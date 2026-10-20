import CoreGraphics
import Foundation

/// Represents a detected active meeting.
struct DetectedMeeting: Equatable {
    let pattern: AppMeetingPattern
    let windowTitle: String
    let ownerName: String
    let windowPID: pid_t
    let detectedAt: Date

    init(
        pattern: AppMeetingPattern,
        windowTitle: String,
        ownerName: String,
        windowPID: pid_t,
        detectedAt: Date = Date(),
    ) {
        self.pattern = pattern
        self.windowTitle = windowTitle
        self.ownerName = ownerName
        self.windowPID = windowPID
        self.detectedAt = detectedAt
    }
}

/// Protocol for meeting detection strategies.
protocol MeetingDetecting {
    /// Single poll: check for active meetings. Returns a meeting after confirmation threshold.
    func checkOnce() -> DetectedMeeting?

    /// Single poll that never returns a meeting of an app in `excludedApps`:
    /// the app whose consent prompt is open, and the apps waiting for that
    /// question to settle. A poll returns one meeting, so without this those
    /// meetings would come back every poll and could hide another app's call
    /// for as long as the prompt stays open. Hits for an excluded app still
    /// count, so it is confirmed again as soon as the exclusion lifts.
    /// `excludedApps` holds identity keys (`AppMeetingPattern.identityKey`).
    func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting?

    /// Check if a previously detected meeting is still active.
    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool

    /// Every meeting whose call signal is present right now, one per watched
    /// identity (`AppMeetingPattern.identityKey`), each built as detection
    /// builds it (the per-browser identity, the native-process exclusion,
    /// deny-listed identities skipped) but without waiting for confirmation.
    /// Read-only: confirmation counts, cooldowns and once-per-session logging
    /// stay as they are, and a meeting in cooldown is listed too. A watch loop
    /// started by a resume holds these (`WatchLoop.holdSignallingMeetings`).
    func signallingMeetings() -> [DetectedMeeting]

    /// Reset confirmation counters and start cooldown for the given app.
    /// `appName` carries the app's identity key (`AppMeetingPattern.identityKey`),
    /// which is its name only for a built-in app or a browser.
    func reset(appName: String?)
}

extension MeetingDetecting {
    // swiftlint:disable:next unused_declaration
    func reset() {
        reset(appName: nil)
    }

    /// For a detector that reports at most one meeting per poll anyway: drop
    /// it when it is an excluded one. The detectors that can confirm several
    /// apps at once implement the requirement themselves and pass over the
    /// excluded apps to the next confirmed one.
    func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
        guard let meeting = checkOnce(), !excludedApps.contains(meeting.pattern.identityKey) else { return nil }
        return meeting
    }

    /// For a detector that cannot list what signals without confirming it:
    /// the test doubles, and the window-title `MeetingDetector`, which is not
    /// the production detector. It lists nothing, so a resume holds nothing.
    func signallingMeetings() -> [DetectedMeeting] {
        []
    }
}
