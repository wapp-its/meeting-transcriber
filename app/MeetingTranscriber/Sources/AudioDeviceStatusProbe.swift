import CoreAudio
import Foundation

/// One reading for the Audio Devices window (`AudioDevicesWindowReader`).
struct AudioDeviceStatusReading: Equatable, Sendable {
    /// Per device UID, `kAudioDevicePropertyDeviceIsRunningSomewhere`: whether
    /// any process, this one included, runs audio on the device. A device
    /// whose UID or flag could not be read is missing.
    let running: [String: Bool]
    /// Whether this app's own process runs audio input; nil when Core Audio
    /// did not answer, which `/state` reports as null rather than as false.
    let selfRunningInput: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The tapped processes' devices; nil when this reading did not ask.
    let meetingApp: MeetingAppDevices?
}

/// The hardware side of the Audio Devices window: per device, whether it runs
/// for some process; whether this app's own process runs audio input; and,
/// when asked, which input and output devices the recording's tapped processes
/// use, the input side read as `MeetingMicrophoneProbe.read` reads it plus its
/// output-scope counterpart. Property reads only: it opens no device, installs
/// no tap and starts no capture.
///
/// **Never call this on the main thread.** Every read is a synchronous round
/// trip through coreaudiod, which can stop answering (issue #588);
/// `AudioDevicesWindowReader` runs it on its own serial queue, one at a time.
enum AudioDeviceStatusProbe {
    /// - Parameter tappedPIDs: the processes to ask about; empty to not ask.
    static func read(
        tappedPIDs: [pid_t],
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        reads: MeetingMicrophoneProbe.RawReads = .coreAudio,
    ) -> AudioDeviceStatusReading {
        AudioDeviceStatusReading(
            running: runningDevices(reads),
            selfRunningInput: value(reads.processObject(ownPID)).flatMap(\.self).flatMap { process in
                value(reads.uint32(process, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal))
                    .map { $0 != 0 }
            },
            meetingApp: tappedPIDs.isEmpty ? nil : meetingAppDevices(pids: tappedPIDs, reads: reads),
        )
    }

    private static func runningDevices(_ reads: MeetingMicrophoneProbe.RawReads) -> [String: Bool] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let devices = value(reads.objectIDs(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal))
        else { return [:] }
        var running: [String: Bool] = [:]
        for device in devices {
            guard let uid = value(reads.string(device, kAudioDevicePropertyDeviceUID)),
                  let flag = value(reads.uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal))
            else { continue }
            running[uid] = flag != 0
        }
        return running
    }

    /// A pid without a process object uses no audio device, and is skipped
    /// as the meeting microphone probe skips it. A pid whose translation
    /// failed may use any device, so both sides are incomplete.
    private static func meetingAppDevices(pids: [pid_t], reads: MeetingMicrophoneProbe.RawReads) -> MeetingAppDevices {
        var processes: [AudioObjectID] = []
        var translated = true
        for pid in pids {
            switch reads.processObject(pid) {
            case let .value(object?): processes.append(object)
            case .value(nil): continue
            case .failed: translated = false
            }
        }
        let input = deviceUIDs(processes, scope: kAudioObjectPropertyScopeInput, reads: reads)
        let output = deviceUIDs(processes, scope: kAudioObjectPropertyScopeOutput, reads: reads)
        return MeetingAppDevices(
            inputUIDs: input.uids, outputUIDs: output.uids,
            inputComplete: translated && input.complete, outputComplete: translated && output.complete,
        )
    }

    private static func deviceUIDs(
        _ processes: [AudioObjectID], scope: AudioObjectPropertyScope, reads: MeetingMicrophoneProbe.RawReads,
    ) -> (uids: Set<String>, complete: Bool) {
        var uids: Set<String> = []
        var complete = true
        for process in processes {
            guard let devices = value(reads.objectIDs(process, kAudioProcessPropertyDevices, scope)) else {
                complete = false
                continue
            }
            for device in devices {
                if let uid = value(reads.string(device, kAudioDevicePropertyDeviceUID)) {
                    uids.insert(uid)
                } else {
                    complete = false
                }
            }
        }
        return (uids, complete)
    }

    private static func value<Value>(_ reading: MeetingMicrophoneProbe.Reading<Value>) -> Value? {
        if case let .value(value) = reading { value } else { nil }
    }
}
