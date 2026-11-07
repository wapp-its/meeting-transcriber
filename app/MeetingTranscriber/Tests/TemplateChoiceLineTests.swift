@testable import MeetingTranscriber
import XCTest

/// How the start dialog's and the Record Meeting window's drafts follow the
/// template rules, and what the line under Template says in each of its five
/// cases. Values only; the windows' wiring is in their view tests.
@MainActor
final class TemplateChoiceLineTests: XCTestCase {
    private static let daily = ProtocolTemplateRule(pattern: "daily|stand-?up", template: .file(name: "Daily"))

    private static let choices = ProtocolTemplateChoices(
        templates: [.builtIn, .file(name: "Board"), .file(name: "Daily")],
        defaultTemplate: .file(name: "Board"),
        rules: [daily],
    )

    private static let noRules = ProtocolTemplateChoices(
        templates: [.builtIn, .file(name: "Board"), .file(name: "Daily")],
        defaultTemplate: .file(name: "Board"),
    )

    private static let zoom = RunningApp(id: 100, name: "Zoom", bundleIdentifier: "us.zoom.xos", icon: nil)

    // MARK: - The five cases' wording

    func testEachCaseReadsAsTheAcceptedMockup() {
        XCTAssertEqual(
            TemplateChoiceLine.rule(number: 1, pattern: "daily|stand-?up", title: "Team Daily").text,
            "From rule 1 (daily|stand-?up), matching the title “Team Daily”.",
        )
        XCTAssertEqual(
            TemplateChoiceLine.noRuleMatches(title: "Microsoft Teams Call").text,
            "Default template: no rule matches the title “Microsoft Teams Call”.",
        )
        XCTAssertEqual(TemplateChoiceLine.defaultUntilSourceChosen.text, "Default template until you choose what to record.")
        XCTAssertEqual(TemplateChoiceLine.chosenByHand.text, "Chosen by you. This recording uses it, whatever the rules say.")
    }

    // MARK: - The options draft

    func testARuleMatchSelectsItsTemplateAndSaysWhichRule() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Board"))

        draft.follow(Self.choices, title: "Team Daily")

