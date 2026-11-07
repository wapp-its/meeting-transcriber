@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Settings → Output → Template Rules: what each model operation does to the
/// saved rules, what a row and the try-a-title field show, then one wiring
/// test per control and a check that identifiers carry positions only. Runs
/// against a temp templates folder holding "Board" and "Daily" and a
/// throwaway defaults suite.
@MainActor
final class TemplateRulesSettingsTests: XCTestCase {
    private static let daily = ProtocolTemplateRule(pattern: "daily|stand-?up", template: .file(name: "Daily"))
    private static let board = ProtocolTemplateRule(pattern: "board", template: .file(name: "Board"))

    private func makeSettings(rules: [ProtocolTemplateRule] = []) throws -> AppSettings {
        let suite = "TemplateRulesSettingsTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
        settings.protocolTemplateRules = rules
        return settings
    }

    private func makeModel(
        rules: [ProtocolTemplateRule] = [], settings: AppSettings? = nil, templates names: [String] = ["Board", "Daily"],
    ) throws -> (TemplateRulesModel, AppSettings) {
        let settings = try settings ?? makeSettings(rules: rules)
        let store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "template-rules-settings"))
        for name in names {
            try "Template \(name)".write(to: store.fileURL(named: name), atomically: true, encoding: .utf8)
        }
        let templates = ProtocolTemplatesModel(store: store, settings: settings)
        templates.reload()
        return (TemplateRulesModel(templates: templates, settings: settings), settings)
    }

    // MARK: - Editing and saving

    /// The rules are kept with the settings, in their order, across a restart.
    func testTheSettingsKeepTheRulesInOrder() throws {
        let suite = "TemplateRulesSettingsTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.protocolTemplateRules, [], "no rules by default")

        settings.protocolTemplateRules = [Self.daily, Self.board]

        XCTAssertEqual(AppSettings(defaults: defaults).protocolTemplateRules, [Self.daily, Self.board])
    }

    func testTheRowsShowTheSavedRulesInOrder() throws {
        let (model, _) = try makeModel(rules: [Self.daily, Self.board])

        XCTAssertEqual(model.rows.map(\.text), ["daily|stand-?up", "board"])
        XCTAssertEqual(model.rows.map(\.template), [.file(name: "Daily"), .file(name: "Board")])
    }

    /// A new row starts on the default template and is saved once its pattern
    /// is valid; until then it changes nothing.
    func testANewRuleStartsOnTheDefaultAndIsSavedOnceItsPatternIsValid() throws {
        let settings = try makeSettings()
        settings.defaultProtocolTemplate = .file(name: "Board")
        let (model, _) = try makeModel(settings: settings)

        model.addRule()
        XCTAssertEqual(model.rows.map(\.template), [.file(name: "Board")])
        XCTAssertEqual(settings.protocolTemplateRules, [], "an empty pattern is not saved")

        let id = try XCTUnwrap(model.rows.first?.id)
        model.setText("(retro", of: id)
        XCTAssertEqual(settings.protocolTemplateRules, [], "an invalid pattern is not saved")

        model.setText("(retro)", of: id)
        XCTAssertEqual(settings.protocolTemplateRules, [ProtocolTemplateRule(pattern: "(retro)", template: .file(name: "Board"))])
    }

    /// A saved rule keeps its last valid pattern while the field holds one
    /// that is refused, so typing through an invalid state changes nothing.
    func testARefusedPatternLeavesTheSavedOneInForce() throws {
        let (model, settings) = try makeModel(rules: [Self.daily])
        let id = try XCTUnwrap(model.rows.first?.id)

        model.setText("daily|(stand", of: id)

        XCTAssertEqual(model.rows.first?.text, "daily|(stand")
        XCTAssertEqual(settings.protocolTemplateRules, [Self.daily])
        XCTAssertEqual(
            model.rows.first.map { model.refusal(of: $0)?.message },
            "Not a valid pattern: a “(” is not closed. The rule is saved once the pattern is valid.",
        )
    }

    func testTheTemplatePickerMoveAndDeleteSaveAtOnce() throws {
        let (model, settings) = try makeModel(rules: [Self.daily, Self.board])
        let first = try XCTUnwrap(model.rows.first?.id)

        model.setTemplate(.builtIn, of: first)
        XCTAssertEqual(settings.protocolTemplateRules.first?.template, .builtIn)

        model.moveDown(first)
        XCTAssertEqual(settings.protocolTemplateRules.map(\.pattern), ["board", "daily|stand-?up"])
        model.moveDown(first)
        XCTAssertEqual(settings.protocolTemplateRules.map(\.pattern), ["board", "daily|stand-?up"], "the last row stays last")

        model.moveUp(first)
        XCTAssertEqual(settings.protocolTemplateRules.map(\.pattern), ["daily|stand-?up", "board"])
        model.moveUp(first)
        XCTAssertEqual(settings.protocolTemplateRules.map(\.pattern), ["daily|stand-?up", "board"], "the first row stays first")

        model.delete(first)
        XCTAssertEqual(settings.protocolTemplateRules, [Self.board])
        XCTAssertEqual(model.rows.map(\.text), ["board"])
    }

    // MARK: - What a row shows

    func testARuleWhoseTemplateFileIsGoneIsMarkedMissing() throws {
        let gone = ProtocolTemplateRule(pattern: "retro", template: .file(name: "Retro"))
        let builtIn = ProtocolTemplateRule(pattern: "sync", template: .builtIn)
        let (model, _) = try makeModel(rules: [gone, Self.daily, builtIn])

        XCTAssertEqual(model.rows.map { model.missingTemplate(of: $0) }, ["Retro", nil, nil])
    }

    /// A Finder rename that changed only the case keeps the rule working and
    /// its picker on the listed spelling.
    func testACaseOnlyRenameIsNotMissing() throws {
        let (model, _) = try makeModel(rules: [Self.daily], templates: ["daily"])
        let row = try XCTUnwrap(model.rows.first)

        XCTAssertNil(model.missingTemplate(of: row))
        XCTAssertEqual(model.selection(of: row), .file(name: "daily"))
    }

    // MARK: - Try a title

    func testAnEmptyTitleShowsNoResult() throws {
        let (model, _) = try makeModel(rules: [Self.daily])

        XCTAssertNil(model.tryChoice)
    }

    /// Rules are numbered as the rows show them, an unsaved row included.
    func testTheResultNamesTheTemplateAndTheRuleByItsRow() throws {
        let (model, _) = try makeModel(rules: [Self.daily])
        model.addRule()
        try model.setText("board", of: XCTUnwrap(model.rows.last?.id))
        model.addRule()
        model.tryTitle = "Board Review"

        let choice = try XCTUnwrap(model.tryChoice)

        XCTAssertEqual(
            String(TemplateRulesModel.tryText(for: choice).characters),
            "Gets Standard (built-in), from rule 2 (board).",
        )
    }

    func testTheResultSaysWhenNoRuleMatchesAndNamesTheDefaultInBold() throws {
        let settings = try makeSettings(rules: [Self.daily])
        settings.defaultProtocolTemplate = .file(name: "Board")
        let (model, _) = try makeModel(settings: settings)
        model.tryTitle = "Microsoft Teams Call"

        let text = try TemplateRulesModel.tryText(for: XCTUnwrap(model.tryChoice))

        XCTAssertEqual(String(text.characters), "Gets the default template, Board: no rule matches.")
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(text[$0.range].characters) }
        XCTAssertEqual(bold, ["Board"])
    }

    func testARuleThatTookTooLongIsNamedBeforeTheResult() {
        let choice = ProtocolTemplateRules.Choice(template: .file(name: "Daily"), source: .rule(index: 1, pattern: "daily"), timedOutRules: [0])

        XCTAssertEqual(
            String(TemplateRulesModel.tryText(for: choice).characters),
            "Rule 1 took too long on this title and is skipped. Gets Daily, from rule 2 (daily).",
        )
    }

    // MARK: - Wiring

    private func makeView(
        rules: [ProtocolTemplateRule] = [daily, board], settings: AppSettings? = nil, templates: [String] = ["Board", "Daily"],
    ) throws -> (TemplateRulesSettingsView, TemplateRulesModel, AppSettings) {
        let (model, settings) = try makeModel(rules: rules, settings: settings, templates: templates)
        return (TemplateRulesSettingsView(model: model), model, settings)
    }

    private func element(_ identifier: String, in view: TemplateRulesSettingsView) throws -> InspectableView<ViewType.ClassifiedView> {
        try view.inspect().find(viewWithAccessibilityIdentifier: identifier)
    }

    func testTheSectionShowsTheCaptionHeadingsAndTitleNote() throws {
        let (view, _, _) = try makeView()
        let body = try view.inspect()

        XCTAssertNoThrow(try body.find(text: TemplateRulesSettingsView.caption))
        XCTAssertNoThrow(try body.find(text: "Meeting title contains"))
        XCTAssertNoThrow(try body.find(text: "Template"))
        XCTAssertNoThrow(try body.find(text: TemplateRulesSettingsView.titleNote))
        XCTAssertTrue(TemplateRulesSettingsView.caption.hasSuffix("“daily” matches “Team Daily”."))
    }

    func testThePatternFieldWritesTheRule() throws {
        let (view, _, settings) = try makeView()

        try element(A11yID.templateRulePatternField(0), in: view).textField().setInput("daily")

        XCTAssertEqual(settings.protocolTemplateRules.first?.pattern, "daily")
    }

    func testTheTemplatePickerWritesTheRule() throws {
        let (view, _, settings) = try makeView()

        try element(A11yID.templateRuleTemplatePicker(1), in: view)
            .find(ViewType.Picker.self)
            .select(value: ProtocolTemplateID.file(name: "Daily"))

        XCTAssertEqual(settings.protocolTemplateRules.last?.template, .file(name: "Daily"))
    }

    func testMoveUpMovesTheRowAndIsDisabledOnTheFirst() throws {
        let (view, _, settings) = try makeView()
        XCTAssertTrue(try element(A11yID.templateRuleMoveUp(0), in: view).button().isDisabled())

        try element(A11yID.templateRuleMoveUp(1), in: view).button().tap()

        XCTAssertEqual(settings.protocolTemplateRules.map(\.pattern), ["board", "daily|stand-?up"])
    }

    func testMoveDownMovesTheRowAndIsDisabledOnTheLast() throws {
        let (view, _, settings) = try makeView()
        XCTAssertTrue(try element(A11yID.templateRuleMoveDown(1), in: view).button().isDisabled())

        try element(A11yID.templateRuleMoveDown(0), in: view).button().tap()

        XCTAssertEqual(settings.protocolTemplateRules.map(\.pattern), ["board", "daily|stand-?up"])
    }

    func testDeleteRemovesTheRow() throws {
        let (view, _, settings) = try makeView()

        try element(A11yID.templateRuleDelete(0), in: view).button().tap()

        XCTAssertEqual(settings.protocolTemplateRules, [Self.board])
    }

    func testAddRuleAddsARow() throws {
        let (view, model, _) = try makeView()

        try element(A11yID.templateRulesAddButton, in: view).button().tap()

        XCTAssertEqual(model.rows.count, 3)
        XCTAssertNoThrow(try element(A11yID.templateRulePatternField(2), in: view))
    }

    func testTheTryTitleFieldShowsTheResult() throws {
        let (view, model, _) = try makeView()
        XCTAssertThrowsError(try element(A11yID.templateRulesTryResult, in: view), "an empty field shows no result")

        try element(A11yID.templateRulesTryTitleField, in: view).textField().setInput("Team Daily")

        XCTAssertEqual(model.tryTitle, "Team Daily")
        XCTAssertNoThrow(try element(A11yID.templateRulesTryResult, in: view))
    }

    func testAMissingTemplateAndAnInvalidPatternSayWhyTheRuleIsSkipped() throws {
        let gone = ProtocolTemplateRule(pattern: "retro", template: .file(name: "Retro"))
        let (view, model, _) = try makeView(rules: [gone, Self.board])
        try model.setText("[board", of: XCTUnwrap(model.rows.last?.id))
        let body = try view.inspect()

        XCTAssertNoThrow(try body.find(text: "Retro (missing)"))
        XCTAssertNoThrow(try body.find(
            text: "The template “Retro” is no longer in the templates folder, so this rule is skipped. It works again when the file is back.",
        ))
        XCTAssertNoThrow(try body.find(text: "Not a valid pattern: a “[” is not closed. The rule is saved once the pattern is valid."))
    }

    /// `/ui/tree` publishes identifiers unredacted, and patterns and template
    /// names are user input: no identifier in the section may carry either.
    func testIdentifiersCarryRowPositionsOnly() throws {
        let secret = ProtocolTemplateRule(pattern: "acme-merger", template: .file(name: "Confidential"))
        let (view, _, _) = try makeView(rules: [secret], templates: ["Confidential"])

        let identifiers = try view.inspect().findAll { view in
            (try? view.accessibilityIdentifier()).map { !$0.isEmpty } ?? false
        }.map { try $0.accessibilityIdentifier() }

        XCTAssertFalse(identifiers.isEmpty)
        for identifier in identifiers {
            XCTAssertFalse(identifier.localizedCaseInsensitiveContains("acme"), identifier)
            XCTAssertFalse(identifier.localizedCaseInsensitiveContains("confidential"), identifier)
        }
        XCTAssertTrue(identifiers.contains(A11yID.templateRulePatternField(0)))
    }

    /// The section sits in Settings → Output.
    func testOutputSettingsShowsTheTemplateRules() throws {
        let settings = try makeSettings(rules: [Self.daily])
        let store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "template-rules-output"))

        let body = try OutputSettingsView(settings: settings, templateStore: store).inspect()

        XCTAssertNoThrow(try body.find(TemplateRulesSettingsView.self))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.templateRulePatternField(0)))
    }
}
