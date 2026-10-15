import Foundation

/// The open "Record <App> meeting?" prompt, for the menu and the menu bar
/// icon. Single-member accessors like `pipelineQueue` and `canStopRecording`:
/// the menu-bar body reads these named members, so the `watching.watchLoop?`
/// chains resolve here and not inside its type-check budget.
extension AppState {
    /// The current watch loop's open recording prompt, nil when none is open
    /// or nothing is watching.
    var pendingConsentQuestion: ConsentQuestion? {
        watching.watchLoop?.pendingConsentQuestion
    }

    /// Whether a question waits for the user's answer: the single input for
    /// the question mark on the menu bar icon. Today that is the open
    /// recording prompt; another question for the user (the "meeting seems
    /// to have ended" question, say) can feed the same input later.
    var awaitingUserAnswer: Bool {
        pendingConsentQuestion != nil
    }

    /// Answer `question` from the menu or the Record Meeting window, the
    /// window's Record with its `protocolOptions`. Changes nothing unless it is
    /// still the open prompt (`WatchLoop.answerParkedConsent`), and returns
    /// whether it was: a menu that went stale has nothing to do with the
    /// result, while the window says the question is no longer open.
    @discardableResult
    func answerConsentQuestion(_ question: ConsentQuestion, granted: Bool, protocolOptions: MeetingProtocolOptions? = nil) -> Bool {
        watching.watchLoop?.answerParkedConsent(question, granted: granted, protocolOptions: protocolOptions) ?? false
    }
}
