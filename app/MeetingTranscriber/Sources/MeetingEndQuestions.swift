import Foundation

/// Delivers the answer to a "meeting seems to have ended" question.
typealias MeetingEndQuestionHandler = @MainActor @Sendable (MeetingEndAnswer) -> Void

extension AppNotifying {
    /// Nothing is shown by default, so nothing is ever answered and the
    /// caller's countdown ends the recording. That is the safe side: a question
    /// nobody saw must never keep the room recorded.
    @MainActor
    func askBeforeEndingRecording(
        id _: String,
        title _: String,
        body _: String,
        // Spelled exactly as the requirement, or the analyzer reads this
        // default as an unused overload rather than its witness.
        // swiftlint:disable:next unneeded_escaping
        onAnswer _: @escaping MeetingEndQuestionHandler,
    ) {}

    func withdrawMeetingEndQuestion(id _: String) {}
}

/// The open "meeting seems to have ended" questions, by notification id.
///
/// Holds no deadline of its own: the watch loop owns the countdown, and every
/// way out of its wait withdraws the question, so an entry lives exactly as
/// long as the question is open. A withdrawn question is forgotten here, which
/// is what keeps a tap on a stale notification from reaching the loop.
///
/// `@unchecked Sendable`: `handlers` is guarded by `lock`, because the
/// notification delegate answers from an arbitrary queue.
final class MeetingEndQuestions: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: MeetingEndQuestionHandler] = [:]

    func register(id: String, handler: @escaping MeetingEndQuestionHandler) {
        lock.lock(); handlers[id] = handler; lock.unlock()
    }

    /// Remove and return the question's handler. Nil once it was answered or
    /// withdrawn, so each question is answered at most once.
    func take(id: String) -> MeetingEndQuestionHandler? {
        lock.lock(); defer { lock.unlock() }
        return handlers.removeValue(forKey: id)
    }
}
