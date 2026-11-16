@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The switch "First heading contains the meeting title" of each template:
/// kept in the settings by the template's name, never in its file. New
/// Template switches it on, Delete removes it, and a file added in Finder
/// starts off. Which notes then lend their heading as the meeting title is
/// pinned in `PipelineQueueAITitleTemplateTests` and
/// `PipelineQueueNotionTitleTemplateTests`.
@MainActor
final class ProtocolTemplatesTitleHeadingTests: XCTestCase {
    // MARK: - Model

    func testAFileAddedInFinderStartsOff() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()

        XCTAssertEqual(model.names, ["Board"])
        XCTAssertFalse(model.hasTitleHeading("Board"))
    }

    /// New Template copies the built-in text, whose first heading holds the
    /// title, so its switch starts on.
    func testNewTemplateStartsOn() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = " Board.md "

        model.createTemplate()

        XCTAssertEqual(model.names, ["Board"])
        XCTAssertEqual(fixture.settings.templatesWithTitleHeading, ["Board"])
    }

    func testARefusedCreateSwitchesNothingOn() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "board"

        model.createTemplate()

        XCTAssertNotNil(model.nameProblem, "test premise: the name was refused")
        XCTAssertEqual(fixture.settings.templatesWithTitleHeading, [])
    }

    /// A file made again under the deleted name starts off, as any new file.
    func testDeleteRemovesTheSwitchAndAFailedDeleteKeepsIt() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        fixture.settings.templatesWithTitleHeading = ["Board", "Retro"]
        var trashFails = true
        let model = fixture.makeModel { url in
            if trashFails { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            try FileManager.default.removeItem(at: url)
        }

        model.confirmDelete("Board")
        XCTAssertTrue(model.hasTitleHeading("Board"), "a failed delete keeps the switch")
        trashFails = false
        model.confirmDelete("Board")

        XCTAssertEqual(fixture.settings.templatesWithTitleHeading, ["Retro"])
    }

    /// By name and case-insensitive, as the default volume treats the names.
    func testTheSwitchIsKeptAcrossARelaunchWhateverTheCaseOfTheName() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        fixture.settings.setTemplateHasTitleHeading(true, for: "Board")
        fixture.settings.setTemplateHasTitleHeading(true, for: "BOARD")

        let relaunched = AppSettings(defaults: fixture.defaults)
        XCTAssertEqual(relaunched.templatesWithTitleHeading, ["Board"])
        XCTAssertTrue(relaunched.templateHasTitleHeading("board"))
        relaunched.setTemplateHasTitleHeading(false, for: "board")

        XCTAssertEqual(AppSettings(defaults: fixture.defaults).templatesWithTitleHeading, [])
    }

    // MARK: - View wiring

    func testRowZerosToggleSwitchesItsTemplateAndExplainsTheSwitch() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        let model = fixture.makeModel()
        let view = ProtocolTemplatesSettingsView(model: model)
        let row = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateTitleHeadingToggle(0))

        try row.find(ViewType.Toggle.self).tap()

        XCTAssertEqual(fixture.settings.templatesWithTitleHeading, ["Board"])
        XCTAssertEqual(try row.find(HelpBadge.self).actualView().text, SettingsHelp.templateTitleHeading)
    }

    func testRowOnesToggleShowsItsTemplatesSwitch() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        fixture.settings.templatesWithTitleHeading = ["Retro"]
        let view = ProtocolTemplatesSettingsView(model: fixture.makeModel())

        func isOn(row: Int) throws -> Bool {
            try view.inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateTitleHeadingToggle(row))
                .find(ViewType.Toggle.self)
                .isOn()
        }

        XCTAssertFalse(try isOn(row: 0))
        XCTAssertTrue(try isOn(row: 1))
    }
}
