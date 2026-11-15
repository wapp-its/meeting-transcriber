@testable import MeetingTranscriber
import XCTest

/// What the prompt window shows (issue #99): the open questions, the countdown
/// first, less those closed with ✕, nothing while the setting is off; the time
/// left on the countdown; and the input the app builds for it.
@MainActor
final class PromptWindowContentTests: XCTestCase {
    private let prompt = ConsentQuestion(
        app: "Zoom", title: "Record Zoom meeting?",
        body: "A meeting is active in Zoom. Everyone must agree to being recorded.",
    )
    private let countdown = MeetingEndQuestion(
        id: "meeting-end-1", app: "Teams", title: "Meeting seems to have ended",
        body: "No sign of the Teams call. The recording ends in 2 minutes.",
        deadline: Date(timeIntervalSinceReferenceDate: 800_000_000),
    )

    func testShowsTheOpenQuestionsCountdownFirstAndNothingWhileTheSettingIsOff() {
        let cases: [(name: String, input: PromptWindowInput, shown: [PromptWindowItem])] = [
            ("setting off", PromptWindowInput(enabled: false, consent: prompt, meetingEnd: countdown), []),
            ("nothing open", PromptWindowInput(enabled: true), []),
            ("one prompt", PromptWindowInput(enabled: true, consent: prompt), [.consent(prompt)]),
            ("one countdown", PromptWindowInput(enabled: true, meetingEnd: countdown), [.meetingEnd(countdown)]),
            (
                "both", PromptWindowInput(enabled: true, consent: prompt, meetingEnd: countdown),
                [.meetingEnd(countdown), .consent(prompt)],
            ),
        ]
        for testCase in cases {
            XCTAssertEqual(PromptWindowContent.items(for: testCase.input, hiding: []), testCase.shown, testCase.name)
        }
    }

    /// ✕ hides that question only, and an item is its question's id: a new
    /// prompt about the same app with the same text shows again.
    func testAHiddenIdHidesOnlyItsQuestionAndANewIdShowsAgain() {
        let both = PromptWindowInput(enabled: true, consent: prompt, meetingEnd: countdown)
        XCTAssertEqual(PromptWindowContent.items(for: both, hiding: [.meetingEnd(countdown.id)]), [.consent(prompt)])
        XCTAssertEqual(PromptWindowContent.items(for: both, hiding: [.consent(prompt.id)]), [.meetingEnd(countdown)])

        let again = ConsentQuestion(app: prompt.app, title: prompt.title, body: prompt.body)
        XCTAssertEqual(
            PromptWindowContent.items(for: PromptWindowInput(enabled: true, consent: again), hiding: [.consent(prompt.id)]),
            [.consent(again)],
        )
    }

    /// "Ends in m:ss": whole seconds rounded up, so 0:00 shows only at the
    /// deadline, and never below it.
    func testTimeLeftCountsDownToZeroAndStaysThere() {
        let cases: [(secondsLeft: TimeInterval, shown: String)] = [
            (120, "2:00"), (102, "1:42"), (101.4, "1:42"), (9, "0:09"), (0.4, "0:01"), (0, "0:00"), (-30, "0:00"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptWindowContent.timeLeft(until: countdown.deadline, now: countdown.deadline - testCase.secondsLeft),
                testCase.shown, "\(testCase.secondsLeft) s left",
            )
        }
    }

    /// The app's input follows the setting and the current loop's two
    /// questions, and holds none while nothing is watching.
    func testTheAppsInputFollowsTheSettingAndTheCurrentLoop() throws {
        let state = try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(), settings: makeIsolatedSettings(),
            notifier: SilentNotifier(),
        )
        XCTAssertEqual(state.promptWindowInput, PromptWindowInput(enabled: false), "no loop, setting off by default")

        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        loop.pendingConsentQuestion = prompt
        loop.meetingEndQuestion = countdown
        state.settings.promptWindowEnabled = true
        XCTAssertEqual(state.promptWindowInput, PromptWindowInput(enabled: true, consent: prompt, meetingEnd: countdown))

        state.watching.watchLoop = nil
        XCTAssertEqual(state.promptWindowInput, PromptWindowInput(enabled: true), "loop removed")
    }
}
