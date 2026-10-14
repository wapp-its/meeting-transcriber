@testable import MeetingTranscriber
import XCTest

/// The menu's answer to the open recording prompt (`answerParkedConsent`): by
/// the prompt's id, as a tap on its notification answers it, and only while
/// that prompt is the open question. Driven through the real poll loop like
/// the rest of this class.
extension WatchLoopAskBeforeRecordingTests {
    /// A Teams call whose prompt is parked, and the question the loop holds for it.
    private func parkedTeamsPrompt() async throws -> (WatchLoop, ParkingNotifier, Recorders, ConsentQuestion) {
        let notifier = ParkingNotifier()
        let (loop, recorders, _) = try makeLoop(detector: ScriptedDetector([teams]), notifier: notifier)
        loop.start()
        await waitFor(notifier.isParked)
        let question = try XCTUnwrap(loop.pendingConsentQuestion, "precondition: the prompt is open")
        return (loop, notifier, recorders, question)
    }

    func testRecordFromTheMenuStartsTheRecordingAndClosesTheQuestion() async throws {
        let (loop, _, recorders, question) = try await parkedTeamsPrompt()

        XCTAssertTrue(loop.answerParkedConsent(question, granted: true))
        await waitFor(recorders.starts == 1)
        XCTAssertEqual(recorders.starts, 1)
        XCTAssertNil(loop.pendingConsentQuestion)
        loop.stop()
    }

    func testIgnoreFromTheMenuRecordsNothingAndIsNotAskedAgain() async throws {
        let (loop, notifier, recorders, question) = try await parkedTeamsPrompt()

        XCTAssertTrue(loop.answerParkedConsent(question, granted: false))
        await severalPolls()
        XCTAssertEqual(recorders.starts, 0)
        XCTAssertEqual(notifier.prompts.count, 1, "the decline cooldown keeps the same call from being asked again")
        XCTAssertNil(loop.pendingConsentQuestion)
        loop.stop()
    }

    /// The menu repeats the question it shows, so it has to be the prompt that
    /// was posted, and the existing readers still get the app's name.
    func testTheOpenQuestionIsThePostedPrompt() async throws {
        let (loop, notifier, _, question) = try await parkedTeamsPrompt()

        let posted = try XCTUnwrap(notifier.prompts.first)
        XCTAssertEqual(posted.title, question.title)
        XCTAssertEqual(posted.body, question.body)
        XCTAssertEqual(notifier.parkedID, question.id)
        XCTAssertEqual(loop.pendingConsentApp, teams.pattern.appName)
        notifier.answer(.declined)
        loop.stop()
    }

    /// A question that is no longer the open one, from a menu that went stale:
    /// a later prompt about the same call with the same text, and one already
    /// answered in its notification. Neither answers anything.
    func testAQuestionThatIsNotTheOpenOneAnswersNothing() async throws {
        let (loop, notifier, recorders, question) = try await parkedTeamsPrompt()

        let sameText = ConsentQuestion(app: question.app, title: question.title, body: question.body)
        XCTAssertFalse(loop.answerParkedConsent(sameText, granted: true))
        XCTAssertTrue(notifier.isParked, "the open prompt is untouched")
        XCTAssertEqual(loop.pendingConsentQuestion, question)

        notifier.answer(.declined)
        await waitFor(loop.pendingConsentQuestion == nil)
        XCTAssertFalse(loop.answerParkedConsent(question, granted: true), "already answered")
        await severalPolls()
        XCTAssertEqual(recorders.starts, 0)
        loop.stop()
    }

    /// Stop Watching declines the open prompt. A prompt that registers only
    /// afterwards under the same id (registration runs off the main actor) is
    /// no longer the open question, so the menu must not answer it.
    func testAnAnswerAfterStopWatchingAnswersNothing() async throws {
        let (loop, notifier, _, question) = try await parkedTeamsPrompt()
        loop.stop()
        XCTAssertFalse(notifier.isParked, "precondition: Stop Watching declined the prompt")
        let late = Task { await notifier.askToRecord(question) }
        await waitFor(notifier.isParked)

        XCTAssertFalse(loop.answerParkedConsent(question, granted: true))
        XCTAssertTrue(notifier.isParked, "the late prompt is untouched")
        notifier.answer(.declined)
        _ = await late.value
    }

    /// Stop Watching clears the question at once, and the declined prompt's
    /// completion lands a main-actor hop later. A newer question set in
    /// between must survive that completion.
    func testALatePromptCompletionLeavesANewerQuestionOpen() async throws {
        let (loop, _, _, declined) = try await parkedTeamsPrompt()
        let newer = ConsentQuestion(app: declined.app, title: declined.title, body: declined.body)

        loop.stop()
        loop.pendingConsentQuestion = newer
        await severalPolls()
        XCTAssertEqual(loop.pendingConsentQuestion, newer)
    }
}
