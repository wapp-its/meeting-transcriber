import AppKit
@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The prompt window's controller (issue #99) on a real panel, with the app's
/// side faked: the input it reads whenever it renders, the clock, the answer
/// calls and where the window goes.
@MainActor
final class PromptWindowControllerTests: XCTestCase {
    /// The app as the controller sees it. The answer calls record what they
    /// were asked and return `takesAnswers`, as an answer call does when its
    /// question is still open.
    private final class FakeApp {
        var input = PromptWindowInput(enabled: true)
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var takesAnswers = true
        var consentAnswers: [ConsentAnswer] = []
        var meetingEndAnswers: [MeetingEndAnswer] = []
        /// The window size of every placement.
        var placements: [CGSize] = []
    }

    private let origin = CGPoint(x: 400, y: 600)
    private let prompt = ConsentQuestion(
        app: "Zoom", title: "Record Zoom meeting?",
        body: "A meeting is active in Zoom. Everyone must agree to being recorded.",
    )

    private func makeCountdown(secondsLeft: TimeInterval, from now: Date) -> MeetingEndQuestion {
        MeetingEndQuestion(
            id: UUID().uuidString, app: "Teams", title: "Meeting seems to have ended",
            body: "No sign of the Teams call. The recording ends in 2 minutes.",
            deadline: now + secondsLeft,
        )
    }

    private func makeController(for app: FakeApp) -> PromptWindowController {
        let origin = origin
        let controller = PromptWindowController(
            input: { app.input },
            answers: PromptWindowAnswers(
                consent: { _, answer in
                    app.consentAnswers.append(answer)
                    return app.takesAnswers
                },
                meetingEnd: { _, answer in
                    app.meetingEndAnswers.append(answer)
                    return app.takesAnswers
                },
            ),
            now: { app.now },
            origin: { size in
                app.placements.append(size)
                return origin
            },
        )
        addTeardownBlock { @MainActor in controller.panel?.orderOut(nil) }
        return controller
    }

    /// Records the window's answers to the recording prompt and asks nothing.
    private final class AnswerRecordingNotifier: AppNotifying {
        private(set) var answers: [(id: UUID, answer: ConsentAnswer)] = []

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        func answerConsentPrompt(id: UUID, answer: ConsentAnswer) -> Bool {
            answers.append((id, answer))
            return true
        }
    }

    /// Runs the main run loop until `condition` holds or `timeout` passed.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }

    private func isShown(_ controller: PromptWindowController) -> Bool {
        controller.panel?.isVisible ?? false
    }

    private func shows(_ text: String, in controller: PromptWindowController) -> Bool {
        (try? controller.panel?.host.rootView.inspect().find(text: text)) != nil
    }

    private func tap(_ id: String, in controller: PromptWindowController) throws {
        try XCTUnwrap(controller.panel).host.rootView.inspect().find(viewWithAccessibilityIdentifier: id).button().tap()
    }

    /// Shown below the icon while a question is open and the setting is on,
    /// placed again when its size changes, ordered out when nothing is left.
    /// The setting is read whenever it renders: off closes the window at once,
    /// on shows a question that is already open.
    func testFollowsTheOpenQuestionsAndTheSetting() {
        let app = FakeApp()
        let controller = makeController(for: app)

        app.input.consent = prompt
        controller.update()
        XCTAssertEqual(controller.items, [.consent(prompt)])
        XCTAssertTrue(isShown(controller))
        XCTAssertEqual(controller.panel?.frame.origin, origin)
        XCTAssertEqual(controller.panel?.frame.width, PromptWindowView.width)
        let oneQuestionHeight = controller.panel?.frame.height ?? 0
        XCTAssertGreaterThan(oneQuestionHeight, 0)

        app.input.enabled = false
        controller.update()
        XCTAssertFalse(isShown(controller), "setting off")
        app.input.enabled = true
        controller.update()
        XCTAssertTrue(isShown(controller), "setting on with the question still open")

        app.input.meetingEnd = makeCountdown(secondsLeft: 102, from: app.now)
        controller.update()
        XCTAssertEqual(controller.items.count, 2)
        XCTAssertGreaterThan(controller.panel?.frame.height ?? 0, oneQuestionHeight)
        XCTAssertEqual(app.placements.count, 3, "placed when shown, shown again and grown")

        app.input = PromptWindowInput(enabled: true)
        controller.update()
        XCTAssertEqual(controller.items, [])
        XCTAssertFalse(isShown(controller), "nothing left to show")
    }

    /// An answer the app took hides its question at once, before the loop
    /// clears it at its next poll.
    func testAnAnswerTakenHidesItsQuestionAtOnce() throws {
        let app = FakeApp()
        let countdown = makeCountdown(secondsLeft: 102, from: app.now)
        app.input = PromptWindowInput(enabled: true, consent: prompt, meetingEnd: countdown)
        let controller = makeController(for: app)
        controller.update()

        try tap(A11yID.promptWindowNever, in: controller)
        XCTAssertEqual(app.consentAnswers, [.never])
        XCTAssertEqual(controller.items, [.meetingEnd(countdown)])

        try tap(A11yID.promptWindowKeepRecording, in: controller)
        XCTAssertEqual(app.meetingEndAnswers, [.keepRecording])
        XCTAssertEqual(controller.items, [])
        XCTAssertFalse(isShown(controller))
    }

