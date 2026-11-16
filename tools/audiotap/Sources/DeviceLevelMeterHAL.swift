import CoreAudio
import Foundation

/// The Core Audio calls a `DeviceLevelMeter` open makes, injectable so every
/// step's failure and every cancellation can be asserted without hardware.
/// Releasing goes through `AppTapSessionHAL`, the recording's order.
///
/// Translations are readings, not optionals: a call that failed must stay
/// apart from an absent device or process object.
@available(macOS 14.2, *)
struct DeviceLevelMeterHAL: Sendable {
    var translateUID: @Sendable (String) -> ProcessOutputState.Reading<AudioObjectID>
    var translatePID: @Sendable (pid_t) -> ProcessOutputState.Reading<AudioObjectID>
    var createTap: @Sendable (CATapDescription) -> (OSStatus, AudioObjectID)
    var createAggregate: @Sendable ([String: Any]) -> (OSStatus, AudioObjectID)
    var createIOProc: @Sendable (AudioObjectID, @escaping AudioDeviceIOBlock) -> (OSStatus, AudioDeviceIOProcID?)
    var start: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
    var teardown: AppTapSessionHAL

    static let real = Self(
        translateUID: { translate(uid: $0) },
        translatePID: { translate(pid: $0) },
        createTap: { tap in
            var tapID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(tap, &tapID)
            return (status, tapID)
        },
        createAggregate: { description in
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
            return (status, aggregateID)
        },
        // A nil queue runs the block on the device's IO thread itself.
        createIOProc: { deviceID, block in
            var procID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil, block)
            return (status, procID)
        },
        start: { AudioDeviceStart($0, $1) },
        teardown: .real,
    )

    /// `deviceIDForUID` without dropping the status.
    private static func translate(uid: String) -> ProcessOutputState.Reading<AudioObjectID> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        // Extended lifetime for the reason `deviceIDForUID` gives.
        let cfUID = uid as CFString
        var qualifier: Unmanaged<CFString>? = .passUnretained(cfUID)
        let qualifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withExtendedLifetime(cfUID) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, qualifierSize, &qualifier, &size, &deviceID,
            )
        }
        return status == noErr ? .value(deviceID) : .failed(status)
    }

    /// `AppAudioCapture.translatePID` without dropping the status.
    private static func translate(pid: pid_t) -> ProcessOutputState.Reading<AudioObjectID> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &objectID,
        )
        return status == noErr ? .value(objectID) : .failed(status)
    }
}
