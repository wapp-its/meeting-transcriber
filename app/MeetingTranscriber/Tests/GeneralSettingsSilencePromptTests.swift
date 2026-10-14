@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring tests for the "Long Silence" section in Settings → General, one per
/// control. What the stored values mean is pinned in
/// `AppSettingsSilencePromptTests`.
@MainActor
final class GeneralSettingsSilencePromptTests: XCTestCase {
    private func makeSettings() throws -> (AppSettings, UserDefaults) {
        let suiteName = "GeneralSettingsSilencePromptTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return (AppSettings(defaults: suite), suite)
    }

    func testSwitchWritesBack() throws {
        let (settings, suite) = try makeSettings()
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.silencePromptToggle)
            .find(ViewType.Toggle.self)
        XCTAssertTrue(try toggle.isOn())

        try toggle.tap()

        XCTAssertFalse(settings.silencePromptEnabled)
        XCTAssertEqual(suite.object(forKey: "silencePromptEnabled") as? Bool, false, "a relaunch reads the stored key")
    }

    func testStepperWritesBackAndIsDisabledWhileSwitchedOff() throws {
        let (settings, _) = try makeSettings()
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        let stepper = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.silencePromptMinutesStepper)
            .find(ViewType.Stepper.self)
        try stepper.increment()

        XCTAssertEqual(settings.silencePromptMinutes, 6)

        settings.silencePromptEnabled = false
        let switchedOff = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.silencePromptMinutesStepper)
            .find(ViewType.Stepper.self)
        XCTAssertTrue(switchedOff.isDisabled(), "the minutes mean nothing while the question is switched off")
    }
}
