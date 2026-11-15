@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The prompt window's view (issue #99): one wiring test per control, found by
/// its `A11yID`, and the texts and layout the accepted boards draw. Which
/// questions it gets is `PromptWindowContent`'s decision.
@MainActor
final class PromptWindowViewTests: XCTestCase {
    /// What the view's controls asked for, in order.
    private final class Performed {
        var actions: [PromptWindowAction] = []
    }

    private let prompt = ConsentQuestion(
        app: "Zoom", title: "Record Zoom meeting?",
        body: "A meeting is active in Zoom. Everyone must agree to being recorded.",
    )
    private let countdown = MeetingEndQuestion(
        id: "meeting-end-1", app: "Teams", title: "Meeting seems to have ended",
        body: "No sign of the Teams call. The recording ends in 2 minutes.",
        deadline: Date(timeIntervalSinceReferenceDate: 800_000_000),
    )

    private func makeView(
        _ items: [PromptWindowItem], secondsLeft: TimeInterval = 102, performed: Performed = Performed(),
    ) -> PromptWindowView {
        PromptWindowView(items: items, now: countdown.deadline - secondsLeft) { performed.actions.append($0) }
    }

    /// The labels of the buttons that have one, in document order.
    private func buttonLabels(of view: PromptWindowView) throws -> [String] {
        try view.inspect().findAll(ViewType.Button.self).compactMap { try? $0.find(ViewType.Text.self).string() }
    }

    func testEachControlAsksForItsAnswerOrForHidingAndNothingElse() throws {
        let cases: [(id: String, action: PromptWindowAction)] = [
            (A11yID.promptWindowRecord, .answerConsent(prompt, .granted)),
            (A11yID.promptWindowIgnore, .answerConsent(prompt, .declined)),
            (A11yID.promptWindowNever, .answerConsent(prompt, .never)),
            (A11yID.promptWindowHidePrompt, .hide(.consent(prompt.id))),
            (A11yID.promptWindowKeepRecording, .answerMeetingEnd(countdown, .keepRecording)),
            (A11yID.promptWindowStopNow, .answerMeetingEnd(countdown, .stopNow)),
            (A11yID.promptWindowHideCountdown, .hide(.meetingEnd(countdown.id))),
        ]
        for testCase in cases {
            let performed = Performed()
            let view = makeView([.meetingEnd(countdown), .consent(prompt)], performed: performed)

            try view.inspect().find(viewWithAccessibilityIdentifier: testCase.id).button().tap()

            XCTAssertEqual(performed.actions, [testCase.action], testCase.id)
        }
    }

    func testEachHideButtonIsLabelledForVoiceOver() throws {
        let view = makeView([.meetingEnd(countdown), .consent(prompt)])
        for id in [A11yID.promptWindowHidePrompt, A11yID.promptWindowHideCountdown] {
            let label = try view.inspect().find(viewWithAccessibilityIdentifier: id).accessibilityLabel().string()
            XCTAssertEqual(label, "Hide this question", id)
        }
    }

    /// Title and body as posted, the buttons in the drawn order, and the
    /// microphone tile only while one question shows.
    func testEachQuestionShowsItsTextAndItsButtonsInTheDrawnOrder() throws {
        let alone = makeView([.consent(prompt)])
        XCTAssertNoThrow(try alone.inspect().find(text: prompt.title))
        XCTAssertNoThrow(try alone.inspect().find(text: prompt.body))
        XCTAssertEqual(try buttonLabels(of: alone), ["Never for this app", "Ignore", "Record"])
        XCTAssertNoThrow(try alone.inspect().find(ViewType.Image.self) { try $0.actualImage().name() == "mic.fill" })

        let countdownAlone = makeView([.meetingEnd(countdown)])
        XCTAssertNoThrow(try countdownAlone.inspect().find(text: countdown.title))
        XCTAssertNoThrow(try countdownAlone.inspect().find(text: countdown.body))
        XCTAssertEqual(try buttonLabels(of: countdownAlone), ["Stop now", "Keep recording"])

        let both = makeView([.meetingEnd(countdown), .consent(prompt)])
        XCTAssertEqual(try buttonLabels(of: both), ["Stop now", "Keep recording", "Never for this app", "Ignore", "Record"])
        XCTAssertEqual(try both.inspect().findAll(ViewType.Divider.self).count, 1, "a thin line between the two")
        XCTAssertThrowsError(
            try both.inspect().find(ViewType.Image.self) { try $0.actualImage().name() == "mic.fill" },
            "no tile with both open",
        )
    }

    /// Record and Keep recording are the prominent buttons, and they draw in
    /// the accent colour although the panel is never the key window: a never-key
    /// panel of an inactive app draws `.borderedProminent` like a plain button
    /// unless its controls are told to draw as active.
    func testTheProminentButtonsDrawAsInAnActiveWindow() throws {
        let view = makeView([.meetingEnd(countdown), .consent(prompt)])
        for id in [A11yID.promptWindowRecord, A11yID.promptWindowKeepRecording] {
            let button = try view.inspect().find(viewWithAccessibilityIdentifier: id)
            XCTAssertTrue(try button.buttonStyle() is BorderedProminentButtonStyle, id)
        }
        XCTAssertEqual(try view.inspect().vStack().environment(\.controlActiveState), .key)
    }

    func testTheCountdownShowsTheTimeLeftAndZeroAfterTheDeadline() throws {
        let running = makeView([.meetingEnd(countdown)], secondsLeft: 102)
        XCTAssertNoThrow(try running.inspect().find(text: "Ends in"))
        XCTAssertNoThrow(try running.inspect().find(text: "1:42"))

        let over = makeView([.meetingEnd(countdown)], secondsLeft: -3)
        XCTAssertNoThrow(try over.inspect().find(text: "0:00"))
    }
}
