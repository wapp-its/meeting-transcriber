@testable import AudioTapLib
import CoreAudio
import XCTest

/// The level meters of the Audio Devices window, through an injected HAL: the
/// level the real-time block stores, how a reading ages, and what an open
/// builds, refuses and gives back.
@available(macOS 14.2, *)
final class DeviceLevelMeterTests: XCTestCase {
    private typealias Step = DeviceLevelMeter.Step

    private static let deviceID: AudioObjectID = 7
    private static let processObject: AudioObjectID = 9
    private static let tapID: AudioObjectID = 11
    private static let aggregateID: AudioObjectID = 22

    /// Records every HAL call in order and fails the one of `failing`.
    /// Unchecked because the HAL closures are `@Sendable`; the lock is what
    /// makes it safe.
    private final class FakeHAL: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private(set) var block: AudioDeviceIOBlock?
        private(set) var tap: CATapDescription?
        private(set) var aggregate: [String: Any] = [:]

        var failing: Step?
        var status: OSStatus = -1
        var device = DeviceLevelMeterTests.deviceID
        var processObject = DeviceLevelMeterTests.processObject

        var calls: [String] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        private func record(_ call: String) {
            lock.lock(); _calls.append(call); lock.unlock()
        }

        private func fails(_ step: Step) -> Bool {
            failing == step
        }

