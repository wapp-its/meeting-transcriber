import Foundation

/// The "Meeting seems to have ended" question the watch loop has open. Built
/// once, when the loop asks, so `title` and `body` are exactly what the
/// notification shows and a window can repeat them word for word.
///
/// `id` is also the notification's identifier and the key of its answer in
/// `MeetingEndQuestions`, which is what lets code outside the notification
/// answer exactly this question the way a tap on it does. `deadline` is the
/// one the loop's countdown ends the recording at (`PendingMeetingEnd`), so a
/// view counting down to it shows the time the loop enforces. Equality
/// includes the id, so a later question with the same text is a different
/// question, and an answer meant for the earlier one cannot reach it.
struct MeetingEndQuestion: Equatable, Sendable {
    let id: String
    /// The app named in the text: the meeting pattern's `appName`, or the
    /// window owner's name when that is empty.
    let app: String
    let title: String
    let body: String
    let deadline: Date
}
