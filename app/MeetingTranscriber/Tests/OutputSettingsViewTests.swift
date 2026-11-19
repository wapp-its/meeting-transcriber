@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class OutputSettingsViewTests: XCTestCase {
    // MARK: - OutputSettingsLogic.displayPath

    func testDisplayPathAbbreviatesHomePrefix() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alice/Documents/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "~/Documents/Meetings",
        )
    }

    func testDisplayPathReturnsFullPathOutsideHome() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Volumes/External/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Volumes/External/Meetings",
        )
    }

    func testDisplayPathExactlyHomeReturnsTilde() {
        let home = URL(fileURLWithPath: "/Users/alice")
        XCTAssertEqual(OutputSettingsLogic.displayPath(for: home, home: home), "~")
    }

    func testDisplayPathDifferentUserHomeReturnsFull() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/bob/Documents")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/bob/Documents",
        )
    }

    /// Regression guard: a naive `hasPrefix` match treats `/Users/alicebob/foo`
    /// as inside `/Users/alice` and yields `~bob/foo`. Boundary must be a path
    /// component (`/` or end-of-string).
    func testDisplayPathDoesNotMatchAcrossComponentBoundary() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alicebob/foo")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/alicebob/foo",
        )
    }

    // MARK: - OutputSettingsLogic.retentionDaysLabel

    func testRetentionDaysLabelSpellsOutZeroAndSingular() {
        XCTAssertEqual(OutputSettingsLogic.retentionDaysLabel(0), "0 days (right away)")
        XCTAssertEqual(OutputSettingsLogic.retentionDaysLabel(1), "1 day")
        XCTAssertEqual(OutputSettingsLogic.retentionDaysLabel(30), "30 days")
    }

    // MARK: - OutputSettingsLogic.mergePickerOptions

    func testMergePickerOptionsPrependsSelectedWhenAbsent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "custom-tag:latest",
        )
        XCTAssertEqual(result, ["custom-tag:latest", "gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedWhenSelectedPresent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedForEmptySelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4"], selected: "",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableYieldsJustSelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: [], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableAndEmptySelectedYieldsEmpty() {
        let result = OutputSettingsLogic.mergePickerOptions(available: [], selected: "")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Protocol language list

    func testProtocolLanguagesContainNoDuplicates() {
        // The picker uses the names as ForEach ids, so a repeat would collide.
        let languages = AppSettings.protocolLanguages
        XCTAssertEqual(languages.count, Set(languages).count)
    }

    // MARK: - Render

    func testViewRendersWithDefaultSettings() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        let view = OutputSettingsView(settings: settings)
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - Recording Retention section

    /// The original's section, between the fork's Notion export and Meeting Notes,
    /// with the caption naming the fork's Keep mark.
    func testTheRetentionSectionSitsAboveMeetingNotesAndNamesKeep() throws {
        let view = OutputSettingsView(settings: AppSettings(defaults: makeIsolatedDefaults()))
        let body = try view.inspect()

        let headers = try body.findAll(ViewType.Section.self).map { section in
            try section.header().find(ViewType.Text.self).string()
        }
        let retention = try XCTUnwrap(headers.firstIndex(of: "Recording Retention"))
        XCTAssertEqual(headers[retention + 1], "Meeting Notes")
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.recordingRetentionToggle))
        let captions = try body.findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(captions.contains { $0.contains("neither are meetings marked Keep in All Recordings") })
    }

    func testOpenAIProviderExplainsConnectionsAndTheirSettingsInHelp() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        let body = try OutputSettingsView(settings: settings).inspect()
        let helpTexts = try body.findAll(HelpBadge.self).map { try $0.actualView().text }

        XCTAssertTrue(helpTexts.contains(SettingsHelp.openAIProvider))
        XCTAssertTrue(helpTexts.contains(SettingsHelp.openAIConnection))
        XCTAssertNoThrow(try body.find(text: "Connection Settings"))
    }

    func testAdvancedIsCollapsedForAValidHeaderName() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "x-api-key"
        let body = try OutputSettingsView(settings: settings).inspect()

        // The Advanced row renders, so the missing picker is not a failed lookup.
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAdvancedToggle))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyPlacementPicker))
    }

    func testAnInvalidHeaderNameKeepsAdvancedOpen() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        settings.openAIAPIKeyPlacement = .customHeader
        settings.openAIAPIKeyHeaderName = "Content-Type"
        let body = try OutputSettingsView(settings: settings).inspect()

        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIAPIKeyHeaderNameWarning))
    }

    /// The templates replace the original's prompt row in Meeting Notes, so
    /// they follow that section, and AI Provider keeps its connection below it.
    func testTheTemplateSectionsSitBetweenMeetingNotesAndTheProvider() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.protocolProvider = .openAICompatible
        let store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "output-templates"))
        let body = try OutputSettingsView(settings: settings, templateStore: store).inspect()

        let headers = try body.findAll(ViewType.Section.self).map { section in
            try section.header().find(ViewType.Text.self).string()
        }
        let notes = try XCTUnwrap(headers.firstIndex(of: "Meeting Notes"))
        XCTAssertEqual(
            Array(headers[notes...].prefix(5)),
            ["Meeting Notes", "Meeting Notes Templates", "Template Rules", "AI Provider", "Connection Settings"],
        )
    }

    #if !APPSTORE
        /// The fork's providers keep their rows in AI Provider and explain
        /// themselves in its header, as the original's providers do.
        func testTheForkProvidersExplainThemselvesInTheProviderHeader() throws {
            let cases: [(ProtocolProvider, String, String)] = [
                (.codexCLI, SettingsHelp.codexCLIProvider, A11yID.codexProviderNote),
                (.customCommand, SettingsHelp.customCommandProvider, A11yID.customCommandEditor),
                (.localModel, SettingsHelp.localModelProvider, A11yID.localModelCheckButton),
            ]
            for (provider, help, rowID) in cases {
                let settings = AppSettings(defaults: makeIsolatedDefaults())
                settings.protocolProvider = provider
                let body = try OutputSettingsView(settings: settings).inspect()
                let section = try body.find(viewWithAccessibilityIdentifier: A11yID.protocolProviderSection)
                XCTAssertNoThrow(try section.find(HelpBadge.self) { try $0.actualView().text == help }, "\(provider)")
                XCTAssertNoThrow(try section.find(viewWithAccessibilityIdentifier: rowID), "\(provider)")
            }
        }

        func testClaudeCLIProviderExplainsItselfInHelpAndKeepsTheBillingNoteInView() throws {
            let settings = AppSettings(defaults: makeIsolatedDefaults())
            settings.protocolProvider = .claudeCLI
            let body = try OutputSettingsView(settings: settings).inspect()
            XCTAssertNoThrow(try body.find(HelpBadge.self) { try $0.actualView().text == SettingsHelp.claudeCLIProvider })
            XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.claudeAPIKeyBillingNote))
        }

        func testClaudeCLIProviderHidesConnectionSettings() throws {
            let settings = AppSettings(defaults: makeIsolatedDefaults())
            settings.protocolProvider = .claudeCLI
            let body = try OutputSettingsView(settings: settings).inspect()
            // The binary picker renders, so the missing section is not a failed lookup.
            XCTAssertNoThrow(try body.find(text: "Claude CLI"))
            XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionSection))
        }
    #endif

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OutputSettingsViewTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        guard let defaults = DefaultsSuite.open(suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        return defaults
    }
}
