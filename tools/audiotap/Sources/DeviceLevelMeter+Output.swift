import CLevelCell
import CoreAudio
import Foundation

/// The output meter: what every process but this one plays to one output
/// device, from a device-stream tap read through a private aggregate.
///
/// The aggregate is the recording's (`aggregateDescription`): the tapped device
/// as its main and only sub-device, then the tap. Measured on macOS 26.6: an
/// aggregate holding the tap alone delivered the default output's audio, but
/// only zeros for an output that was not the default, in three variants (with
/// and without drift compensation, with the main sub-device key and no
/// sub-device list). The tapped device as sub-device delivered both. The cost:
/// on an output that also has inputs, a running meter runs that device's input
/// too (`tapBuffer(in:)` skips it, #803), as the recording's tap does.
@available(macOS 14.2, *)
extension DeviceLevelMeter {
    /// Open a level meter on the output device `uid`, leaving out what the
    /// process `excludingPID` plays there.
    ///
    /// `shouldContinue` is asked right before creating the tap, creating the
    /// aggregate and `AudioDeviceStart`; on false the open tears down what it
    /// built, starts nothing and throws `OpenError.cancelled`. Blocks on Core
    /// Audio, so never call it on the main thread.
    public static func openOutput(
        uid: String, excludingPID: pid_t, shouldContinue: () -> Bool,
    ) throws -> DeviceLevelMeter {
        try openOutput(uid: uid, excludingPID: excludingPID, shouldContinue: shouldContinue, hal: .real)
    }

    static func openOutput(
        uid: String, excludingPID: pid_t, shouldContinue: () -> Bool, hal: DeviceLevelMeterHAL,
    ) throws -> DeviceLevelMeter {
        _ = try resolveDevice(uid: uid, hal: hal)
        let excluded = try processObjects(pid: excludingPID, hal: hal)

        guard shouldContinue() else { throw OpenError.cancelled(before: .createTap) }
        let tap = tapDescription(deviceUID: uid, excluding: excluded)
        let (tapStatus, tapID) = hal.createTap(tap)
        guard tapStatus == noErr else { throw OpenError.failed(.createTap, tapStatus) }

        // From here the session owns what is built. No drain: the IOProc runs
        // on the IO thread itself, with no queue that could still hold a block.
        let session = AppTapSession(tapID: tapID, hal: hal.teardown) {}
        let cell = LevelCell()
        let meter = DeviceLevelMeter(cell: cell, opened: .output(session), teardown: hal.teardown)

        try meter.closeOnError {
            guard shouldContinue() else { throw OpenError.cancelled(before: .createAggregate) }
            let description = AppAudioCapture.aggregateDescription(
                nameTag: "level", outputUID: uid, tapUUID: tap.uuid.uuidString,
            )
            let (aggregateStatus, aggregateID) = hal.createAggregate(description)
            guard aggregateStatus == noErr else { throw OpenError.failed(.createAggregate, aggregateStatus) }
            // The meter never reads a rate; the session's rate is the recording's.
            session.attach(aggregateID: aggregateID, resolvedSampleRate: 0)

            let procID = try createIOProc(deviceID: aggregateID, block: outputBlock(cell: cell.handle), hal: hal)
            session.attach(procID: procID)
            try meter.start(deviceID: aggregateID, procID: procID, shouldContinue: shouldContinue, hal: hal)
        }
        return meter
    }

    /// The process object of `pid`, as the one process to leave out; none when
    /// the process has no object (it plays nothing). A failed lookup is a
    /// failure, never "nothing to exclude".
    static func processObjects(pid: pid_t, hal: DeviceLevelMeterHAL) throws -> [AudioObjectID] {
        switch hal.translatePID(pid) {
        case let .failed(status):
            throw OpenError.failed(.ownProcessObject, status)

        case let .value(objectID):
            objectID == kAudioObjectUnknown ? [] : [objectID]
        }
    }

    /// Every process stream destined for the device's first output stream,
    /// except `excluding`. Private, so no other process sees it, and unmuted,
    /// so the meter never silences what it measures.
    static func tapDescription(deviceUID: String, excluding: [AudioObjectID]) -> CATapDescription {
        let tap = CATapDescription(excludingProcesses: excluding, deviceUID: deviceUID, stream: 0)
        tap.uuid = UUID()
        tap.name = "MeetingTranscriber-level-tap"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        return tap
    }

    /// An output's level is the tap's buffer only, the last one: an output with
    /// inputs hands its own input streams over first (#803).
    static func outputBlock(cell: LevelCell.Handle) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            guard let tap = AppAudioCapture.tapBuffer(in: inputData) else { return }
            var sum = SumOfSquares()
            sum.add(tap)
            audiotap_level_cell_store(cell.pointer, sum.levelDBFS, mach_absolute_time())
        }
    }
}
