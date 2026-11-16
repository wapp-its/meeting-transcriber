import CLevelCell
import CoreAudio
import Foundation

/// The live level of one device for the Audio Devices window: a microphone
/// through an IOProc on the device itself, an output through a device-stream
/// tap read by its own private aggregate (`DeviceLevelMeter+Output.swift`).
///
/// Nothing else: no owner, no lane, no deadline, no log. A meter feeds a level
/// bar and nothing downstream, so it keeps one number and no audio.
///
/// The IOProc runs on the device's real-time IO thread (nil queue) and does
/// only arithmetic and two atomic stores into a C cell, never an allocation, a
/// lock or a log; `LevelPublisher` locks, which is fine off the real-time
/// thread only.
///
/// Whoever holds a meter closes it. `close()` is idempotent and also runs on
/// deinit; `levelDBFS()` may be called from any thread, also during a close.
@available(macOS 14.2, *)
public final class DeviceLevelMeter: @unchecked Sendable {
    /// The open steps, in order, named in every failure so a caller can log
    /// where an open stopped and with which status.
    public enum Step: Equatable, Sendable {
        case translateUID
        case ownProcessObject
        case createTap
        case createAggregate
        case createIOProc
        case start
    }

    public enum OpenError: Error, Equatable {
        /// The UID names no device right now; an absence, not a failure.
        case deviceNotFound
        /// `shouldContinue` answered false right before `before`, a step that
        /// starts hardware: nothing was started and everything built is gone.
        case cancelled(before: Step)
        /// The Core Audio call of `step` failed with `status`; everything built
        /// before it is gone.
        case failed(Step, OSStatus)
    }

    /// What one open built, and how to give it back.
    enum Opened {
        /// The IOProc on the microphone itself; the device is not ours to destroy.
        case input(deviceID: AudioObjectID, procID: AudioDeviceIOProcID)
        /// Tap, aggregate and IOProc, released in the recording's order.
        case output(AppTapSession)
    }

    /// How long a meter keeps showing its last buffer's level: a dormant
    /// aggregate (nothing plays) and a device that stopped delivering read
    /// silent after this, the rule of `currentLevel`.
    static let stalenessSec = 0.5

    let cell: LevelCell
    private let teardown: AppTapSessionHAL
    private let lock = NSLock()
    private var opened: Opened?

    init(cell: LevelCell, opened: Opened, teardown: AppTapSessionHAL) {
        self.cell = cell
        self.opened = opened
        self.teardown = teardown
    }

    deinit {
        close()
    }

    /// Open a level meter on the input device `uid`.
    ///
    /// `shouldContinue` is asked right before `AudioDeviceStart`; on false the
    /// open destroys its IOProc, starts nothing and throws
    /// `OpenError.cancelled`. Blocks on Core Audio, so never call it on the
    /// main thread.
    public static func openInput(uid: String, shouldContinue: () -> Bool) throws -> DeviceLevelMeter {
        try openInput(uid: uid, shouldContinue: shouldContinue, hal: .real)
    }

    static func openInput(
        uid: String, shouldContinue: () -> Bool, hal: DeviceLevelMeterHAL,
    ) throws -> DeviceLevelMeter {
        let deviceID = try resolveDevice(uid: uid, hal: hal)
        let cell = LevelCell()
        let procID = try createIOProc(deviceID: deviceID, block: inputBlock(cell: cell.handle), hal: hal)
        let meter = DeviceLevelMeter(
            cell: cell, opened: .input(deviceID: deviceID, procID: procID), teardown: hal.teardown,
        )
        try meter.closeOnError {
            try meter.start(deviceID: deviceID, procID: procID, shouldContinue: shouldContinue, hal: hal)
        }
        return meter
    }

    /// The newest buffer's level in dBFS, or -120 once no buffer arrived for
    /// half a second. Lock-free; any thread.
    public func levelDBFS() -> Double {
        levelDBFS { mach_absolute_time() }
    }

    /// The cell is loaded before the clock is read, and `reading` accepts a
    /// tick newer than that clock, so a store landing in between cannot make
    /// the age negative.
    func levelDBFS(now: () -> UInt64) -> Double {
        var ticks: UInt64 = 0
        let level = audiotap_level_cell_load(cell.handle.pointer, &ticks)
        return Self.reading(level: level, storedTicks: ticks, nowTicks: now())
    }

