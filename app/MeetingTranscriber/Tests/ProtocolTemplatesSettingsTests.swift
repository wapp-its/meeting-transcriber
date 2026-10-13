@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Settings → Output → Protocol Templates: what each model operation does to
/// the folder and the default setting, then one wiring test per control. Every
/// test runs against a temp folder and a throwaway defaults suite, and records
/// opened and trashed files instead of reaching the Finder or the real Trash.
@MainActor
final class ProtocolTemplatesSettingsTests: XCTestCase {
    private func makeStore() throws -> ProtocolTemplateStore {
        try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "protocol-templates-settings"))
    }

    private func makeSettings() throws -> AppSettings {
        let suite = "ProtocolTemplatesSettingsTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func makeModel(
        _ store: ProtocolTemplateStore,
        settings: AppSettings? = nil,
        openFile: @escaping (URL) -> Void = { _ in },
    ) throws -> ProtocolTemplatesModel {
        try ProtocolTemplatesModel(store: store, settings: settings ?? makeSettings(), openFile: openFile)
    }

    private func write(_ names: [String], in store: ProtocolTemplateStore) throws {
        for name in names {
            try "Template \(name)".write(to: store.fileURL(named: name), atomically: true, encoding: .utf8)
        }
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - Model

    func testCreateWritesTheBuiltInTextClearsTheFieldAndOpensTheFile() throws {
        let store = try makeStore()
        var opened: [URL] = []
        let model = try makeModel(store) { opened.append($0) }
        model.newName = "  Board  "

        model.create()

        let url = store.fileURL(named: "Board")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ProtocolGenerator.protocolPrompt)
        XCTAssertEqual(model.newName, "")
        XCTAssertNil(model.message)
        XCTAssertEqual(model.names, ["Board"])
        XCTAssertEqual(opened, [url])
    }

    func testARefusedNameSetsTheMessageAndCreatesNothing() throws {
        let store = try makeStore()
        try write(["Board"], in: store)
        let cases: [(String, ProtocolTemplateName.Refusal)] = [
            ("   ", .empty),
            (String(repeating: "x", count: ProtocolTemplateName.maxLength + 1), .tooLong),
            ("a/b", .forbiddenCharacter),
            (".hidden", .leadingDot),
            ("board", .duplicate),
        ]
        for (raw, refusal) in cases {
            var opened: [URL] = []
            let model = try makeModel(store) { opened.append($0) }
            model.newName = raw

            model.create()

            XCTAssertEqual(model.message, refusal.errorDescription, raw)
            XCTAssertEqual(model.newName, raw, raw)
            XCTAssertEqual(contents(of: store.directory), ["Board.md"], raw)
            XCTAssertEqual(opened, [], raw)
        }
    }

    func testAFailedCreateShowsTheErrorAndLeavesTheFolderUnchanged() throws {
        let store = try makeStore()
        try write(["Board"], in: store)
        let folder = store.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        var opened: [URL] = []
        let model = try makeModel(store) { opened.append($0) }
        model.newName = "Retro"

        model.create()

        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.newName, "Retro")
        XCTAssertEqual(contents(of: store.directory), ["Board.md"])
        XCTAssertEqual(opened, [])
    }

    func testDeleteTrashesThroughTheInjectedTrashAndResetsADeletedDefault() throws {
        let store = try makeStore()
        try write(["Board", "Retro"], in: store)
        let settings = try makeSettings()
        settings.defaultProtocolTemplate = .file(name: "Retro")
        var trashed: [URL] = []
        let trash: (URL) throws -> Void = { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        let model = ProtocolTemplatesModel(store: store, settings: settings, trashItem: trash)

        model.requestDelete("Board")
        XCTAssertEqual(model.pendingDeletion, "Board")
        model.confirmDelete("Board")
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(settings.defaultProtocolTemplate, .file(name: "Retro"), "deleting another template keeps the default")

        model.confirmDelete("Retro")

        XCTAssertEqual(trashed, [store.fileURL(named: "Board"), store.fileURL(named: "Retro")])
        XCTAssertEqual(settings.defaultProtocolTemplate, .builtIn)
        XCTAssertEqual(model.names, [])
        XCTAssertNil(model.message)
    }

    func testAFailedDeleteShowsTheErrorAndKeepsTheTemplateAndTheDefault() throws {
        let store = try makeStore()
        try write(["Board"], in: store)
        let settings = try makeSettings()
        settings.defaultProtocolTemplate = .file(name: "Board")
        let refusingTrash: (URL) throws -> Void = { url in
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let model = ProtocolTemplatesModel(store: store, settings: settings, trashItem: refusingTrash)

        model.confirmDelete("Board")

        XCTAssertNotNil(model.message)
        XCTAssertEqual(contents(of: store.directory), ["Board.md"])
        XCTAssertEqual(model.names, ["Board"])
        XCTAssertEqual(settings.defaultProtocolTemplate, .file(name: "Board"))
    }

    func testDefaultSelectionShowsTheBuiltInForAMissingFileAndWritesTheSetting() throws {
        let store = try makeStore()
        try write(["Board"], in: store)
        let settings = try makeSettings()
        settings.defaultProtocolTemplate = .file(name: "Gone")
        let model = ProtocolTemplatesModel(store: store, settings: settings)

        XCTAssertEqual(model.defaultSelection, .builtIn)
        XCTAssertEqual(settings.defaultProtocolTemplate, .file(name: "Gone"), "reading must not rewrite the setting")

        model.defaultSelection = .file(name: "Board")

        XCTAssertEqual(settings.defaultProtocolTemplate, .file(name: "Board"))
        XCTAssertEqual(model.defaultSelection, .file(name: "Board"))
    }

    /// Finder renames the default `Board.md` to `board.md`. On the default
    /// case-insensitive volume the stored "Board" still resolves, so the
    /// picker must select the listed "board", and deleting it resets the default.
    func testACaseOnlyRenameOfTheDefaultStaysSelectedAndDeletable() throws {
        let store = try makeStore()
        let caseSensitive = try store.directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        try XCTSkipIf(caseSensitive == true, "a case-only rename only keeps the old name resolving on a case-insensitive volume")
        try write(["Board"], in: store)
        let settings = try makeSettings()
        settings.defaultProtocolTemplate = .file(name: "Board")
        let fm = FileManager.default
        try fm.moveItem(at: store.fileURL(named: "Board"), to: store.fileURL(named: "board"))
        let trash: (URL) throws -> Void = { try fm.removeItem(at: $0) }
        let model = ProtocolTemplatesModel(store: store, settings: settings, trashItem: trash)
        model.reload()

        XCTAssertEqual(model.names, ["board"])
        XCTAssertEqual(model.defaultSelection, .file(name: "board"))

        model.confirmDelete("board")

        XCTAssertEqual(settings.defaultProtocolTemplate, .builtIn)
    }

    func testOpenFolderCreatesAMissingFolderWithoutTheMigrationMarker() throws {
        let root = try makeTempDirectory(prefix: "protocol-templates-settings")
        let store = ProtocolTemplateStore(directory: root.appendingPathComponent("Protocol Templates"))
        var opened: [URL] = []
        let model = try makeModel(store) { opened.append($0) }

        model.openFolder()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(contents(of: store.directory), [], "the migration marker is the migration's to write")
        XCTAssertEqual(opened, [store.directory])
        XCTAssertNil(model.message)
    }

    func testReloadPicksUpAFileAddedOnDisk() throws {
        let store = try makeStore()
        try write(["Board"], in: store)
        let model = try makeModel(store)
        model.reload()
        XCTAssertEqual(model.names, ["Board"])

        try write(["Retro"], in: store)
        model.reload()

        XCTAssertEqual(model.names, ["Board", "Retro"])
    }

    // MARK: - Wiring

    /// The section over `store` holding the templates "Board" and "Retro".
    private func makeView(
        store: ProtocolTemplateStore,
        settings: AppSettings? = nil,
        openFile: @escaping (URL) -> Void = { _ in },
    ) throws -> (ProtocolTemplatesSettingsView, ProtocolTemplatesModel) {
        try write(["Board", "Retro"], in: store)
        let model = try makeModel(store, settings: settings, openFile: openFile)
        model.reload()
        return (ProtocolTemplatesSettingsView(model: model), model)
    }

    private func button(_ identifier: String, in view: ProtocolTemplatesSettingsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: identifier).button()
    }

    func testDefaultPickerWritesTheSetting() throws {
        let settings = try makeSettings()
        let (view, _) = try makeView(store: makeStore(), settings: settings)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateDefaultPicker)
            .find(ViewType.Picker.self)
            .select(value: ProtocolTemplateID.file(name: "Retro"))

        XCTAssertEqual(settings.defaultProtocolTemplate, .file(name: "Retro"))
    }

    func testNameFieldWritesTheModel() throws {
        let (view, model) = try makeView(store: makeStore())

        try view.inspect()
            .find(ViewType.TextField.self) { try $0.accessibilityIdentifier() == A11yID.protocolTemplateNameField }
            .setInput("Workshop")

        XCTAssertEqual(model.newName, "Workshop")
    }

    func testCreateButtonCreatesTheTypedTemplate() throws {
        let store = try makeStore()
        var opened: [URL] = []
        let (view, model) = try makeView(store: store) { opened.append($0) }
        model.newName = "Workshop"

        try button(A11yID.protocolTemplateCreateButton, in: view).tap()

        XCTAssertEqual(model.names, ["Board", "Retro", "Workshop"])
        XCTAssertEqual(opened, [store.fileURL(named: "Workshop")])
    }

    func testEditOfRowZeroOpensItsFile() throws {
        let store = try makeStore()
        var opened: [URL] = []
        let (view, _) = try makeView(store: store) { opened.append($0) }

        try button(A11yID.protocolTemplateEdit(0), in: view).tap()

        XCTAssertEqual(opened, [store.fileURL(named: "Board")])
    }

    func testDeleteOfRowZeroAsksForConfirmation() throws {
        let store = try makeStore()
        let (view, model) = try makeView(store: store)

        try button(A11yID.protocolTemplateDelete(0), in: view).tap()

        XCTAssertEqual(model.pendingDeletion, "Board")
        XCTAssertEqual(contents(of: store.directory), ["Board.md", "Retro.md"], "nothing is deleted before the confirmation")
    }

    func testOpenFolderButtonOpensTheFolder() throws {
        let store = try makeStore()
        var opened: [URL] = []
        let (view, _) = try makeView(store: store) { opened.append($0) }

        try button(A11yID.protocolTemplatesOpenFolderButton, in: view).tap()

        XCTAssertEqual(opened, [store.directory])
    }
}
