import Foundation

/// Turning meeting watching back on after a manual recording that took it
/// over. `performManualRecording` sets `resumeWatchingPending` when it stops an
/// active watch loop; the end of that recording (`WatchLoop`'s end signal) and
/// a start that recorded nothing both call `scheduleResumeIfPending`.
///
/// The resume is "start unless already watching": `startWatchLoop` with all
/// its ownership checks, asking for no permission, and holding every call
/// signalling at that moment (`WatchLoop.holdSignallingMeetings`). It runs in
/// a task of its own, never inside the stop or the failed start that triggered
/// it: there it would still see the old loop, or the start's own registration,
/// and leave watching off with nothing left to pick the intent up.
@MainActor
extension WatchingController {
    /// Launch the resume if one is owed and none is running. A resume already
    /// running re-reads the state after each of its waits, so it covers this
    /// call too.
    func scheduleResumeIfPending() {
        guard resumeWatchingPending, resumeTask == nil else { return }
        resumeTask = Task { @MainActor in
            defer { resumeTask = nil }
            await resumeWatching()
        }
    }

    /// Bounded wait for the resume in flight, like `joinStart`. True when it
    /// finished, false on expiry.
    func joinResume() async -> Bool {
        await join { self.resumeTask != nil }
    }

    /// Each pass waits out whatever is in the way, then starts watching unless
    /// a manual recording runs (the intent then waits for its end) or watching
    /// is already on (nothing is owed any more).
    private func resumeWatching() async {
        while resumeWatchingPending {
            // A registered manual start ends in its recording, whose end calls
            // `scheduleResumeIfPending`, or in a failure, which calls it too.
            // Giving up on one still parked on the microphone prompt therefore
            // loses nothing.
            guard await joinManualStart() else { return }
            if watchLoop?.isManualRecording == true { return }
            // A start someone else launched (Start Watching) is let finish first.
            guard await joinStart() else {
                // The intent goes too: a manual recording started later, with
                // watching off, must not bring watching back when it ends.
                resumeWatchingPending = false
                diagnostics.notice("watch_resume_failed reason=start_did_not_settle")
                return
            }
            if !resumeWatchingPending || isManualRecording { continue }
            if isWatching {
                resumeWatchingPending = false
                return
            }
            startWatchLoop(userInitiated: false, requestingPermissions: false, holdingSignallingMeetings: true)
            // That start waits on nothing, so this settles at once. Installed,
            // it consumed the intent and the loop ends. Bailed for a manual
            // start that registered before it ran, it left the intent pending,
            // and the next pass waits for that start.
            _ = await joinStart()
        }
    }
}
