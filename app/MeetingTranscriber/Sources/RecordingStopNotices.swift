import Foundation

/// Whether a recording is warned on this poll that it is about to reach its
/// maximum length. Both poll loops ask it, `waitForMeetingEnd` for detected
/// meetings and `monitorManualRecording` for manual ones, each with the
/// elapsed time its own duration cap measures, so the warning and the stop
/// agree. Each loop keeps the "already warned" flag for its recording.
enum RecordingCapWarningPolicy {
    /// How long before the maximum the warning goes out: fixed, with no
    /// setting. `WatchLoop` takes it as a parameter only so tests can use a
    /// short maximum.
    static let defaultLead: TimeInterval = 600

    /// True on the first poll inside the last `lead` before `maxDuration`.
    /// Inclusive at both ends: the stop is strict (`elapsed > maxDuration`), so
    /// a poll exactly at the maximum still records. A poll that lands late in
    /// the window (the Mac slept through its start) still warns; a maximum
    /// that is not longer than the lead never does.
    static func shouldWarn(
        elapsed: TimeInterval,
        maxDuration: TimeInterval,
        lead: TimeInterval,
        alreadyWarned: Bool,
    ) -> Bool {
        guard !alreadyWarned, maxDuration > lead else { return false }
        return elapsed >= maxDuration - lead && elapsed <= maxDuration
    }
}

/// The texts of the notices about a recording's automatic stops that no
/// question precedes: the warning before the maximum length, the notice that
/// the maximum ended the recording, and the notice that a manual recording
/// ended because its app quit. Pure, so tests pin the wording without a
/// notification centre; `WatchLoop` posts them through `AppNotifying`.
///
/// The warning is time sensitive because the person can still act on it
/// (split a long recording at a convenient moment); the two "ended" notices
/// report the past and are standard.
enum RecordingStopNotices {
    typealias Notice = (title: String, body: String, urgency: NotificationUrgency)

    /// "Recording Ends in 10 Minutes": the minutes actually left, rounded up
    /// and never fewer than one.
    static func capWarning(recordingTitle: String, elapsed: TimeInterval, maxDuration: TimeInterval) -> Notice {
        let minutes = max(1, Int(((maxDuration - elapsed) / 60).rounded(.up)))
        let subject = recordingTitle.isEmpty ? "This recording" : quoted(recordingTitle)
        return (
            title: "Recording Ends in \(minutes) \(minutes == 1 ? "Minute" : "Minutes")",
            body: "\(subject) reaches the maximum length of \(lengthPhrase(maxDuration)).",
            urgency: .timeSensitive,
        )
    }

    static func capReached(recordingTitle: String, maxDuration: TimeInterval) -> Notice {
        let subject = recordingTitle.isEmpty ? "The recording" : quoted(recordingTitle)
        return (
            title: "Recording Ended",
            body: "\(subject) reached the maximum length of \(lengthPhrase(maxDuration)).",
            urgency: .standard,
        )
    }

    static func appQuit(recordingTitle: String, appName: String) -> Notice {
        let recording = recordingTitle.isEmpty ? "the recording" : "the recording \(quoted(recordingTitle))"
        return (
            title: "Recording Ended",
            body: "\(appName) quit, so \(recording) ended.",
            urgency: .standard,
        )
    }

    /// The diagnostic line for a warning. The trigger and the whole seconds
    /// left and nothing else, because the line is unconditional and lands in
    /// the log file the user exports: no title, no app name.
    static func capWarningLogLine(trigger: RecordingSidecar.Trigger, remaining: TimeInterval) -> String {
        "recording_cap_warning trigger=\(trigger.rawValue) remaining_s=\(Int(remaining.rounded()))"
    }

    /// The maximum length in words: whole hours when it is a whole number of
    /// them (14 400 s is "4 hours"), whole minutes otherwise.
    static func lengthPhrase(_ duration: TimeInterval) -> String {
        if duration >= 3600, duration.truncatingRemainder(dividingBy: 3600) == 0 {
            return count(Int(duration / 3600), "hour")
        }
        return count(Int((duration / 60).rounded()), "minute")
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }

    private static func quoted(_ title: String) -> String {
        "\"\(title)\""
    }
}
