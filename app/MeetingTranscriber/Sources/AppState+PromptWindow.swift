import Foundation

/// What the prompt window below the menu bar icon is built from (issue #99).
/// One member, like `pendingConsentQuestion`: the wiring follows it with
/// `onChange`, and the window controller reads it again whenever it renders,
/// so a change still queued behind the observer can never show a question
/// after the setting went off.
extension AppState {
    /// The setting and the current watch loop's two open questions; no
    /// question while nothing is watching.
    var promptWindowInput: PromptWindowInput {
        PromptWindowInput(
            enabled: settings.promptWindowEnabled, consent: pendingConsentQuestion, meetingEnd: meetingEndQuestion,
        )
    }
}
