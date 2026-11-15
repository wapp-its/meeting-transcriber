import Foundation

/// The open "Meeting seems to have ended" question, for the prompt window.
/// Single-member accessors like `pendingConsentQuestion`: a SwiftUI body reads
/// these named members, so the `watching.watchLoop?` chains resolve here and
/// not inside its type-check budget.
extension AppState {
    /// The current watch loop's open countdown question, nil when none is open
    /// or nothing is watching.
    var meetingEndQuestion: MeetingEndQuestion? {
        watching.watchLoop?.meetingEndQuestion
    }

    /// Answer `question` as a tap on its notification would. Changes nothing
    /// unless it is still the open question (`WatchLoop.answerMeetingEndQuestion`),
    /// and returns whether it was.
    @discardableResult
    func answerMeetingEndQuestion(_ question: MeetingEndQuestion, answer: MeetingEndAnswer) -> Bool {
        watching.watchLoop?.answerMeetingEndQuestion(question, answer: answer) ?? false
    }
}
