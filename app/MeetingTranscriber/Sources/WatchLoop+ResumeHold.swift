import Foundation

/// Holding the calls already running when watching resumes after a manual
/// recording, split out of `WatchLoop.swift` to keep that file under the line
/// cap.
///
/// A call that ran through the whole manual recording would otherwise be
/// recorded, or asked about, from its middle by the resumed loop. Every
/// meeting the detector reports signalling at that moment, confirmed or not,
/// gets the re-detection hold (`WatchLoop+RedetectionHold.swift`), whose own
/// rule releases it: the first watching poll that finds that meeting's signal
/// gone. `start()` keeps holds and `stop()` discards them, so this runs on a
/// loop before its `start()`.
extension WatchLoop {
    /// Hold every meeting signalling now and log how many. The count line
    /// names no app; each hold logs its own app.
    func holdSignallingMeetings() {
        let meetings = detector.signallingMeetings()
        for meeting in meetings {
            holdRedetection(of: meeting)
        }
        diagnostics.notice("watch_resumed_after_manual_recording held=\(meetings.count)")
    }
}
