@testable import MeetingTranscriber
import XCTest

/// The menu reads and answers the open recording prompt through `AppState`,
/// which routes both to whatever watch loop is current.
@MainActor
final class AppStateConsentPromptTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var testLogDir: URL!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    /// Records the menu's answers and asks nothing.
    private final class AnswerRecordingNotifier: AppNotifying {
        private(set) var answers: [(id: UUID, granted: Bool)] = []

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        func answerConsentPrompt(id: UUID, granted: Bool) -> Bool {
            answers.append((id, granted))
            return true
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        // Its own settings suite and folders, as in `AppStateTests`: the
        // pipeline must not build on the installed app's data.
        testLogDir = try makeTempDirectory(prefix: "AppStateConsentPromptTests")
        let suite = "AppStateConsentPromptTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
            defaultOutputDir: testLogDir.appendingPathComponent("output", isDirectory: true),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
    }

    private func makeState() -> AppState {
        AppState(
            settings: settings,
            notifier: SilentNotifier(),
            pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: testLogDir),
        )
    }

    private func makeStateWithLoop() -> (AppState, WatchLoop, AnswerRecordingNotifier) {
        let state = makeState()
        let notifier = AnswerRecordingNotifier()
        let (loop, _) = makeTestWatchLoop(notifier: notifier)
        state.watching.watchLoop = loop
        return (state, loop, notifier)
    }

    private func makeQuestion() -> ConsentQuestion {
        ConsentQuestion(app: "Zoom", title: "Record Zoom meeting?", body: "A meeting is active in Zoom.")
    }

    func testNoQuestionWithoutAWatchLoop() {
        XCTAssertNil(makeState().pendingConsentQuestion)
    }

    func testTheQuestionFollowsTheLoopsOpenQuestion() {
        let (state, loop, _) = makeStateWithLoop()
        XCTAssertNil(state.pendingConsentQuestion)

        let question = makeQuestion()
        loop.pendingConsentQuestion = question
        XCTAssertEqual(state.pendingConsentQuestion, question)

        loop.pendingConsentQuestion = nil
        XCTAssertNil(state.pendingConsentQuestion)
    }

    func testAnsweringTheOpenQuestionAnswersItsPromptById() {
        let (state, loop, notifier) = makeStateWithLoop()
        let question = makeQuestion()
        loop.pendingConsentQuestion = question

        state.answerConsentQuestion(question, granted: true)
        XCTAssertEqual(notifier.answers.map(\.id), [question.id])
        XCTAssertEqual(notifier.answers.map(\.granted), [true])
    }

    func testAnsweringAnotherQuestionAnswersNothing() {
        let (state, loop, notifier) = makeStateWithLoop()
        loop.pendingConsentQuestion = makeQuestion()

        state.answerConsentQuestion(makeQuestion(), granted: true)
        XCTAssertTrue(notifier.answers.isEmpty)
    }
}
