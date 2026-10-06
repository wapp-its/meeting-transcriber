@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// The "meeting seems to have ended" question as `NotificationManager` posts
/// and resolves it: its own category with two actions, answered at most once,
/// never after it was withdrawn, and never answered at all when it could not
/// be shown, which leaves the watch loop's countdown to end the recording.
@MainActor
final class NotificationManagerMeetingEndTests: XCTestCase {
    /// Collects the answers a question's handler receives.
    @MainActor
    private final class Answers {
        var received: [MeetingEndAnswer] = []
    }

    private func makeManager(setUp: Bool = true) -> (NotificationManager, FakeNotificationScheduler) {
        let fake = FakeNotificationScheduler()
        let canDeliver: @Sendable () -> Bool = { true }
        let manager = NotificationManager(scheduler: fake, canDeliver: canDeliver)
        if setUp { manager.setUp() }
        return (manager, fake)
    }

    private func ask(_ manager: NotificationManager, id: String = "q1") -> Answers {
        let answers = Answers()
        manager.askBeforeEndingRecording(id: id, title: "Meeting seems to have ended", body: "Ends in 2 minutes.") { answer in
            answers.received.append(answer)
        }
        return answers
    }

    // MARK: - Category and mapping

    func testTheCategoryOffersKeepRecordingAndStopNowWithoutActivatingTheApp() {
        let category = NotificationManager.makeMeetingEndCategory()
        XCTAssertEqual(category.identifier, NotificationManager.meetingEndCategoryID)
        XCTAssertEqual(
            category.actions.map(\.identifier),
            [NotificationManager.keepRecordingActionID, NotificationManager.stopNowActionID],
        )
        XCTAssertEqual(category.actions.map(\.title), ["Keep recording", "Stop now"])
        XCTAssertFalse(category.actions.contains { $0.options.contains(.foreground) })
    }

    /// Only the two actions answer. A body tap, a dismissal and anything else
    /// are no answer, so nothing but an explicit Keep keeps the room recorded.
    func testOnlyTheTwoActionsAreAnswers() {
        let cases: [(String, MeetingEndAnswer?)] = [
            (NotificationManager.keepRecordingActionID, .keepRecording),
            (NotificationManager.stopNowActionID, .stopNow),
            (UNNotificationDefaultActionIdentifier, nil),
            (UNNotificationDismissActionIdentifier, nil),
            (NotificationManager.recordActionID, nil),
            ("something-else", nil),
        ]
        for (action, expected) in cases {
            XCTAssertEqual(NotificationManager.meetingEndAnswer(for: action), expected, action)
        }
    }

    // MARK: - Posting and answering

    func testTheQuestionIsPostedTimeSensitiveAndAnsweredAtMostOnce() async throws {
        let (manager, fake) = makeManager()
        let answers = ask(manager)

        let posted = try XCTUnwrap(fake.added.first)
        XCTAssertEqual(posted.identifier, "q1")
        XCTAssertEqual(posted.content.categoryIdentifier, NotificationManager.meetingEndCategoryID)
        XCTAssertEqual(posted.content.interruptionLevel, .timeSensitive, "a question with a deadline breaks through Focus")

        await manager.answerMeetingEndQuestion(id: "q1", actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(answers.received, [], "a body tap is no answer")
        await manager.answerMeetingEndQuestion(id: "q1", actionIdentifier: NotificationManager.keepRecordingActionID)
        await manager.answerMeetingEndQuestion(id: "q1", actionIdentifier: NotificationManager.stopNowActionID)
        XCTAssertEqual(answers.received, [.keepRecording], "answered once, by the first action")
    }

    /// R3: a withdrawn question leaves Notification Center, and a tap that
    /// still reaches the app changes nothing.
    func testAWithdrawnQuestionIsRemovedAndNeverAnswered() async {
        let (manager, fake) = makeManager()
        let answers = ask(manager)

        manager.withdrawMeetingEndQuestion(id: "q1")
        await manager.answerMeetingEndQuestion(id: "q1", actionIdentifier: NotificationManager.stopNowActionID)

        XCTAssertEqual(fake.removedIdentifiers, ["q1"], "out of Notification Center")
        XCTAssertEqual(fake.removedPendingIdentifiers, ["q1"], "and never shown if it had not appeared yet")
        XCTAssertEqual(answers.received, [])
    }

    /// R5: a question that cannot be shown is not posted and can never be
    /// answered, so the countdown, not the notification, decides.
    func testAQuestionThatCannotBeShownIsNeitherPostedNorAnswerable() async {
        let (manager, fake) = makeManager(setUp: false)
        let answers = ask(manager)

        await manager.answerMeetingEndQuestion(id: "q1", actionIdentifier: NotificationManager.keepRecordingActionID)

        XCTAssertTrue(fake.added.isEmpty)
        XCTAssertEqual(answers.received, [])
        #if !APPSTORE
            XCTAssertEqual(manager.recentNotifications.map(\.posted), [false], "the decision to ask is still on record")
        #endif
    }
}
