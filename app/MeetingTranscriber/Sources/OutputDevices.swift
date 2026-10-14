import AudioTapLib
import CoreAudio
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OutputDevices")

/// One sound output the menu bar's Output entry shows.
struct OutputDevice: Equatable, Sendable {
    /// The device's Core Audio UID: what the entry checks and what choosing it
    /// makes the Mac's default output.
    let uid: String
    let name: String
}

/// The Mac's sound outputs and its default output, read from Core Audio, and
/// the one write the Output entry makes: setting that default.
///
/// The app-audio tap follows the Mac's default output (`AppAudioCapture`), so
/// this is the setting that decides what a recording's app track hears. The
/// app keeps no output choice of its own.
enum OutputDevices {
    /// Every device the Mac offers as a sound output, in Core Audio's order:
    /// one with an output stream that Core Audio says can be the default output
    /// and that is not hidden. That flag is what keeps private aggregate
    /// devices out, the app's own capture aggregates among them (measured: a
    /// private aggregate reports it false). The Microsoft Teams loopback device
    /// reports it false too, although Teams sets it as the default output.
    static func available() -> [OutputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasOutputStream(id),
                  readUInt32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput) == 1,
                  readUInt32(id, kAudioDevicePropertyIsHidden) != 1
            else { return nil }
            return device(id)
        }
    }

    /// The Mac's default output, nil when there is none or Core Audio does not
    /// answer.
    static func systemDefault() -> OutputDevice? {
        guard let id = readUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              id != kAudioObjectUnknown
        else { return nil }
        return device(id)
    }

    /// Make the device with `uid` the Mac's default output, as choosing it in
    /// Control Center does. Returns the status of the set, or
    /// `kAudioHardwareBadDeviceError` when no device has that UID.
    static func setSystemDefault(uid: String) -> OSStatus {
        guard var id = allDeviceIDs().first(where: { readCFStringAudioProperty($0, kAudioDevicePropertyDeviceUID) == uid })
        else { return kAudioHardwareBadDeviceError }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id,
        )
    }

    /// Call `handler` on the main queue whenever the default output or the
    /// device list changes. For the app's lifetime: nothing is ever removed.
    static func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain,
            )
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { handler() }
            }
            if status != noErr {
                logger.warning("Output device listener not installed (status: \(status))")
            }
        }
    }

    private static func device(_ id: AudioObjectID) -> OutputDevice? {
        guard let uid = readCFStringAudioProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return OutputDevice(uid: uid, name: readCFStringAudioProperty(id, kAudioObjectPropertyName) ?? uid)
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func hasOutputStream(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func readUInt32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
