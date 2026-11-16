import Foundation

/// "Record (<App>)": recording the rest of a call whose "Record <App>
/// meeting?" question the person answered "Ignore" while the call goes on.
/// Split out of `WatchLoop.swift` to keep that file under the line cap.
///
/// An Ignore from the notification, the menu or the prompt window books the
/// decline's quiet time as before (`WatchLoop+Consent.swift`): the app stays
/// in detection, its call is passed over for ten minutes, and it is asked
/// about again if the call still runs then. Holding the app instead, as
/// "Record Again" does, would keep that question from coming back. So the
/// Ignore also keeps the meeting it answered (`IgnoredCalls`), and the menu
/// offers it next to "Record Again" (`recordAgainOffers`), except while a
/// question about the same app is open, whose own "Record" is the way then.
///
/// A click goes the way of a "Record Again" click: parked for the next poll,
/// which lifts the entry if the signal is still there, ends the app's quiet
/// time and records the meeting through `runMeeting` like a detected one,
/// without a question. The first watching poll that finds the meeting's
/// signal gone releases the entry, any recording of that app forgets it
/// (`handleMeeting`), and so do "Never for this app" and Stop Watching.
extension WatchLoop {
    /// Keep `meeting` as an ignored call: `finishConsent` calls this for an
    /// Ignore of the question that was still open, while watching runs.
    func rememberIgnoredCall(_ meeting: DetectedMeeting) {
        ignoredCalls.remember(meeting)
        // The identity key only: the meeting title stays out of the log.
        diagnostics.notice("ignore_offer_set app=\(meeting.pattern.identityKey)")
    }

    /// Release every ignored call whose meeting's signal is gone. Run at the
    /// top of every watching poll, next to the holds and before a parked
    /// click is taken.
    func releaseEndedIgnoredCalls() {
        for app in ignoredCalls.release(where: { !detector.isMeetingActive($0) }) {
            diagnostics.notice("ignore_offer_released app=\(app)")
        }
    }

    /// The ignored calls "Record" is offered for now: all but the app whose
    /// question is open.
    var offeredIgnoredMeetings: [DetectedMeeting] {
        let asked = pendingConsentQuestion?.identityKey
        return ignoredCalls.ignoredMeetings.filter { $0.pattern.identityKey != asked }
    }

    /// The parked click's step for an ignored call: lift `app`'s entry if its
    /// meeting still runs, and end the app's quiet time, since the click was
    /// the person's answer for this call only and the app's next call is
    /// asked about as usual. Nil, and nothing changed, when the call ended.
    func takeIgnoredCall(_ app: String) -> DetectedMeeting? {
        guard let meeting = ignoredCalls.lift(app, ifActive: { detector.isMeetingActive($0) }) else {
            diagnostics.notice("record_ignored_dropped app=\(app)")
            return nil
        }
        diagnostics.notice("record_ignored app=\(app)")
        consentPolicy.endSuppression(app: app)
        return meeting
    }
}
