@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The open "Record <App> meeting?" prompt at the top of the menu, the
/// fallback for whoever missed its notification.
@MainActor
final class MenuBarViewConsentPromptTests: XCTestCase {
    /// One line of the menu as far as the order is concerned.
    private enum Line: Equatable {
        case text(String)
        case status
        case divider
        case button(String)
    }

    /// Every answer the menu handed back, in order, and every question it
    /// opened the Record Meeting window for.
    private final class Answers {
        var calls: [(question: ConsentQuestion, granted: Bool)] = []
        var optionsOpened: [ConsentQuestion] = []
    }

    private let question = ConsentQuestion(
        app: "Zoom",
        title: "Record Zoom meeting?",
        body: "A meeting is active in Zoom. Everyone must agree to being recorded.",
    )

    private func makeView(question: ConsentQuestion?, answers: Answers = Answers()) -> MenuBarView {
        MenuBarView(
            status: TranscriberStatus(
                version: 1,
                timestamp: "2024-01-01T00:00:00",
                state: .watching,
                detail: "",
                meeting: nil,
                error: nil,
                audioPath: nil,
                pid: nil,
            ),
            isWatching: true,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenProtocol: { _ in },
            onOpenLastProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            consentQuestion: question,
            onAnswerConsent: { question, granted in answers.calls.append((question, granted)) },
            onRecordConsentWithOptions: { answers.optionsOpened.append($0) },
            onQuit: {},
        )
    }

    /// The question's two texts, the status line, the dividers and the
    /// buttons, in document order (`findAll` searches depth-first, top to
    /// bottom as written).
    private func lines(of view: MenuBarView) throws -> [Line] {
        let texts = [question.title, question.body]
        let nodes = try view.inspect().findAll { node in
            if (try? node.divider()) != nil || (try? node.button()) != nil { return true }
            guard let string = try? node.text().string() else { return false }
            return texts.contains(string) || string == TranscriberState.watching.label
        }
        return try nodes.map { node in
            if (try? node.divider()) != nil { return .divider }
            if let button = try? node.button() { return try .button(button.find(ViewType.Text.self).string()) }
            let string = try node.text().string()
            return string == TranscriberState.watching.label ? .status : .text(string)
        }
    }

    private func tap(_ identifier: String, in view: MenuBarView) throws {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: identifier)
            .button()
            .tap()
    }

    func testWithoutAQuestionTheMenuHasNoConsentSection() throws {
        let sut = makeView(question: nil)

        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentPromptRecord))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentPromptRecordWithOptions))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.consentPromptIgnore))
        XCTAssertEqual(try lines(of: sut).first, .status)
    }

    func testWithAQuestionTheMenuOpensWithItsTextThenItsAnswers() throws {
        let sut = makeView(question: question)

        XCTAssertEqual(
            try Array(lines(of: sut).prefix(7)),
            [
                .text(question.title),
                .text(question.body),
                .button("Record"),
                .button("Record with Options…"),
                .button("Ignore"),
                .divider,
                .status,
            ],
        )
    }

    func testRecordAnswersTheDisplayedQuestionWithYes() throws {
        let answers = Answers()
        let sut = makeView(question: question, answers: answers)

        try tap(A11yID.consentPromptRecord, in: sut)

        XCTAssertEqual(answers.calls.count, 1)
        XCTAssertEqual(answers.calls.first?.question, question)
        XCTAssertEqual(answers.calls.first?.granted, true)
    }

    /// Opens the window for the displayed question and answers nothing itself:
    /// the window's Record does.
    func testRecordWithOptionsHandsBackTheDisplayedQuestion() throws {
        let answers = Answers()
        let sut = makeView(question: question, answers: answers)

        try tap(A11yID.consentPromptRecordWithOptions, in: sut)

        XCTAssertEqual(answers.optionsOpened, [question])
        XCTAssertTrue(answers.calls.isEmpty)
    }

    func testIgnoreAnswersTheDisplayedQuestionWithNo() throws {
        let answers = Answers()
        let sut = makeView(question: question, answers: answers)

        try tap(A11yID.consentPromptIgnore, in: sut)

        XCTAssertEqual(answers.calls.count, 1)
        XCTAssertEqual(answers.calls.first?.question, question)
        XCTAssertEqual(answers.calls.first?.granted, false)
    }
}
