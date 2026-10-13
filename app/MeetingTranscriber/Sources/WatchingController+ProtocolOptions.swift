import Foundation

/// The start dialog's Start, split out of `WatchingController.swift` to keep
/// that file under the line cap.
@MainActor
extension WatchingController {
    /// Starts what the dialog selected with its options. Routed through the
    /// two entry points the menu uses, never `beginManualRecording` directly:
    /// the "No Microphone" refusal and its notification live in
    /// `startMicrophoneRecording`, and the dialog's disabled Start is only the
    /// explanation, never the enforcement.
    func startRecording(_ request: ManualRecordingRequest, protocolOptions: MeetingProtocolOptions) {
        switch request {
        case let .app(pid, appName, title):
            startManualRecording(pid: pid, appName: appName, title: title, protocolOptions: protocolOptions)

        case .microphone:
            startMicrophoneRecording(protocolOptions: protocolOptions)
        }
    }
}
