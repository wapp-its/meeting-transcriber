import AudioTapLib
import AVFoundation

/// One microphone Settings → Audio → Microphone and the menu bar offer.
struct MicrophoneDevice: Equatable, Sendable {
    /// The device's Core Audio UID, the value stored in `AppSettings.micDeviceUID`.
    let uid: String
    let name: String
}

/// The microphone list Settings → Audio → Microphone and the menu bar's
/// Microphone entry share, and the name of the macOS default input.
enum MicrophoneDevices {
    /// Every microphone the app offers, in AVFoundation's discovery order.
    static func available() -> [MicrophoneDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified,
        )
        return session.devices.map { MicrophoneDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// The macOS default input's name, which is what "System Default" records.
    /// From Core Audio, never from `AVCaptureDevice.default(for:)` or the
    /// discovery order above: neither is the device the capture engine follows
    /// when nothing is pinned.
    static func systemDefaultInputName() -> String? {
        MicInputDevice.systemDefaultInput()?.name
    }
}
