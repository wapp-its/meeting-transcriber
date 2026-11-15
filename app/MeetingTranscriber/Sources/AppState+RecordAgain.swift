import Foundation

/// The menu's "Record Again" offers. A single-member accessor like
/// `pendingConsentQuestion`: the menu-bar body reads this named member, so the
/// `watching.watchLoop?` chain resolves here and not inside its type-check
/// budget.
extension AppState {
    /// One per held call the current watch loop can record again, empty when
    /// there is none or nothing is watching.
    var recordAgainOffers: [RecordAgainOffer] {
        watching.watchLoop?.recordAgainOffers ?? []
    }
}