    /// A question that is not open for answers yet (or any more) keeps its
    /// place: the window lags the loop by at most a poll.
    func testAnAnswerRefusedKeepsItsQuestion() throws {
        let app = FakeApp()
        let countdown = makeCountdown(secondsLeft: 102, from: app.now)
        app.input = PromptWindowInput(enabled: true, consent: prompt, meetingEnd: countdown)
        app.takesAnswers = false
        let controller = makeController(for: app)
        controller.update()

        try tap(A11yID.promptWindowRecord, in: controller)
        try tap(A11yID.promptWindowStopNow, in: controller)

        XCTAssertEqual(app.consentAnswers, [.granted])
        XCTAssertEqual(app.meetingEndAnswers, [.stopNow])
        XCTAssertEqual(controller.items, [.meetingEnd(countdown), .consent(prompt)])
        XCTAssertTrue(isShown(controller))
    }

    /// ✕ answers nothing and hides that question only; a new prompt about the
    /// same app with the same text opens the window again.
    func testHidingAnswersNothingAndANewQuestionShowsAgain() throws {
        let app = FakeApp()
        app.input.consent = prompt
        let controller = makeController(for: app)
        controller.update()

        try tap(A11yID.promptWindowHidePrompt, in: controller)
        XCTAssertEqual(controller.items, [])
        XCTAssertFalse(isShown(controller))
        XCTAssertEqual(app.consentAnswers, [])

        let again = ConsentQuestion(app: prompt.app, title: prompt.title, body: prompt.body)
        app.input.consent = again
        controller.update()
        XCTAssertEqual(controller.items, [.consent(again)])
        XCTAssertTrue(isShown(controller))
    }

    /// The time left comes from the deadline and the clock, refreshed every
    /// second only while a countdown shows; a refresh of the same size does not
    /// move the window.
    func testTheTimeLeftRefreshesEverySecondWhileACountdownShows() {
        let app = FakeApp()
        app.input.consent = prompt
        let controller = makeController(for: app)
        controller.update()
        XCTAssertFalse(controller.isCountingDown, "no countdown")

        app.input.meetingEnd = makeCountdown(secondsLeft: 102, from: app.now)
        controller.update()
        XCTAssertTrue(controller.isCountingDown)
        XCTAssertTrue(shows("1:42", in: controller))
        let placements = app.placements.count

        app.now += 60
        XCTAssertTrue(waitUntil { shows("0:42", in: controller) }, "refreshed by the controller's own timer")
        XCTAssertEqual(app.placements.count, placements, "same size, same place")

        app.input.meetingEnd = nil
        controller.update()
        XCTAssertFalse(controller.isCountingDown, "countdown over")
    }

    /// The app's wiring on the menu bar label: the window follows the setting
    /// and the current loop's open prompt, and its Never reaches that prompt
    /// by its id through `AppState`.
    func testTheAppsWiringFollowsTheSettingAndAnswersThroughTheApp() throws {
        let state = try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(), settings: makeIsolatedSettings(),
            notifier: SilentNotifier(),
        )
        let notifier = AnswerRecordingNotifier()
        let (loop, _) = makeTestWatchLoop(notifier: notifier)
        state.watching.watchLoop = loop
        loop.pendingConsentQuestion = prompt
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let label = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false,
        )
        label.contentView = NSHostingView(rootView: Color.clear.modifier(MeetingTranscriberApp.PromptWindowWiring(appState: state)))
        label.orderFrontRegardless()
        let panel = {
            NSApplication.shared.windows.first { window in
                !before.contains(ObjectIdentifier(window)) && window.identifier == PromptPanel.windowIdentifier
            } as? PromptPanel
        }
        addTeardownBlock { @MainActor in
            panel()?.orderOut(nil)
            label.orderOut(nil)
        }

        XCTAssertFalse(waitUntil(timeout: 0.5) { panel()?.isVisible == true }, "setting off")
        state.settings.promptWindowEnabled = true
        XCTAssertTrue(waitUntil { panel()?.isVisible == true }, "setting on")
        state.settings.promptWindowEnabled = false
        XCTAssertTrue(waitUntil { panel()?.isVisible == false }, "setting off again")
        state.settings.promptWindowEnabled = true
        XCTAssertTrue(waitUntil { panel()?.isVisible == true }, "setting on again")

        try XCTUnwrap(panel()).host.rootView.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.promptWindowNever).button().tap()
        XCTAssertEqual(notifier.answers.map(\.id), [prompt.id])
        XCTAssertEqual(notifier.answers.map(\.answer), [.never])
        XCTAssertEqual(panel()?.isVisible, false, "answered")
    }

    /// The fallback's gap is counted from the menu bar of the screen that
    /// holds it: its height while it shows, else at least the notch, else the
    /// status bar's thickness.
    func testMenuBarHeightIsTheShownMenuBarElseTheNotchElseTheStatusBar() {
        let notched = CaptionScreen(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 81, width: 1728, height: 1003),
        )
        let hidden = CaptionScreen(frame: notched.frame, visibleFrame: notched.frame)
        let cases: [(name: String, screen: CaptionScreen?, notch: CGFloat, height: CGFloat)] = [
            ("menu bar shown", notched, 32, 33),
            ("menu bar hidden on a notched screen", hidden, 32, 32),
            ("menu bar hidden, no notch", hidden, 0, 22),
            ("no screen", nil, 0, 22),
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptWindowController.menuBarHeight(of: testCase.screen, safeAreaTop: testCase.notch, statusBarThickness: 22),
                testCase.height, testCase.name,
            )
        }
    }
}