        func hal() -> DeviceLevelMeterHAL {
            let proc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
            return DeviceLevelMeterHAL(
                translateUID: { [self] _ in fails(.translateUID) ? .failed(status) : .value(device) },
                translatePID: { [self] _ in fails(.ownProcessObject) ? .failed(status) : .value(processObject) },
                createTap: { [self] tap in
                    record("createTap")
                    self.tap = tap
                    return fails(.createTap) ? (status, 0) : (noErr, DeviceLevelMeterTests.tapID)
                },
                createAggregate: { [self] description in
                    record("createAggregate")
                    aggregate = description
                    return fails(.createAggregate) ? (status, 0) : (noErr, DeviceLevelMeterTests.aggregateID)
                },
                createIOProc: { [self] device, block in
                    record("createIOProc(\(device))")
                    self.block = block
                    return fails(.createIOProc) ? (status, nil) : (noErr, proc)
                },
                start: { [self] device, _ in
                    record("start(\(device))")
                    return fails(.start) ? status : noErr
                },
                teardown: AppTapSessionHAL(
                    stopDevice: { [self] device, _ in record("stop(\(device))") },
                    destroyIOProc: { [self] device, _ in record("destroyIOProc(\(device))") },
                    destroyAggregate: { [self] device in record("destroyAggregate(\(device))") },
                    destroyTap: { [self] tap in record("destroyTap(\(tap))") },
                ),
            )
        }
    }

    private enum Kind { case input, output }

    private func open(
        _ kind: Kind, fake: FakeHAL, shouldContinue: () -> Bool = { true },
    ) throws -> DeviceLevelMeter {
        switch kind {
        case .input:
            try DeviceLevelMeter.openInput(uid: "mic", shouldContinue: shouldContinue, hal: fake.hal())

        case .output:
            try DeviceLevelMeter.openOutput(
                uid: "speakers", excludingPID: 42, shouldContinue: shouldContinue, hal: fake.hal(),
            )
        }
    }

    /// Hands `buffers` (one channel each) to the IO block as one callback.
    private func deliver(_ buffers: [[Float]], to block: AudioDeviceIOBlock?) throws {
        let block = try XCTUnwrap(block)
        let list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
        list.count = buffers.count
        let storage = buffers.map { samples in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        defer {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, samples) in buffers.enumerated() {
            list[index] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: storage[index],
            )
        }
        var now = AudioTimeStamp()
        var inputTime = AudioTimeStamp()
        var outputTime = AudioTimeStamp()
        var output = AudioBufferList()
        block(&now, list.unsafePointer, &inputTime, &output, &outputTime)
    }

    // MARK: - The level

    func testAMicrophoneLevelIsTheRMSOfEverySampleOfEveryBuffer() throws {
        let fake = FakeHAL()
        let meter = try open(.input, fake: fake)

        // Two channels as two buffers: only the first carries signal. Over all
        // four samples the RMS is sqrt(0.125); the first buffer alone would
        // read -6 dB, the last alone the floor.
        try deliver([[0.5, 0.5], [0, 0]], to: fake.block)

        XCTAssertEqual(meter.levelDBFS(), 20 * log10(0.125.squareRoot()), accuracy: 0.001)
    }

    func testSilenceAndAMeterThatNeverDeliveredReadTheFloor() throws {
        let fake = FakeHAL()
        let meter = try open(.input, fake: fake)
        XCTAssertEqual(meter.levelDBFS(), -120)

        try deliver([[0, 0, 0, 0]], to: fake.block)
        XCTAssertEqual(meter.levelDBFS(), -120)

        // Signal far below the floor is still the floor, not -180.
        try deliver([[1e-9, 1e-9]], to: fake.block)
        XCTAssertEqual(meter.levelDBFS(), -120)
    }

    func testTheLevelDecaysToTheFloorHalfASecondAfterTheLastBuffer() throws {
        let fake = FakeHAL()
        let meter = try open(.input, fake: fake)
        try deliver([[0.5, 0.5]], to: fake.block)
        let delivered = mach_absolute_time()

        XCTAssertEqual(meter.levelDBFS { delivered + secondsToMachTicks(0.4) }, 20 * log10(0.5), accuracy: 0.001)
        XCTAssertEqual(meter.levelDBFS { delivered + secondsToMachTicks(0.6) }, -120)
    }

    func testATickNewerThanTheReadersClockReadsFreshAndDoesNotTrap() throws {
        let fake = FakeHAL()
        let meter = try open(.input, fake: fake)
        try deliver([[0.5, 0.5]], to: fake.block)

        // A clock sampled before the store landed: older than the stored tick.
        XCTAssertEqual(meter.levelDBFS { 1 }, 20 * log10(0.5), accuracy: 0.001)
    }

    func testAnOutputLevelIsTheTapBufferOnly() throws {
        let fake = FakeHAL()
        let meter = try open(.output, fake: fake)

        // An output with inputs: its own input stream first, the tap last (#803).
        try deliver([[0.1, 0.1], [0.5, 0.5]], to: fake.block)

        XCTAssertEqual(meter.levelDBFS(), 20 * log10(0.5), accuracy: 0.001)
        let tap = try XCTUnwrap(fake.tap)
        XCTAssertTrue(tap.isExclusive, "the listed processes are excluded, not the only ones tapped")
        XCTAssertEqual(tap.processes, [Self.processObject])
        XCTAssertEqual(tap.deviceUID, "speakers")
        XCTAssertEqual(tap.stream, 0)
        XCTAssertTrue(tap.isPrivate)
        XCTAssertEqual(tap.muteBehavior, .unmuted)
        let aggregate = fake.aggregate
        let taps = try XCTUnwrap(aggregate[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        XCTAssertEqual(taps.first?[kAudioSubTapUIDKey] as? String, tap.uuid.uuidString)
        XCTAssertEqual(aggregate[kAudioAggregateDeviceMainSubDeviceKey] as? String, "speakers")
    }

    // MARK: - Opening

    func testEveryFailedStepNamesItselfAndItsStatusAndReleasesWhatWasBuilt() {
        let input = ["createIOProc(7)", "start(7)", "stop(7)", "destroyIOProc(7)"]
        let output = [
            "createTap", "createAggregate", "createIOProc(22)", "start(22)",
            "stop(22)", "destroyIOProc(22)", "destroyAggregate(22)", "destroyTap(11)",
        ]
        let cases: [(Kind, Step, [String])] = [
            (.input, .translateUID, []),
            (.input, .createIOProc, ["createIOProc(7)"]),
            (.input, .start, input),
            (.output, .translateUID, []),
            (.output, .ownProcessObject, []),
            (.output, .createTap, ["createTap"]),
            (.output, .createAggregate, ["createTap", "createAggregate", "destroyTap(11)"]),
            (.output, .createIOProc, [
                "createTap", "createAggregate", "createIOProc(22)", "destroyAggregate(22)", "destroyTap(11)",
            ]),
            (.output, .start, output),
        ]
        for (index, (kind, step, expectedCalls)) in cases.enumerated() {
            let fake = FakeHAL()
            fake.failing = step
            fake.status = OSStatus(-100 - index)

            XCTAssertThrowsError(try open(kind, fake: fake), "\(kind) \(step)") { error in
                XCTAssertEqual(error as? DeviceLevelMeter.OpenError, .failed(step, fake.status), "\(kind) \(step)")
            }
            XCTAssertEqual(fake.calls, expectedCalls, "\(kind) \(step)")
        }
    }

    func testAnAbsentDeviceIsNotAFailureAndAnAbsentProcessObjectExcludesNothing() throws {
        for kind in [Kind.input, .output] {
            let fake = FakeHAL()
            fake.device = kAudioObjectUnknown
            XCTAssertThrowsError(try open(kind, fake: fake)) { error in
                XCTAssertEqual(error as? DeviceLevelMeter.OpenError, .deviceNotFound, "\(kind)")
            }
            XCTAssertEqual(fake.calls, [], "\(kind)")
        }

        let fake = FakeHAL()
        fake.processObject = kAudioObjectUnknown
        _ = try open(.output, fake: fake)
        XCTAssertEqual(fake.tap?.processes, [])
    }

    func testShouldContinueFalseBeforeAStartStepStartsNothingAndReleasesWhatWasBuilt() {
        let cases: [(Kind, falseAtCheck: Int, Step, [String])] = [
            (.input, 1, .start, ["createIOProc(7)", "stop(7)", "destroyIOProc(7)"]),
            (.output, 1, .createTap, []),
            (.output, 2, .createAggregate, ["createTap", "destroyTap(11)"]),
            (.output, 3, .start, [
                "createTap", "createAggregate", "createIOProc(22)",
                "stop(22)", "destroyIOProc(22)", "destroyAggregate(22)", "destroyTap(11)",
            ]),
        ]
        for (kind, falseAtCheck, step, expectedCalls) in cases {
            let fake = FakeHAL()
            var checks = 0
            let shouldContinue = {
                checks += 1
                return checks < falseAtCheck
            }

            XCTAssertThrowsError(try open(kind, fake: fake, shouldContinue: shouldContinue), "\(kind) \(step)") { error in
                XCTAssertEqual(error as? DeviceLevelMeter.OpenError, .cancelled(before: step), "\(kind) \(step)")
            }
            XCTAssertEqual(fake.calls, expectedCalls, "\(kind) \(step)")
            XCTAssertFalse(fake.calls.contains { $0.hasPrefix("start") }, "\(kind) \(step)")
        }
    }

    // MARK: - Closing

    func testCloseTwiceReleasesOnceAndDeinitAfterCloseReleasesNothingMore() throws {
        let expected: [Kind: [String]] = [
            .input: ["stop(7)", "destroyIOProc(7)"],
            .output: ["stop(22)", "destroyIOProc(22)", "destroyAggregate(22)", "destroyTap(11)"],
        ]
        for (kind, releases) in expected {
            let fake = FakeHAL()
            var opened = 0
            do {
                let meter = try open(kind, fake: fake)
                opened = fake.calls.count
                meter.close()
                meter.close()
            }
            XCTAssertEqual(Array(fake.calls.dropFirst(opened)), releases, "\(kind)")
        }
    }
}
