@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Settings → Output → Meeting Notes Templates: what editing, deleting, the
/// default picker and the folder do to the folder and the default setting,
/// then one wiring test per control. Every test runs on
/// `ProtocolTemplatesFixture`.
@MainActor
final class ProtocolTemplatesSettingsTests: XCTestCase {
    // MARK: - Model

    func testEditOpensTheTemplateFile() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()

        model.edit("Board")

        XCTAssertEqual(fixture.opened, [fixture.store.fileURL(named: "Board")])
    }

    func testDeleteTrashesThroughTheInjectedTrashAndResetsADeletedDefault() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        fixture.settings.defaultProtocolTemplate = .file(name: "Retro")
        let model = fixture.makeModel()

        model.requestDelete("Board")
        XCTAssertEqual(model.pendingDeletion, "Board")
        model.confirmDelete("Board")
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Retro"), "deleting another template keeps the default")

        model.confirmDelete("Retro")

        XCTAssertEqual(fixture.trashed, [fixture.store.fileURL(named: "Board"), fixture.store.fileURL(named: "Retro")])
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .builtIn)
        XCTAssertEqual(model.names, [])
        XCTAssertNil(model.message)
    }

    func testAFailedDeleteShowsTheErrorAndKeepsTheTemplateAndTheDefault() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.settings.defaultProtocolTemplate = .file(name: "Board")
        let model = fixture.makeModel { url in
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }

        model.confirmDelete("Board")

        XCTAssertNotNil(model.message)
        XCTAssertEqual(fixture.files, ["Board.md"])
        XCTAssertEqual(model.names, ["Board"])
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Board"))
    }

    func testDefaultSelectionShowsTheBuiltInForAMissingFileAndWritesTheSetting() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.settings.defaultProtocolTemplate = .file(name: "Gone")
        let model = fixture.makeModel()

        XCTAssertEqual(model.defaultSelection, .builtIn)
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Gone"), "reading must not rewrite the setting")

        model.defaultSelection = .file(name: "Board")

        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Board"))
        XCTAssertEqual(model.defaultSelection, .file(name: "Board"))
    }

    /// Finder renames the default `Board.md` to `board.md`. On the default
    /// case-insensitive volume the stored "Board" still resolves, so the
    /// picker must select the listed "board", and deleting it resets the default.
    func testACaseOnlyRenameOfTheDefaultStaysSelectedAndDeletable() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let store = fixture.store
        let caseSensitive = try store.directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        try XCTSkipIf(caseSensitive == true, "a case-only rename only keeps the old name resolving on a case-insensitive volume")
        fixture.settings.defaultProtocolTemplate = .file(name: "Board")
        try FileManager.default.moveItem(at: store.fileURL(named: "Board"), to: store.fileURL(named: "board"))
        let model = fixture.makeModel()

        XCTAssertEqual(model.names, ["board"])
        XCTAssertEqual(model.defaultSelection, .file(name: "board"))

        model.confirmDelete("board")

        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .builtIn)
    }

    func testOpenFolderCreatesAMissingFolderWithoutTheMigrationMarker() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        try FileManager.default.removeItem(at: fixture.store.directory)
        let model = fixture.makeModel()

        model.openFolder()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(fixture.files, [], "the migration marker is the migration's to write")
        XCTAssertEqual(fixture.opened, [fixture.store.directory])
        XCTAssertNil(model.message)
    }

    /// A file where the folder should be: the folder cannot be created, the
    /// error shows, nothing opens, and the next open that works clears it.
    func testAFolderThatCannotBeCreatedShowsTheErrorAndOpensNothing() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        try FileManager.default.removeItem(at: fixture.store.directory)
        try Data().write(to: fixture.store.directory)
        let model = fixture.makeModel()

        model.openFolder()

        XCTAssertNotNil(model.message)
        XCTAssertEqual(fixture.opened, [])

        try FileManager.default.removeItem(at: fixture.store.directory)
        model.openFolder()

        XCTAssertNil(model.message)
    }

    func testReloadPicksUpAFileAddedOnDisk() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()
        XCTAssertEqual(model.names, ["Board"])

        try fixture.write(["Retro"])
        model.reload()

        XCTAssertEqual(model.names, ["Board", "Retro"])
    }

    // MARK: - Wiring

    /// The section over a folder holding the templates "Board" and "Retro".
    private func makeView() throws -> (ProtocolTemplatesSettingsView, ProtocolTemplatesModel, ProtocolTemplatesFixture) {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        let model = fixture.makeModel()
        return (ProtocolTemplatesSettingsView(model: model), model, fixture)
    }

    private func button(_ identifier: String, in view: ProtocolTemplatesSettingsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: identifier).button()
    }

    func testDefaultPickerWritesTheSetting() throws {
        let (view, _, fixture) = try makeView()

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateDefaultPicker)
            .find(ViewType.Picker.self)
            .select(value: ProtocolTemplateID.file(name: "Retro"))

        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Retro"))
    }

    func testEditOfRowOneOpensItsFile() throws {
        let (view, _, fixture) = try makeView()

        try button(A11yID.protocolTemplateEdit(1), in: view).tap()

        XCTAssertEqual(fixture.opened, [fixture.store.fileURL(named: "Retro")])
    }

    func testDeleteOfRowZeroAsksForConfirmation() throws {
        let (view, model, fixture) = try makeView()

        try button(A11yID.protocolTemplateDelete(0), in: view).tap()

        XCTAssertEqual(model.pendingDeletion, "Board")
        XCTAssertEqual(fixture.files, ["Board.md", "Retro.md"], "nothing is deleted before the confirmation")
    }

    func testOpenFolderButtonOpensTheFolder() throws {
        let (view, _, fixture) = try makeView()

        try button(A11yID.protocolTemplatesOpenFolderButton, in: view).tap()

        XCTAssertEqual(fixture.opened, [fixture.store.directory])
    }
}
