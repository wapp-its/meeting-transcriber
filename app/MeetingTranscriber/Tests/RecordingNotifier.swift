@testable import MeetingTranscriber

// MARK: - AppNotifying spy

/// Records all notify() calls for assertions.
///
/// Its own file rather than another block in `TestHelpers.swift`, which sits on
/// the 600-line `file_length` cap: this double grows whenever `AppNotifying`
/// does, so it is the piece under pressure.
final class RecordingNotifier: AppNotifying {
    private(set) var calls: [(title: String, body: String, urgency: NotificationUrgency)] = []

    /// What `notificationVisibility()` reports. Defaults to the protocol's
    /// own default so existing users of this double are unaffected.
    var reportedVisibility: NotificationVisibility = .unread

    /// How every consent prompt is answered. Defaults to the protocol's own
    /// default, a decline, so a detected meeting records only when a test
    /// says the user answered Record.
    let consentAnswer: ConsentAnswer

    init(consentAnswer: ConsentAnswer = .declined) {
        self.consentAnswer = consentAnswer
    }

    func notify(title: String, body: String, urgency: NotificationUrgency) {
        calls.append((title: title, body: body, urgency: urgency))
    }

    // swiftlint:disable async_without_await
    @MainActor
    func notificationVisibility() async -> NotificationVisibility {
        reportedVisibility
    }

    @MainActor
    func askToRecord(title _: String, body _: String) async -> ConsentAnswer {
        consentAnswer
    }

    // swiftlint:enable async_without_await

    // MARK: - Meeting-end question

    /// Every "meeting seems to have ended" question asked, in order.
    private(set) var meetingEndQuestions: [(id: String, title: String, body: String)] = []
    /// The ids taken back, in order.
    private(set) var withdrawnMeetingEndQuestions: [String] = []
    /// Kept after a withdrawal on purpose, unlike the real notifier: a test can
    /// then deliver a stale answer and show the loop itself ignores it.
    private var meetingEndHandlers: [String: MeetingEndQuestionHandler] = [:]

    @MainActor
    func askBeforeEndingRecording(
        id: String,
        title: String,
        body: String,
        onAnswer: @escaping MeetingEndQuestionHandler,
    ) {
        meetingEndQuestions.append((id: id, title: title, body: body))
        meetingEndHandlers[id] = onAnswer
    }

    func withdrawMeetingEndQuestion(id: String) {
        withdrawnMeetingEndQuestions.append(id)
    }

    /// Answer question `id` the way a tap on one of its actions would.
    @MainActor
    func answerMeetingEndQuestion(_ id: String, with answer: MeetingEndAnswer) {
        meetingEndHandlers[id]?(answer)
    }
}
