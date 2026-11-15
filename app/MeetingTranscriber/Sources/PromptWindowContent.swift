// What the prompt window below the menu bar icon shows (issue #99): the open
// questions, the countdown first, less those closed with ✕. Pure, so every
// case is pinned without a window; `PromptWindowController` only renders it.
import Foundation

/// One question the prompt window shows. An item is its question's id, never
/// its app or its text, so a new question about the same app with the same
/// text is a new item, which shows again after a ✕ on the earlier one.
enum PromptWindowItem: Equatable {
    case meetingEnd(MeetingEndQuestion)
    case consent(ConsentQuestion)

    /// The id of a question of either kind.
    enum QuestionID: Hashable {
        case meetingEnd(String)
        case consent(UUID)
    }

    var id: QuestionID {
        switch self {
        case let .meetingEnd(question): .meetingEnd(question.id)
        case let .consent(question): .consent(question.id)
        }
    }
}

/// What the prompt window is built from (`AppState.promptWindowInput`).
struct PromptWindowInput: Equatable {
    /// Settings → General → "Show prompts below the menu bar icon".
    var enabled: Bool
    /// The open "Record <App> meeting?" prompt.
    var consent: ConsentQuestion?
    /// The open "Meeting seems to have ended" countdown.
    var meetingEnd: MeetingEndQuestion?

    /// The open questions, the countdown first, whether the window is on or
    /// not.
    var questions: [PromptWindowItem] {
        [meetingEnd.map(PromptWindowItem.meetingEnd), consent.map(PromptWindowItem.consent)].compactMap(\.self)
    }
}

enum PromptWindowContent {
    /// The questions the window shows, in order; empty when it must close:
    /// while the setting is off, and when every open question is `hidden`.
    static func items(for input: PromptWindowInput, hiding hidden: Set<PromptWindowItem.QuestionID>) -> [PromptWindowItem] {
        guard input.enabled else { return [] }
        return input.questions.filter { !hidden.contains($0.id) }
    }

    /// The countdown's time left as "m:ss": whole seconds rounded up, so
    /// "0:00" shows from the deadline on and never anything below it.
    static func timeLeft(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
