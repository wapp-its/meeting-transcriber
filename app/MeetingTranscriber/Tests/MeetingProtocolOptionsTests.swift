@testable import MeetingTranscriber
import XCTest

/// The per-recording options as values: how the typed background is
/// normalised, how the draft hands it over and starts again, and what the
/// options form is shown, read from the settings and a temp templates folder.
@MainActor
final class MeetingProtocolOptionsTests: XCTestCase {
    func testBackgroundIsTrimmedAndBlankBecomesNil() {
        let cases: [(String, String?)] = [
            ("  Agenda: budget\nGoal: decide  \n", "Agenda: budget\nGoal: decide"),
            ("", nil),
            (" \n\t ", nil),
        ]
        for (raw, expected) in cases {
            let options = MeetingProtocolOptions(template: .file(name: "Board"), rawBackground: raw)
            XCTAssertEqual(options.background, expected, "raw: \(raw.debugDescription)")
            XCTAssertEqual(options.template, .file(name: "Board"))
        }
    }

    func testDraftHandsOverItsOptionsAndResetStartsAgain() {
        let draft = ProtocolOptionsDraft(template: .file(name: "Board"), background: " Alice, Bob ")

        XCTAssertEqual(draft.options, MeetingProtocolOptions(template: .file(name: "Board"), rawBackground: "Alice, Bob"))

        draft.reset(to: .file(name: "Retro"))

        XCTAssertEqual(draft.template, .file(name: "Retro"))
        XCTAssertEqual(draft.background, "")
    }

    // MARK: - Context

    private func makeStore(_ names: [String]) throws -> ProtocolTemplateStore {
        let store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "protocol-options-context"))
        for name in names {
            try "Template \(name)".write(to: store.fileURL(named: name), atomically: true, encoding: .utf8)
        }
        return store
    }

    private func makeSettings() throws -> AppSettings {
        let suite = "MeetingProtocolOptionsTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    func testContextListsTheBuiltInFirstAndReadsTheSettings() throws {
        let store = try makeStore(["Retro", "Board"])
        let settings = try makeSettings()
        settings.defaultProtocolTemplate = .file(name: "Retro")
        settings.protocolProvider = .none
        settings.recordOnly = true

        let context = ProtocolOptionsContext(
            choices: ProtocolTemplateChoices(settings: settings, store: store),
            use: ProtocolOptionsUse(settings: settings),
        )

        XCTAssertEqual(
            context,
            ProtocolOptionsContext(
                templates: [.builtIn, .file(name: "Board"), .file(name: "Retro")],
                defaultTemplate: .file(name: "Retro"),
                destination: .off,
                recordOnly: true,
            ),
        )
    }

    /// What an open window reads on every redraw follows the settings at the
    /// call, not when the value type was first made.
    func testUseReadsTheSettingsAtTheCall() throws {
        let settings = try makeSettings()
        settings.protocolProvider = .openAICompatible
        settings.openAIEndpoint = "http://localhost:11434/v1"
        settings.recordOnly = false
        XCTAssertEqual(ProtocolOptionsUse(settings: settings), ProtocolOptionsUse(destination: .local(host: "localhost"), recordOnly: false))

        settings.openAIEndpoint = "https://api.example.com/v1"
        settings.recordOnly = true
        XCTAssertEqual(
            ProtocolOptionsUse(settings: settings),
            ProtocolOptionsUse(destination: .remote(name: "api.example.com"), recordOnly: true),
        )
    }

    /// A default naming a missing file preselects the built-in, as new jobs
    /// get it; one renamed in Finder only in case preselects the listed name,
    /// since the stored spelling matches no picker row.
    func testContextDefaultIsTheEffectiveDefaultSpeltAsListed() throws {
        let store = try makeStore(["board"])
        let settings = try makeSettings()

        settings.defaultProtocolTemplate = .file(name: "Gone")
        XCTAssertEqual(ProtocolTemplateChoices(settings: settings, store: store).defaultTemplate, .builtIn)

        settings.defaultProtocolTemplate = .file(name: "Board")
        let caseSensitiveVolume = FileManager.default.fileExists(atPath: store.fileURL(named: "Board").path) == false
        try XCTSkipIf(caseSensitiveVolume, "needs the case-insensitive default volume")
        XCTAssertEqual(ProtocolTemplateChoices(settings: settings, store: store).defaultTemplate, .file(name: "board"))
    }
}
