import Foundation

/// The open "Record <App> meeting?" prompt, for the menu. Single-member
/// accessors like `pipelineQueue` and `canStopRecording`: the menu-bar body
/// reads these named members, so the `watching.watchLoop?` chains resolve here
/// and not inside its type-check budget.
extension AppState {
    /// The current watch loop's open recording prompt, nil when none is open
    /// or nothing is watching.
    var pendingConsentQuestion: ConsentQuestion? {
        watching.watchLoop?.pendingConsentQuestion
    }

    /// Answer `question` from the menu. Changes nothing unless it is still the
    /// open prompt (`WatchLoop.answerParkedConsent`); a menu that went stale
    /// has nothing to do with the result.
    func answerConsentQuestion(_ question: ConsentQuestion, granted: Bool) {
        _ = watching.watchLoop?.answerParkedConsent(question, granted: granted)
    }
}
