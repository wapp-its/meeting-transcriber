import CoreAudio
import Foundation

/// The input device the microphone diagnostics name.
///
/// It exists because the diagnostics answered a different question than the one
/// they were asked. They resolved `kAudioHardwarePropertyDefaultInputDevice`,
/// the system default, while the engine may have been pointed at another
/// device. With a device configured the line then named a microphone that was
/// not recording, so a field report built on it could not be resolved either
/// way (issue #724).
///
/// Both fields are optional separately: CoreAudio can answer one property and
/// decline the other, and a name without a UID is still worth printing.
///
/// Public because the app names the microphone a recording captures
/// (`MicCaptureHandler.activeInputDevice`) and the one a recording would use
/// (`systemDefaultInput()`).
public struct MicInputDevice: Equatable, Sendable {
    public let uid: String?
    public let name: String?

    public init(uid: String?, name: String?) {
        self.uid = uid
        self.name = name
    }

    /// The macOS default input device, nil when there is none or CoreAudio
    /// does not answer.
    ///
    /// Core Audio's `kAudioHardwarePropertyDefaultInputDevice`, not
    /// AVFoundation's default capture device: it is the device the capture
    /// engine follows when nothing is pinned, so it is what "System Default"
    /// records, and AVFoundation's device order is documented as unrelated to
    /// it. Several CoreAudio property reads, so not for a render thread.
    public static func systemDefaultInput() -> Self? {
        systemDefaultInputDeviceID().map(Self.init(deviceID:))
    }

    /// The device's UID and name as CoreAudio reports them.
    init(deviceID: AudioDeviceID) {
        self.init(
            uid: readCFStringAudioProperty(deviceID, kAudioDevicePropertyDeviceUID),
            name: readCFStringAudioProperty(deviceID, kAudioObjectPropertyName),
        )
    }

    static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        guard case let .value(deviceID) = defaultDeviceReading(
            selector: kAudioHardwarePropertyDefaultInputDevice,
        ), deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

/// The `[debug] Mic input device:` line.
///
/// Composed here rather than interpolated at the logging site so the effect is
/// assertable: a test can prove that the device the session reported is the
/// device the line names, which counting the read alone never showed.
///
/// The shape is what a log reader greps for and what field reports quote, so
/// two things are held fixed: a field CoreAudio would not answer stays `"?"`,
/// and the rate keeps the `%f` rendering os_log gave it (`24000.000000`, not
/// `24000.0`).
func micInputDeviceLogLine(
    device: MicInputDevice?, hardwareRate: Double, hardwareChannels: UInt32,
) -> String {
    let rate = String(format: "%f", hardwareRate)
    return "[debug] Mic input device: name=\(device?.name ?? "?") uid=\(device?.uid ?? "?")"
        + " hwRate=\(rate) hwChannels=\(hardwareChannels)"
}
