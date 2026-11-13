import Foundation

/// The menu's update actions in mt-update mode, split out of `AppState.swift`,
/// which sits at the 600-line cap.
extension AppState {
    /// Why "Install Update" is not possible right now, or nil: what mt-update
    /// itself waits for. The manual-recording predicate is the controller's
    /// wide one, so a manual start that has not built its loop yet counts.
    var updateInstallBlockedReason: String? {
        UpdateInstallGate.blockedReason(
            isRecording: watching.isRecording,
            manualRecordingStarting: watching.isManualRecording,
            waitingJobs: pipeline.queue.pendingJobs.count,
            activeJobs: pipeline.queue.activeJobs.count,
        )
    }

    func installUpdate() {
        updateChecker.installNow(blockedReason: updateInstallBlockedReason, isWatching: watching.isWatching)
    }

    /// Reports an install the previous instance started, and turns meeting
    /// watching back on through the auto-watch path when it was on then.
    /// The auto-watch start posted at launch also checks "not already
    /// watching", so whichever of the two runs second does nothing.
    func resumeUpdateAfterLaunch() {
        if updateChecker.resumeAfterLaunch(), !watching.isWatching {
            watching.toggleWatching(userInitiated: false)
        }
    }
}
