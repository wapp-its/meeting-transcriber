@testable import MeetingTranscriber
import XCTest

/// The New Template window's state and writes, on `ProtocolTemplatesModel`: what
/// Create writes and opens, the red line under the name, and what Cancel and a
/// failed write leave behind. The window's controls are wired in
/// `ProtocolTemplatesSettingsTests`.
@MainActor
final class ProtocolTemplatesNewTemplateTests: XCTestCase {
    func testCreateWritesTheBuiltInTextClosesTheWindowAndOpensTheFileInTheEditorApp() async throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "  Board  "

        model.createTemplate()
        await model.openTask?.value

        let url = fixture.store.fileURL(named: "Board")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ProtocolGenerator.protocolPrompt)
        XCTAssertFalse(model.isNewTemplateShown)
        XCTAssertEqual(model.newTemplateName, "")
        XCTAssertEqual(model.names, ["Board"])
        XCTAssertEqual(fixture.apps.opened, [.init(file: url, app: "com.apple.TextEdit")])
        XCTAssertNil(model.notice)
    }

    func testARefusedNameShowsTheStoresMessageAndDisablesCreate() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()
        model.showNewTemplate()
        let cases: [(String, ProtocolTemplateName.Refusal)] = [
            (String(repeating: "x", count: ProtocolTemplateName.maxLength + 1), .tooLong),
            ("a/b", .forbiddenCharacter),
            ("a:b", .forbiddenCharacter),
            (".hidden", .leadingDot),
            ("board", .duplicate),
        ]
        for (raw, refusal) in cases {
            model.newTemplateName = raw

            XCTAssertEqual(model.nameProblem, refusal.errorDescription, raw)
            XCTAssertFalse(model.canCreate, raw)
        }
        XCTAssertEqual(fixture.files, ["Board.md"])
    }

    func testAnEmptyNameDisablesCreateWithoutARedLine() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()

        for raw in ["", "   "] {
            model.newTemplateName = raw

            XCTAssertNil(model.nameProblem, "“\(raw)”")
            XCTAssertFalse(model.canCreate, "“\(raw)”")
        }
        model.newTemplateName = "Retro"
        XCTAssertTrue(model.canCreate)
    }

    func testAFailedWriteKeepsTheWindowAndTheNameAndShowsTheError() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let folder = fixture.store.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Retro"

        model.createTemplate()

        XCTAssertTrue(model.isNewTemplateShown)
        XCTAssertEqual(model.newTemplateName, "Retro")
        XCTAssertNotNil(model.nameProblem)
        XCTAssertNil(model.openTask)
        XCTAssertEqual(fixture.files, ["Board.md"])
        XCTAssertEqual(fixture.apps.opened, [])

        model.newTemplateName = "Retro 2"
        XCTAssertNil(model.nameProblem, "typing again clears the error")
    }

    /// Another app wrote the name while the window was open: Create checks
    /// again, refuses it and leaves that file alone.
    func testANameTakenWhileTheWindowIsOpenIsRefusedOnCreate() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Retro"
        XCTAssertTrue(model.canCreate)
        try fixture.write(["Retro"])

        model.createTemplate()

        XCTAssertTrue(model.isNewTemplateShown)
        XCTAssertEqual(model.nameProblem, ProtocolTemplateName.Refusal.duplicate.errorDescription)
        XCTAssertFalse(model.canCreate)
        XCTAssertEqual(try String(contentsOf: fixture.store.fileURL(named: "Retro"), encoding: .utf8), "Template Retro")
        XCTAssertEqual(fixture.apps.opened, [])
    }

    func testCancelClosesTheWindowWithoutWritingAndANewWindowStartsEmpty() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Retro"

        model.cancelNewTemplate()

        XCTAssertFalse(model.isNewTemplateShown)
        XCTAssertEqual(fixture.files, [])

        model.showNewTemplate()
        XCTAssertEqual(model.newTemplateName, "")
    }

    /// No template exists yet and no app was ever chosen: the help text and
    /// the note still name the Mac's default app for Markdown files.
    func testWithAnEmptyFolderTheHelpTextAndTheNoteNameTheDefaultMarkdownApp() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.newTemplateName = "Board"

        XCTAssertEqual(model.editor, .app(FakeTemplateOpener.textEdit))
        XCTAssertTrue(model.editor.helpText.contains("Edit opens one in TextEdit."))
        XCTAssertTrue(model.newTemplateNote.contains("Creates “Board.md” in the templates folder"))
        XCTAssertTrue(model.newTemplateNote.contains("opens it in TextEdit"))
    }

    /// With no app for Markdown files, Create shows the new file in Finder.
    func testWithoutAMarkdownAppCreateShowsTheFileInFinder() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        fixture.apps.defaultApp = nil
        fixture.apps.offered = []
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Board"

        model.createTemplate()

        let url = fixture.store.fileURL(named: "Board")
        XCTAssertEqual(fixture.apps.revealed, [url])
        XCTAssertEqual(model.notice, .warning(TemplateOpenFailure.noApp.shownInFinder(file: "Board.md")))
    }
}