    /// The level shown for a stored reading at `nowTicks`.
    ///
    /// The cell has no lock, so the callback can store a tick newer than a
    /// clock the reader sampled just before; that reading is as fresh as one
    /// can be. Handing it to `currentLevel` would subtract the two as `UInt64`
    /// and trap.
    static func reading(level: Double, storedTicks: UInt64, nowTicks: UInt64) -> Double {
        guard storedTicks <= nowTicks else { return level }
        return currentLevel(
            level: level, lastUpdateTicks: storedTicks, nowTicks: nowTicks, stalenessSec: stalenessSec,
        )
    }

    /// Stop and release what the open built. At most once; any thread.
    public func close() {
        lock.lock()
        let toRelease = opened
        opened = nil
        lock.unlock()

        switch toRelease {
        case let .input(deviceID, procID):
            teardown.stopDevice(deviceID, procID)
            teardown.destroyIOProc(deviceID, procID)

        case let .output(session):
            session.destroy()

        case nil:
            break
        }
    }

    // MARK: - Open steps shared by both kinds

    static func resolveDevice(uid: String, hal: DeviceLevelMeterHAL) throws -> AudioObjectID {
        switch hal.translateUID(uid) {
        case let .failed(status):
            throw OpenError.failed(.translateUID, status)

        case let .value(deviceID):
            guard deviceID != kAudioObjectUnknown else { throw OpenError.deviceNotFound }
            return deviceID
        }
    }

    static func createIOProc(
        deviceID: AudioObjectID, block: @escaping AudioDeviceIOBlock, hal: DeviceLevelMeterHAL,
    ) throws -> AudioDeviceIOProcID {
        let (status, procID) = hal.createIOProc(deviceID, block)
        guard status == noErr, let procID else { throw OpenError.failed(.createIOProc, status) }
        return procID
    }

    /// Runs the open's steps after the meter exists. On an error the meter is
    /// closed before the error leaves, so a caller that gets an error owns
    /// nothing.
    func closeOnError(_ steps: () throws -> Void) throws {
        do {
            try steps()
        } catch {
            close()
            throw error
        }
    }

    /// The last step of both opens.
    func start(
        deviceID: AudioObjectID, procID: AudioDeviceIOProcID,
        shouldContinue: () -> Bool, hal: DeviceLevelMeterHAL,
    ) throws {
        guard shouldContinue() else { throw OpenError.cancelled(before: .start) }
        let status = hal.start(deviceID, procID)
        guard status == noErr else { throw OpenError.failed(.start, status) }
    }

    // MARK: - The real-time side

    /// A microphone's level is over every channel of every input buffer.
    static func inputBlock(cell: LevelCell.Handle) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            var sum = SumOfSquares()
            for buffer in buffers {
                sum.add(buffer)
            }
            audiotap_level_cell_store(cell.pointer, sum.levelDBFS, mach_absolute_time())
        }
    }
}

/// Sum of squares over Float32 samples, the RMS of `DebugRMSReporter` as dBFS
/// with a floor of -120. A value type on the stack, so the IO thread never
/// allocates for it.
struct SumOfSquares {
    private var sum: Double = 0
    private var samples = 0

    /// A disabled stream arrives with nil data and a byte count; it adds
    /// nothing.
    mutating func add(_ buffer: AudioBuffer) {
        guard let data = buffer.mData else { return }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let floats = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        for sample in floats {
            sum += Double(sample) * Double(sample)
        }
        samples += count
    }

    var levelDBFS: Double {
        guard samples > 0 else { return -120 }
        let rms = (sum / Double(samples)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }
}

/// Owns the C cell one meter's IOProc writes. Freed only on deinit, which is
/// after the meter's close destroyed the IOProc: every meter holds its cell.
final class LevelCell: Sendable {
    /// What the IO block captures: the bare pointer, copied by value, so the
    /// callback does no reference counting.
    struct Handle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    let handle = Handle(pointer: audiotap_level_cell_create())

    deinit {
        audiotap_level_cell_destroy(handle.pointer)
    }
}