        XCTAssertEqual(draft.template, .file(name: "Daily"))
        XCTAssertEqual(draft.line, .rule(number: 1, pattern: "daily|stand-?up", title: "Team Daily"))
    }

    func testNoMatchSelectsTheDefaultAndSaysSo() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Daily"))

        draft.follow(Self.choices, title: "Microsoft Teams Call")

        XCTAssertEqual(draft.template, .file(name: "Board"))
        XCTAssertEqual(draft.line, .noRuleMatches(title: "Microsoft Teams Call"))
    }

    func testNoTitleYetSelectsTheDefaultUntilASourceIsChosen() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Daily"))

        draft.follow(Self.choices, title: nil)

        XCTAssertEqual(draft.template, .file(name: "Board"))
        XCTAssertEqual(draft.line, .defaultUntilSourceChosen)
    }

    func testWithNoRulesThereIsNoLineAndTheSelectionStays() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Board"))

        draft.follow(Self.noRules, title: "Team Daily")
        draft.chooseByHand(.file(name: "Daily"))

        XCTAssertNil(draft.line)
        XCTAssertEqual(draft.template, .file(name: "Daily"))
    }

    func testAHandPickedTemplateStaysWhateverTheRulesSay() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Board"))
        draft.follow(Self.choices, title: "Microsoft Teams Call")

        draft.chooseByHand(.builtIn)
        draft.follow(Self.choices, title: "Team Daily")

        XCTAssertEqual(draft.template, .builtIn)
        XCTAssertEqual(draft.line, .chosenByHand)
        XCTAssertEqual(draft.options.template, .builtIn)
    }

    /// The regenerate sheet shares the draft and never follows the rules, so a
    /// pick there must not make a line appear (spec A6).
    func testAPickWithoutALineShowsNoLine() {
        let draft = ProtocolOptionsDraft(template: .builtIn)

        draft.chooseByHand(.file(name: "Board"))

        XCTAssertTrue(draft.chosenByHand)
        XCTAssertNil(draft.line)
    }

    func testPickingTheSelectedTemplateAgainIsNotAChoice() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Board"))
        draft.follow(Self.choices, title: "Team Daily")

        draft.chooseByHand(.file(name: "Daily"))

        XCTAssertFalse(draft.chosenByHand)
        XCTAssertEqual(draft.line, .rule(number: 1, pattern: "daily|stand-?up", title: "Team Daily"))
    }

    func testResetForgetsTheLineAndTheHandPick() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Board"))
        draft.follow(Self.choices, title: "Team Daily")
        draft.chooseByHand(.builtIn)

        draft.reset(to: .file(name: "Board"))

        XCTAssertNil(draft.line)
        XCTAssertFalse(draft.chosenByHand)
    }

    // MARK: - The start dialog

    func testTheStartDialogOpensOnTheDefaultUntilASourceIsChosen() {
        let draft = StartRecordingDraft(protocolOptions: ProtocolOptionsDraft(template: .builtIn))

        draft.reset(choices: Self.choices)

        XCTAssertEqual(draft.protocolOptions.template, .file(name: "Board"))
        XCTAssertEqual(draft.protocolOptions.line, .defaultUntilSourceChosen)
    }

    /// The title the recording would get: the app's name until one is typed,
    /// the typed title while it is typed, the fixed one for the microphone.
    func testTheStartDialogFollowsTheSelectedSourceAndTheTypedTitle() {
        let draft = StartRecordingDraft()
        draft.reset(choices: Self.choices)

        draft.source = .app(Self.zoom)
        XCTAssertEqual(draft.protocolOptions.template, .file(name: "Board"))
        XCTAssertEqual(draft.protocolOptions.line, .noRuleMatches(title: "Zoom"))

        draft.title = "Team Daily"
        XCTAssertEqual(draft.protocolOptions.template, .file(name: "Daily"))
        XCTAssertEqual(draft.protocolOptions.line, .rule(number: 1, pattern: "daily|stand-?up", title: "Team Daily"))

        draft.source = .microphone
        XCTAssertEqual(draft.protocolOptions.template, .file(name: "Board"))
        XCTAssertEqual(draft.protocolOptions.line, .noRuleMatches(title: "Microphone Recording"))
    }

    func testOnceTheTemplateIsChangedByHandTheStartDialogStaysThere() {
        let draft = StartRecordingDraft()
        draft.reset(choices: Self.choices)
        draft.source = .app(Self.zoom)

        draft.protocolOptions.chooseByHand(.builtIn)
        draft.title = "Team Daily"

        XCTAssertEqual(draft.protocolOptions.template, .builtIn)
        XCTAssertEqual(draft.protocolOptions.line, .chosenByHand)
    }

    func testReopeningTheStartDialogStartsOver() {
        let draft = StartRecordingDraft()
        draft.reset(choices: Self.choices)
        draft.source = .app(Self.zoom)
        draft.title = "Team Daily"
        draft.protocolOptions.chooseByHand(.builtIn)

        draft.reset(choices: Self.choices)

        XCTAssertNil(draft.source)
        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.protocolOptions.template, .file(name: "Board"))
        XCTAssertEqual(draft.protocolOptions.line, .defaultUntilSourceChosen)
    }

    // MARK: - The Record Meeting window

    func testTheRecordMeetingWindowOpensOnTheRulesTemplateForTheQuestionsTitle() {
        let draft = ConsentOptionsDraft()
        let question = ConsentQuestion(app: "Zoom", title: "Record Zoom meeting?", body: "", meetingTitle: "Team Daily")

        draft.reset(choices: Self.choices, question: question)

        XCTAssertEqual(draft.protocolOptions.template, .file(name: "Daily"))
        XCTAssertEqual(draft.protocolOptions.line, .rule(number: 1, pattern: "daily|stand-?up", title: "Team Daily"))
    }

    func testWithoutAQuestionTheRecordMeetingWindowShowsNoLine() {
        let draft = ConsentOptionsDraft()

        draft.reset(choices: Self.choices, question: nil)

        XCTAssertEqual(draft.protocolOptions.template, .file(name: "Board"))
        XCTAssertNil(draft.protocolOptions.line)
    }

    // MARK: - What a window reads

    func testTheChoicesReadTheSettingsRules() throws {
        let suite = "TemplateChoiceLineTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
        settings.protocolTemplateRules = [Self.daily]
        let store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "template-choice-line"))
        try store.create(name: "Daily")

        let choices = ProtocolTemplateChoices(settings: settings, store: store)

        XCTAssertEqual(choices.rules, [Self.daily])
        XCTAssertEqual(choices.choice(forTitle: "Team Daily").template, .file(name: "Daily"))
    }
}
