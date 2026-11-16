import Foundation

/// The open "meeting seems to have ended" question as code outside its
/// notification reads and answers it, split out of `WatchLoop.swift` to keep
/// that file under the line cap. `WatchLoop+MeetingEnd.swift` asks, settles
/// and withdraws the question; nothing here changes the countdown.
extension WatchLoop {
    /// The open question's id, nil when none is open. Derived from
    /// `meetingEndQuestion`, so the two cannot disagree: the menu bar icon's
    /// pulse (`AppState.meetingEndCountdownOverlay`) and the answer guard read
    /// it.
    var meetingEndQuestionID: String? {
        meetingEndQuestion?.id
    }

    /// Answer `question` as a tap on its notification would: by its id through
    /// the notifier, which takes the answer's handler from the registry a tap
    /// uses, so each question is answered at most once, whoever answers first.
    /// The answer then lands in `receiveMeetingEndAnswer` and the wait applies
    /// it at its next poll, a late one counting for nothing there. False when
    /// `question` is not the open one (the signal came back, it was answered,
    /// the recording ended) or its notification could not be posted; nothing
    /// is parked then.
    func answerMeetingEndQuestion(_ question: MeetingEndQuestion, answer: MeetingEndAnswer) -> Bool {
        guard meetingEndQuestion == question else { return false }
        return notifier.answerMeetingEndQuestion(id: question.id, answer: answer)
    }
}
