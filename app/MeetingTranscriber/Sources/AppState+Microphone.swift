import Foundation

/// The menu-bar body's accessors for the recording's microphone and app-audio
/// channels, split out of `AppState.swift`, which sits at the 600-line cap.
extension AppState {
    /// The menu bar's Microphone entry. During a recording it names the device
    /// the capture reports (`microphone.recordedDevice`), not the setting.
    var microphoneMenuState: MicrophoneMenuState {
        .resolve(
            noMic: settings.noMic,
            selectedUID: settings.micDeviceUID,
            devices: microphone.devices,
            defaultInputName: microphone.defaultInputName,
            recordedDevice: microphone.recordedDevice,
            meetingAppHint: nil,
        )
    }

    /// Menu-bar **top-half** red tint: mic channel silent, OR both channels
    /// silent (`recordingSilentActive` paints both halves). Hoisted out of the
    /// menu-bar body for the same type-check-budget reason as
    /// `hasPermissionProblem` — reading two `channelHealth.*` flags through the
    /// sub-controller inline is more than the body can afford on slow CI.
    var micSilentOverlay: Bool {
        channelHealth.micSilentOverlay
    }

    /// Menu-bar **bottom-half** red tint: app-audio channel silent, OR both
    /// channels silent. See `micSilentOverlay`.
    var appSilentOverlay: Bool {
        channelHealth.appSilentOverlay
    }
}
