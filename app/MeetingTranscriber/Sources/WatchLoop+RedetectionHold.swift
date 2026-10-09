import Foundation

/// Keeping an app out of detection after one of its recordings was ended while
/// its call signal was still there, split out of `WatchLoop.swift` to keep
/// that file under the line cap.
///
/// After a recording the loop goes straight back to polling, and a detector's
/// cooldown after a meeting is a few seconds (`PowerAssertionDetector` uses
/// 5 s). A call app often keeps its signal after the meeting the person ended
/// the recording of (Teams keeps its window and the microphone), so without a
/// hold that same call would be detected again within seconds and recorded,
/// or asked about, anew. The signal disappearing is the only call boundary the
/// detector has, so a hold lasts until the first watching poll that finds the
/// held meeting's signal gone; the app's next call is then detected as usual.
/// Any stop that ends a detected meeting while its signal stays can place
/// one; Stop Watching discards them all, since they live in memory only.
extension WatchLoop {
    /// The apps detection passes over until their signal has gone once.
    var appsHeldFromDetection: Set<String> {
        redetectionHolds.heldApps
    }

    /// Keep `meeting`'s app out of detection until a watching poll finds the
    /// meeting's signal gone.
    func holdRedetection(of meeting: DetectedMeeting) {
        guard redetectionHolds.hold(meeting) else { return }
        // The detector identity only: the meeting title stays out of the log.
        diagnostics.notice("redetect_hold_set app=\(meeting.pattern.appName)")
    }

    /// Release every hold whose meeting's signal is gone. Run at the top of
    /// every watching poll, before detection, so the poll that finds a call
    /// over already detects the app's next one.
    func releaseEndedRedetectionHolds() {
        let released = redetectionHolds.release { !detector.isMeetingActive($0) }
        for app in released {
            diagnostics.notice("redetect_hold_released app=\(app)")
        }
    }
}
