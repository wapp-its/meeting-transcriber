@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The switch behind the speech-level balance of the saved mix: on by default,
/// persisted, and wired to its toggle. Whether it reaches a recording is pinned
/// in `DualSourceRecorderLifecycleTests`, whether it reaches crash recovery in
/// `PipelineControllerLevelBalanceTests`.
@MainActor
final class LevelBalanceSettingTests: XCTestCase {
    private func freshSettings() -> AppSettings {
        let name = "level-balance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        // swiftlint:disable:previous force_unwrapping
        addTeardownBlock { DefaultsSuite.remove(name) }
        return AppSettings(defaults: defaults)
    }

    /// On, because it changes only what a person listens to: the track files
    /// everything else reads stay as recorded.
    func testBalancingIsOnByDefault() {
        XCTAssertTrue(freshSettings().levelBalanceEnabled)
    }

    func testTheChoicePersists() throws {
        let name = "level-balance-persist-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        AppSettings(defaults: defaults).levelBalanceEnabled = false
        XCTAssertFalse(
            AppSettings(defaults: defaults).levelBalanceEnabled,
            "the choice has to survive a relaunch",
        )
    }

    func testToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let before = settings.levelBalanceEnabled
        let view = AudioSettingsView(settings: settings)
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.levelBalanceToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertEqual(settings.levelBalanceEnabled, !before)
    }

    /// Unlike the transcription options around it, the switch stays usable in
    /// record-only mode: that mode still writes the mix it balances.
    func testTheToggleStaysAvailableInRecordOnlyMode() throws {
        let settings = freshSettings()
        settings.recordOnly = true
        let toggle = try AudioSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.levelBalanceToggle)
        XCTAssertFalse(toggle.isDisabled())
    }
}
