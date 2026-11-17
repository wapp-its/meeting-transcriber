import Foundation

/// The calls a person answered "Ignore" for, each with the meeting the
/// question was about, while their signal stays. Keyed by
/// `AppMeetingPattern.identityKey`, the key the consent gate files its quiet
/// time under, so a browser meeting is kept per concrete browser.
///
/// Unlike a re-detection hold (`RedetectionHolds`) an entry keeps nothing out
/// of detection: the app's call is still detected every poll and passed over
/// by the decline's quiet time, and asked about again when that ends. The
/// entry only says that "Record (<App>)" may be offered for it.
///
/// A pure value: it never asks a detector. The caller passes the check to
/// `release(where:)` and `lift(_:ifActive:)`, so when an entry ends is decided
/// by the loop that polls, and the entries themselves can be tested without
/// one.
struct IgnoredCalls: Equatable {
    private var meetings: [String: DetectedMeeting] = [:]

    /// The ignored meetings, sorted by app.
    var ignoredMeetings: [DetectedMeeting] {
        meetings.keys.sorted().compactMap { meetings[$0] }
    }

    /// Keep `meeting` for its app. A later Ignore for the same app replaces
    /// the entry with the newer meeting.
    mutating func remember(_ meeting: DetectedMeeting) {
        meetings[meeting.pattern.identityKey] = meeting
    }

    /// Remove every entry whose meeting `ended` reports over, and return
    /// those apps, sorted.
    mutating func release(where ended: (DetectedMeeting) -> Bool) -> [String] {
        let apps = meetings.filter { ended($0.value) }.keys.sorted()
        for app in apps {
            meetings[app] = nil
        }
        return apps
    }

    /// Remove `app`'s entry and hand back its meeting, if `isActive` says
    /// that meeting still runs. Otherwise nothing changes and the answer is
    /// nil. Every other entry stays.
    mutating func lift(_ app: String, ifActive isActive: (DetectedMeeting) -> Bool) -> DetectedMeeting? {
        guard let meeting = meetings[app], isActive(meeting) else { return nil }
        meetings[app] = nil
        return meeting
    }

    /// Remove `app`'s entry, if it has one.
    mutating func forget(_ app: String) {
        meetings[app] = nil
    }

    mutating func removeAll() {
        meetings.removeAll()
    }
}
