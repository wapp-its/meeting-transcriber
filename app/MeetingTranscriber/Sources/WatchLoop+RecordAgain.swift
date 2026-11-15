import Foundation

/// One "Record Again" item: an app held after its detected recording was
/// ended while its call went on.
struct RecordAgainOffer: Equatable {
    /// The app's `AppMeetingPattern.identityKey`, which a click asks for.
    let identityKey: String
    /// The app as a person reads it.
    let appName: String
}

/// "Record Again": recording the rest of a call whose detected recording was
/// stopped by hand, or on the long-silence question, while the call went on.
/// Split out of `WatchLoop.swift` to keep that file under the line cap.
///
/// Such a stop holds the app out of detection until its signal has gone once
/// (`WatchLoop+RedetectionHold.swift`), because the detector cannot tell that
/// call from the app's next one. The person can, and a click asks for a new
/// recording of the held meeting. The click is parked for the watch loop's
/// next poll, since recordings start there and nowhere else, as an approved
/// consent answer is. That poll lifts the hold and records the held meeting
/// through `runMeeting` like a detected one, so the new recording ends with
/// the call by every rule a detected recording ends by, and no hold is left
/// afterwards unless it is again ended while the signal stays. There is no
/// consent question and no confirmation poll: the click is the answer.
extension WatchLoop {
    /// One offer per hold "Record Again" may be offered for, sorted by the
    /// name a person reads; empty unless the loop is watching. Derived from
    /// the loop's observable state, so the menu follows every hold placed,
    /// released or lifted.
    var recordAgainOffers: [RecordAgainOffer] {
        guard state == .watching else { return [] }
        return redetectionHolds.offeredMeetings
            .map { meeting in
                // The consent prompt's fallback, so an empty name never shows.
                let name = meeting.pattern.appName
                return RecordAgainOffer(identityKey: meeting.pattern.identityKey, appName: name.isEmpty ? meeting.ownerName : name)
            }
            .sorted { ($0.appName, $0.identityKey) < ($1.appName, $1.identityKey) }
    }

    /// Ask for a new recording of the meeting held for `identityKey` at the
    /// next poll, and say whether the request was taken. Refused unless the
    /// loop is watching and that app's hold is offered, so a click from a menu
    /// that went stale changes nothing. Asked again before that poll, the one
    /// request stands; a click for another app is refused then, since that
    /// poll starts one recording.
    @discardableResult
    func recordAgain(identityKey: String) -> Bool {
        guard state == .watching,
              redetectionHolds.offeredMeetings.contains(where: { $0.pattern.identityKey == identityKey })
        else { return false }
        if let parked = recordAgainRequest { return parked == identityKey }
        recordAgainRequest = identityKey
        return true
    }

    /// The poll's step for a parked click: the held meeting to record now, or
    /// nil. Run right after the poll released the holds whose signal is gone,
    /// so a click for a call that ended since finds its hold gone and is
    /// dropped.
    func takeRecordAgain() -> DetectedMeeting? {
        guard let app = recordAgainRequest else { return nil }
        recordAgainRequest = nil
        guard let meeting = redetectionHolds.liftOffered(app, ifActive: { detector.isMeetingActive($0) }) else {
            diagnostics.notice("record_again_dropped app=\(app)")
            return nil
        }
        // The identity key only: the meeting title stays out of the log. The
        // line also ends the hold, so no `redetect_hold_released` follows.
        diagnostics.notice("record_again app=\(app)")
        // An approval is not a reservation (`WatchLoop+Consent.swift`). Kept
        // past this recording, it would let a later call of that app record on
        // an answer about this one, since `isMeetingActive` checks the app,
        // not the call. Dropped without a decline, so if the call still runs
        // once this recording ends, it is detected and asked about again.
        _ = takeApprovedConsent()
        // The stop before this reset the app's count and started its cooldown;
        // a new-call split relies on the recorded app's count standing.
        detector.markConfirmed(appName: app)
        return meeting
    }
}
