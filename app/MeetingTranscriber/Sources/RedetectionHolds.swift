import Foundation

/// The apps kept out of meeting detection until their call signal has gone
/// once, each with the meeting whose signal decides that. Keyed by
/// `AppMeetingPattern.identityKey`, the key
/// `MeetingDetecting.checkOnce(excluding:)` takes.
///
/// A hold also says whether "Record Again" may be offered for it: yes for one
/// placed when a detected meeting's recording ended while its signal stayed,
/// no for one placed when watching resumed after a manual recording.
///
/// A pure value: it never asks a detector. The caller passes the check to
/// `release(where:)` and `liftOffered(_:ifActive:)`, so when a hold ends is
/// decided by the loop that polls, and the holds themselves can be tested
/// without one.
struct RedetectionHolds: Equatable {
    private var meetings: [String: DetectedMeeting] = [:]
    /// The held apps "Record Again" may be offered for.
    private var offered: Set<String> = []

    var heldApps: Set<String> {
        Set(meetings.keys)
    }

    /// The held meetings "Record Again" may be offered for, sorted by app.
    var offeredMeetings: [DetectedMeeting] {
        offered.sorted().compactMap { meetings[$0] }
    }

    /// Hold `meeting`'s app, offered for "Record Again" or not. True when the
    /// app was not held yet; holding it again keeps the one entry it has, and
    /// whether it is offered.
    mutating func hold(_ meeting: DetectedMeeting, offered isOffered: Bool = false) -> Bool {
        let app = meeting.pattern.identityKey
        guard meetings[app] == nil else { return false }
        meetings[app] = meeting
        if isOffered { offered.insert(app) }
        return true
    }

    /// Remove every hold whose meeting `ended` reports over, and return those
    /// apps, sorted.
    mutating func release(where ended: (DetectedMeeting) -> Bool) -> [String] {
        let apps = meetings.filter { ended($0.value) }.keys.sorted()
        for app in apps {
            meetings[app] = nil
            offered.remove(app)
        }
        return apps
    }

    /// Lift `app`'s hold and hand back its meeting, if the hold may be offered
    /// and `isActive` says its meeting still runs. Otherwise nothing changes
    /// and the answer is nil. Every other hold stays.
    mutating func liftOffered(_ app: String, ifActive isActive: (DetectedMeeting) -> Bool) -> DetectedMeeting? {
        guard offered.contains(app), let meeting = meetings[app], isActive(meeting) else { return nil }
        meetings[app] = nil
        offered.remove(app)
        return meeting
    }

    mutating func removeAll() {
        meetings.removeAll()
        offered.removeAll()
    }
}
