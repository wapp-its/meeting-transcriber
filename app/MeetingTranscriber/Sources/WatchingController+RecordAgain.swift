import Foundation

/// The menu's "Record Again (<App>)": a new recording of a meeting whose
/// detected recording was stopped while its call went on. Split out of
/// `WatchingController.swift` to keep that file under the line cap.
@MainActor
extension WatchingController {
    /// Ask the watch loop to record `offer`'s held meeting at its next poll,
    /// and say whether it took the request. False without a loop, and
    /// whenever the loop refuses it (`WatchLoop.recordAgain(identityKey:)`).
    @discardableResult
    func recordAgain(_ offer: RecordAgainOffer) -> Bool {
        watchLoop?.recordAgain(identityKey: offer.identityKey) ?? false
    }
}
