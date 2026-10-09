import Foundation

/// The apps kept out of meeting detection until their call signal has gone
/// once, each with the meeting whose signal decides that. Keyed by the
/// detector identity (`AppMeetingPattern.appName`), the name
/// `MeetingDetecting.checkOnce(excluding:)` takes.
///
/// A pure value: it never asks a detector. The caller passes the check to
/// `release(where:)`, so when a hold ends is decided by the loop that polls,
/// and the holds themselves can be tested without one.
struct RedetectionHolds: Equatable {
    private var meetings: [String: DetectedMeeting] = [:]

    var heldApps: Set<String> {
        Set(meetings.keys)
    }

    /// Hold `meeting`'s app. True when the app was not held yet; holding it
    /// again keeps the one entry it has.
    mutating func hold(_ meeting: DetectedMeeting) -> Bool {
        let app = meeting.pattern.appName
        guard meetings[app] == nil else { return false }
        meetings[app] = meeting
        return true
    }

    /// Remove every hold whose meeting `ended` reports over, and return those
    /// apps, sorted.
    mutating func release(where ended: (DetectedMeeting) -> Bool) -> [String] {
        let apps = meetings.filter { ended($0.value) }.keys.sorted()
        for app in apps {
            meetings[app] = nil
        }
        return apps
    }

    mutating func removeAll() {
        meetings.removeAll()
    }
}
