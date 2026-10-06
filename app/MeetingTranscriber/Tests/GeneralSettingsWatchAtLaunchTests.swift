@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring test for "Watch for meetings when the app starts". The app reads
/// `autoWatch` at launch (`MeetingTranscriberApp.shouldAutoWatch`); before
/// this switch it could only be set with `defaults write`.
@MainActor
final class GeneralSettingsWatchAtLaunchTests: XCTestCase {
    func testSwitchIsOffByDefaultAndWritesBack() throws {
        let suiteName = "GeneralSettingsWatchAtLaunchTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.watchAtLaunchToggle)
            .find(ViewType.Toggle.self)
        XCTAssertFalse(try toggle.isOn())

        try toggle.tap()

        XCTAssertTrue(settings.autoWatch)
        XCTAssertTrue(suite.bool(forKey: "autoWatch"), "the launch path reads the stored key")
    }
}
