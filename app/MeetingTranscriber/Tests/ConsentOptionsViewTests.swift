@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the Record Meeting window ("Record with Options…" on the open
/// recording prompt). What an answer does is pinned in
/// `WatchLoopConsentOptionsTests`.
@MainActor
final class ConsentOptionsViewTests: XCTestCase {
    private static let choices = ProtocolTemplateChoices(templates: [.builtIn, .file(name: "Board")], defaultTemplate: .builtIn)
    private static let withRules = ProtocolTemplateChoices(
        templates: [.builtIn, .file(name: "Board")], defaultTemplate: .builtIn,
        rules: [ProtocolTemplateRule(pattern: "board", template: .file(name: "Board"))],
    )
    private static let use = ProtocolOptionsUse(destination: .remote(name: "Anthropic (Claude)"), recordOnly: false)

    private let question = ConsentQuestion(
        app: "Zoom",
        title: "Record Zoom meeting?",
        body: "A meeting is active in Zoom. Everyone must agree to being recorded.",
    )

    /// What the window handed back: every answer and every close.
    private final class Calls {
        var answers: [(question: ConsentQuestion, options: MeetingProtocolOptions)] = []
        var closes = 0
    }

    private func makeView(
        question: ConsentQuestion?,
        optionsUse: @escaping () -> ProtocolOptionsUse = { use },
        draft: ConsentOptionsDraft = ConsentOptionsDraft(),
        choices: ProtocolTemplateChoices = choices,
        answerResult: Bool = true,
        calls: Calls = Calls(),
    ) -> ConsentOptionsView {
        let onRecord: (ConsentQuestion, MeetingProtocolOptions) -> Bool = { question, options in
            calls.answers.append((question, options))
            return answerResult
        }
        // A local, not a closure literal: as the last argument one would be
        // rewritten into a trailing closure.
        let onClose: () -> Void = { calls.closes += 1 }
        return ConsentOptionsView(
            question: question,
            templateChoices: { choices },
            optionsUse: optionsUse,
            draft: draft,
            onRecord: onRecord,
            onClose: onClose,
        )
    }

    private func button(_ identifier: String, in view: ConsentOptionsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: identifier).button()
    }

    func testTheWindowShowsTheQuestionsTitleAndBodyAndTheOptionsForm() throws {
        let sut = try makeView(question: question).inspect()

        XCTAssertNoThrow(try sut.find(text: question.title))
        XCTAssertNoThrow(try sut.find(text: question.body))
        XCTAssertNoThrow(try sut.find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsTemplatePicker))
        XCTAssertThrowsError(try sut.find(text: ConsentOptionsView.noLongerOpen))
    }

    /// A window left open while Settings switches from a local to a remote
    /// provider names where the background info goes now.
    func testTheNoticeFollowsTheSettingsWhileTheWindowIsOpen() throws {
        var use = ProtocolOptionsUse(destination: .local(host: "127.0.0.1"), recordOnly: false)
        let currentUse: () -> ProtocolOptionsUse = { use }
        let sut = makeView(question: question, optionsUse: currentUse)
        try sut.inspect().vStack().callOnAppear()
        let notice = {
            try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsDestinationNotice).text().string()
        }
        XCTAssertEqual(try notice(), ProtocolDestination.local(host: "127.0.0.1").notice)

        use = ProtocolOptionsUse(destination: .remote(name: "OpenAI (Codex)"), recordOnly: false)

        XCTAssertEqual(try notice(), ProtocolDestination.remote(name: "OpenAI (Codex)").notice)
    }

    func testRecordAnswersTheDisplayedQuestionWithTheDraftsOptionsAndCloses() throws {
        let calls = Calls()
        let draft = ConsentOptionsDraft(protocolOptions: ProtocolOptionsDraft(template: .file(name: "Board"), background: " Agenda "))
        let sut = makeView(question: question, draft: draft, calls: calls)

        try button(A11yID.consentOptionsRecordButton, in: sut).tap()

        XCTAssertEqual(calls.answers.map(\.question), [question])
        XCTAssertEqual(calls.answers.map(\.options), [MeetingProtocolOptions(template: .file(name: "Board"), rawBackground: "Agenda")])
        XCTAssertEqual(calls.closes, 1)
    }

    func testAnAnswerThatFindsTheQuestionClosedSaysSoAndStaysOpen() throws {
        let calls = Calls()
        let draft = ConsentOptionsDraft()
        let sut = makeView(question: question, draft: draft, answerResult: false, calls: calls)

        try button(A11yID.consentOptionsRecordButton, in: sut).tap()

        XCTAssertEqual(calls.answers.count, 1)
        XCTAssertEqual(calls.closes, 0, "the window stays open")
        XCTAssertTrue(draft.questionClosed)
        XCTAssertNoThrow(try sut.inspect().find(text: ConsentOptionsView.noLongerOpen))
    }

    // MARK: - Template rules

    private func templateLine(_ sut: ConsentOptionsView) throws -> String {
        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsTemplateLine).text().string()
    }

    /// The window opens on what the rules pick for the meeting's title, says
    /// so, and Record answers with that template.
    func testTheWindowOpensOnTheTemplateTheRulesPickForTheMeetingTitle() throws {
        let calls = Calls()
        let meeting = ConsentQuestion(app: "Zoom", title: question.title, body: question.body, meetingTitle: "Board Review")
        let sut = makeView(question: meeting, choices: Self.withRules, calls: calls)
        try sut.inspect().vStack().callOnAppear()

        XCTAssertEqual(try templateLine(sut), "From rule 1 (board), matching the title “Board Review”.")
        try button(A11yID.consentOptionsRecordButton, in: sut).tap()
        XCTAssertEqual(calls.answers.map(\.options.template), [.file(name: "Board")])
    }

    func testNoMatchSaysTheDefaultAppliesAndAPickSaysItWasChosen() throws {
        let draft = ConsentOptionsDraft()
        let meeting = ConsentQuestion(app: "Teams", title: question.title, body: question.body, meetingTitle: "Microsoft Teams Call")
        let sut = makeView(question: meeting, draft: draft, choices: Self.withRules)
        try sut.inspect().vStack().callOnAppear()
        XCTAssertEqual(try templateLine(sut), "Default template: no rule matches the title “Microsoft Teams Call”.")

        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsTemplatePicker)
            .find(ViewType.Picker.self)
            .select(value: ProtocolTemplateID.file(name: "Board"))

        XCTAssertEqual(try templateLine(sut), "Chosen by you. This recording uses it, whatever the rules say.")
    }

    func testCancelClosesWithoutAnswering() throws {
        let calls = Calls()
        let sut = makeView(question: question, calls: calls)

        try button(A11yID.consentOptionsCancelButton, in: sut).tap()

        XCTAssertTrue(calls.answers.isEmpty)
        XCTAssertEqual(calls.closes, 1)
    }

    /// A window macOS restored at launch has no question to answer.
    func testWithoutAQuestionRecordIsDisabled() throws {
        let sut = makeView(question: nil)

        XCTAssertTrue(try button(A11yID.consentOptionsRecordButton, in: sut).isDisabled())
        XCTAssertNoThrow(try sut.inspect().find(text: ConsentOptionsView.noQuestion))
    }
}
