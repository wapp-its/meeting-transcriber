import Foundation

/// The warning before a recording reaches its maximum length, and the notices
/// saying why a recording stopped without a question first, as both poll loops
/// post them. The decision and the texts are in `RecordingStopNotices.swift`;
/// this posts them through the notifier and writes the warning's diagnostic
/// line.
extension WatchLoop {
    /// Warn that the recording is about to reach its maximum length, if this
    /// poll is the first inside the warning window. `elapsed` is what the
    /// calling loop's own cap check measures, so the warning and the stop
    /// agree; `warned` is that loop's flag for this recording.
    func warnBeforeMaximumIfDue(
        elapsed: TimeInterval,
        recordingTitle: String,
        trigger: RecordingSidecar.Trigger,
        warned: inout Bool,
    ) {
        guard RecordingCapWarningPolicy.shouldWarn(
            elapsed: elapsed,
            maxDuration: maxDuration,
            lead: capWarningLead,
            alreadyWarned: warned,
        ) else { return }
        warned = true
        postStopNotice(RecordingStopNotices.capWarning(recordingTitle: recordingTitle, elapsed: elapsed, maxDuration: maxDuration))
        diagnostics.notice(RecordingStopNotices.capWarningLogLine(trigger: trigger, remaining: maxDuration - elapsed))
    }

    func postStopNotice(_ notice: RecordingStopNotices.Notice) {
        notifier.notify(title: notice.title, body: notice.body, urgency: notice.urgency)
    }
}
