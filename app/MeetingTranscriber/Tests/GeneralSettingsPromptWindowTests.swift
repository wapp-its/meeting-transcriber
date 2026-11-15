@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring tests for the "Prompts" section in Settings → General: the switch
/// that also shows the open questions in a window below the menu bar icon, and
/// its help text. The stored value's default and its unreadable cases are
/// pinned in `AppSettingsTests`.
@MainActor
final class GeneralSettingsPromptWindowTests: XCTestCase {
    private func makeSuite() throws -> UserDefaults {
        let suiteName = "GeneralSettingsPromptWindowTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(DefaultsSuite.open(suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return suite
    }

    func testSwitchWritesBackAndSurvivesARelaunch() throws {
        let suite = try makeSuite()
        let settings = AppSettings(defaults: suite)
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.promptWindowToggle)
            .find(ViewType.Toggle.self)
        XCTAssertFalse(try toggle.isOn())

        try toggle.tap()

        XCTAssertTrue(settings.promptWindowEnabled)
        XCTAssertTrue(AppSettings(defaults: suite).promptWindowEnabled, "a relaunch reads the stored value")
    }

    func testGroupHoldsOnlyTheSwitchAndItsHelpTextAfterRecordWithoutAsking() throws {
        let view = try GeneralSettingsView(settings: AppSettings(defaults: makeSuite()), notificationVisibility: nil)
        let sections = try view.inspect().findAll(ViewType.Section.self)
        let headers = try sections.map { try $0.header().find(ViewType.Text.self).string() }
        let index = try XCTUnwrap(headers.firstIndex(of: "Prompts"))
        XCTAssertEqual(headers[index - 1], "Record Without Asking")

        let group = sections[index]
        XCTAssertEqual(group.count, 2, "only the switch and its help text")
        XCTAssertEqual(try group.toggle(0).accessibilityIdentifier(), A11yID.promptWindowToggle)
        XCTAssertEqual(try group.toggle(0).labelView().text().string(), "Show prompts below the menu bar icon")
        XCTAssertEqual(try group.text(1).accessibilityIdentifier(), A11yID.promptWindowHelp)
        XCTAssertEqual(
            try group.text(1).string(),
            """
            The "Record … meeting?" question and the "Meeting seems to have ended" countdown also appear \
            in a small window below the menu bar icon, even when a Focus mode holds notifications back. \
            Others may see this window while you share your screen.
            """,
        )
    }
}
