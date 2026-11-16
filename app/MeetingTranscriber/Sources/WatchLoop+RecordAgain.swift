import Foundation

/// One item under the menu's status line that records the rest of a call: an
/// app held after its detected recording was ended while its call went on
/// ("Record Again"), or an app whose question was answered "Ignore" while its
/// call goes on ("Record", `WatchLoop+RecordIgnored.swift`).
struct RecordAgainOffer: Equatable {
    enum Kind: Equatable {
        /// A held call: "Record Again (<App>)".
        case heldCall
        /// An ignored call: "Record (<App>)".
        case ignoredCall
    }

    /// The app's `AppMeetingPattern.identityKey`, which a click asks for.
    let identityKey: String
    /// The app as a person reads it.
    let appName: String
    var kind: Kind = .heldCall
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
///
/// A click on "Record (<App>)" for an ignored call takes the same way; only
/// the entry it lifts differs (`WatchLoop+RecordIgnored.swift`).
extension WatchLoop {
    /// One offer per hold "Record Again" may be offered for and per ignored
    /// call "Record" may be offered for, sorted by the name a person reads;
    /// empty unless the loop is watching. Derived from the loop's observable
    /// state, so the menu follows every entry placed, released or lifted.
    /// An app never has both: a hold follows a recording, and any recording
    /// of an app forgets its ignored call.
    var recordAgainOffers: [RecordAgainOffer] {
        guard state == .watching else { return [] }
        let held = redetectionHolds.offeredMeetings.map { Self.offer(for: $0, kind: .heldCall) }
        let ignored = offeredIgnoredMeetings.map { Self.offer(for: $0, kind: .ignoredCall) }
        return (held + ignored).sorted { ($0.appName, $0.identityKey) < ($1.appName, $1.identityKey) }
    }

    private static func offer(for meeting: DetectedMeeting, kind: RecordAgainOffer.Kind) -> RecordAgainOffer {
        // The consent prompt's fallback, so an empty name never shows.
        let name = meeting.pattern.appName
        return RecordAgainOffer(identityKey: meeting.pattern.identityKey, appName: name.isEmpty ? meeting.ownerName : name, kind: kind)
    }

    /// Ask for a new recording of the meeting offered for `identityKey` at
    /// the next poll, and say whether the request was taken. Refused unless
    /// that app is offered now (`recordAgainOffers`, empty unless the loop
    /// is watching), so a click from a menu that went stale changes nothing.
    /// Asked again before that poll, the one request stands; a click for
    /// another app is refused then, since that poll starts one recording.
    @discardableResult
    func recordAgain(identityKey: String) -> Bool {
        guard let offer = recordAgainOffers.first(where: { $0.identityKey == identityKey }) else { return false }
        if let parked = recordAgainRequest { return parked.identityKey == identityKey }
        recordAgainRequest = offer
        return true
    }

    /// The poll's step for a parked click: the held or ignored meeting to
    /// record now, or nil. Run right after the poll released the holds and
    /// the ignored calls whose signal is gone, so a click for a call that
    /// ended since finds its entry gone and is dropped.
    func takeRecordAgain() -> DetectedMeeting? {
        guard let request = recordAgainRequest else { return nil }
        recordAgainRequest = nil
        let app = request.identityKey
        let taken = switch request.kind {
        case .heldCall: takeHeldCall(app)
        case .ignoredCall: takeIgnoredCall(app)
        }
        guard let meeting = taken else { return nil }
        // An approval is not a reservation (`WatchLoop+Consent.swift`). Kept
        // past this recording, it would let a later call of that app record on
        // an answer about this one, since `isMeetingActive` checks the app,
        // not the call. Dropped without a decline, so if the call still runs
        // once this recording ends, it is detected and asked about again.
        _ = takeApprovedConsent()
        // The stop or the Ignore before this reset the app's count and
        // started its cooldown; a new-call split relies on the recorded app's
        // count standing.
        detector.markConfirmed(appName: app)
        return meeting
    }

    /// Lift `app`'s offered hold if its meeting still runs.
    private func takeHeldCall(_ app: String) -> DetectedMeeting? {
        guard let meeting = redetectionHolds.liftOffered(app, ifActive: { detector.isMeetingActive($0) }) else {
            diagnostics.notice("record_again_dropped app=\(app)")
            return nil
        }
        // The identity key only: the meeting title stays out of the log. The
        // line also ends the hold, so no `redetect_hold_released` follows.
        diagnostics.notice("record_again app=\(app)")
        return meeting
    }
}
