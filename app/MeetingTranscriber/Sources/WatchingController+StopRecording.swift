import Foundation

/// The menu's "Stop Recording": one entry point that ends whatever is recording.
///
/// Split out of `WatchingController.swift` to keep that file under the line cap.
/// The two kinds of recording end differently, and the difference is who owns
/// the loop. A manual recording owns it, so stopping one tears the loop down
/// exactly as `stopManualRecording()` always has. A detected meeting's recording
/// belongs to a loop that is watching for meetings, so it is only asked to end
/// (`WatchLoop.stopDetectedRecording()`): the loop stops, processes and holds
/// the app at its next poll, and watching carries on.
@MainActor
extension WatchingController {
    /// End the running recording, detected meeting or manual. Does nothing
    /// unless the loop is recording, so a click that lands after the recording
    /// already ended cannot stop watching or anything else.
    func stopRecording() {
        guard let loop = watchLoop, loop.state == .recording else { return }
        if loop.isManualRecording {
            stopManualRecording()
        } else {
            loop.stopDetectedRecording()
        }
    }
}
