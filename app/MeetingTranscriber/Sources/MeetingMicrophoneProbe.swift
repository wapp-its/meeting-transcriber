import AudioTapLib
import CoreAudio
import Foundation

/// One process the recording tapped, as Core Audio describes its microphone
/// use: whether it runs audio input and which input devices it uses (issue
/// #43). Read by `MeetingMicrophoneProbe`, judged by `MeetingMicrophoneVerdict`.
struct MeetingInputProcess: Equatable, Sendable {
    let pid: pid_t
    /// AudioTapLib's `getExecutableName(pid:)`, `?` when the lookup fails.
    let executableName: String
    let isRunningInput: MeetingMicrophoneProbe.Reading<Bool>
    let inputDevices: MeetingMicrophoneProbe.Reading<[MeetingInputDevice]>
}

/// One input device a tapped process uses. The name is read for the
/// notification, the menu hint and the verbose `[debug]` line only.
struct MeetingInputDevice: Equatable, Sendable {
    let objectID: AudioObjectID
    let uid: MeetingMicrophoneProbe.Reading<String>
    let name: MeetingMicrophoneProbe.Reading<String>
    let transport: MeetingMicrophoneProbe.Reading<UInt32>
}

/// The hardware side of the meeting-app microphone probe: maps the recording's
/// tapped process ids to Core Audio process objects and reads, per process,
/// `kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyDevices` on
/// the **input** scope, and per device its UID, name and transport type. No
/// logic beyond reading; the verdict and the warning policy decide.
///
/// **Never call this on the main thread.** Every read is a synchronous round
/// trip through coreaudiod, which can stop answering (issue #588);
/// `MicrophoneController` runs it on its own serial queue, at most one at a time.
enum MeetingMicrophoneProbe {
    /// A value that was read, or the status that says why it was not, shaped
    /// like AudioTapLib's `ProcessOutputState.Reading`. Every property keeps its
    /// own, the name included, so a failed read is logged as `?(<status>)` and
    /// never as a plausible value: "no input device" and "could not ask" must
    /// stay apart, or a reader draws the first conclusion from the second.
    enum Reading<Value: Equatable & Sendable>: Equatable, Sendable {
        case value(Value)
        case failed(OSStatus)

        var isFailed: Bool {
            if case .failed = self { true } else { false }
        }

        func map<Other>(_ transform: (Value) -> Other) -> Reading<Other> {
            switch self {
            case let .value(value): .value(transform(value))
            case let .failed(status): .failed(status)
            }
        }
    }

    /// The four raw Core Audio reads, injectable so a test can make any one of
    /// them fail and follow the status into the log lines. `processObject` is
    /// nil for a pid without a process object, which the probe skips; the
    /// others keep the status of a failed call.
    struct RawReads: Sendable {
        let processObject: @Sendable (pid_t) -> AudioObjectID?
        let uint32: @Sendable (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope) -> Reading<UInt32>
        let objectIDs: @Sendable (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope) -> Reading<[AudioObjectID]>
        let string: @Sendable (AudioObjectID, AudioObjectPropertySelector) -> Reading<String>

        static let coreAudio = Self(
            processObject: translatePID,
            uint32: readUInt32,
            objectIDs: readObjectIDs,
            string: readString,
        )
    }

    /// The input side of every tapped process that has a process object.
    static func read(pids: [pid_t], reads: RawReads = .coreAudio) -> [MeetingInputProcess] {
        pids.compactMap { pid in
            guard let object = reads.processObject(pid) else { return nil }
            let devices = reads.objectIDs(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
            return MeetingInputProcess(
                pid: pid,
                executableName: getExecutableName(pid: pid),
                isRunningInput: reads.uint32(object, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal)
                    .map { $0 != 0 },
                inputDevices: devices.map { ids in ids.map { device($0, reads: reads) } },
            )
        }
    }

    private static func device(_ objectID: AudioObjectID, reads: RawReads) -> MeetingInputDevice {
        MeetingInputDevice(
            objectID: objectID,
            uid: reads.string(objectID, kAudioDevicePropertyDeviceUID),
            name: reads.string(objectID, kAudioObjectPropertyName),
            transport: reads.uint32(objectID, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal),
        )
    }

    // MARK: - Core Audio

    /// AudioTapLib's PID translation (`AppAudioCapture.translatePID`), which is
    /// internal to the library.
    private static func translatePID(_ pid: pid_t) -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePid = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &mutablePid, &size, &objectID,
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func readUInt32(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
    ) -> Reading<UInt32> {
        var address = propertyAddress(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { return .failed(status) }
        return .value(value)
    }

    private static func readObjectIDs(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
    ) -> Reading<[AudioObjectID]> {
        var address = propertyAddress(selector, scope)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard sizeStatus == noErr else { return .failed(sizeStatus) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return .value([]) }

        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids)
        guard status == noErr else { return .failed(status) }
        // The second call updates `size`, and the list can have shrunk between
        // the two. Without the trim the tail would be logged as device 0.
        return .value(Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)))
    }

    /// A CFString read that keeps its status, unlike AudioTapLib's
    /// `readCFStringAudioProperty`, which returns nil and drops it. A call that
    /// answers `noErr` without a string reads as `?(0)`, not as an empty name.
    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Reading<String> {
        var address = propertyAddress(selector, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return .failed(status) }
        guard let string = value?.takeRetainedValue() else { return .failed(noErr) }
        return .value(string as String)
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
