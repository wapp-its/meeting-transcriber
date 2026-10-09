import Foundation

/// The "Record <App> meeting?" prompt the consent gate has open. Built once,
/// when the gate posts the prompt, so `title` and `body` are exactly what the
/// notification shows and the menu can repeat them word for word.
///
/// `id` is also the prompt's id in `ConsentPromptCoordinator` and the
/// notification's identifier, which is what lets the menu answer exactly this
/// prompt the way a tap on its notification does. Equality includes it, so a
/// later prompt about the same app, with the same text, is a different
/// question, and an answer meant for the earlier one cannot reach it.
struct ConsentQuestion: Equatable, Sendable {
    let id: UUID
    /// The meeting pattern's `appName`: the name detection exclusion and the
    /// re-prompt cooldowns key on, not the label shown in the text.
    let app: String
    let title: String
    let body: String

    init(app: String, title: String, body: String, id: UUID = UUID()) {
        self.id = id
        self.app = app
        self.title = title
        self.body = body
    }
}
