@testable import MeetingTranscriber
import UserNotifications
import ViewInspector
import XCTest

/// Wiring test for the consent-prompt warning: `BrowserConsentReadinessTests`
/// owns the decision logic, this only proves the General tab actually renders it.
///
/// It exists because the failure it guards against is invisible by construction:
/// with notifications denied watching looks enabled, detection keeps firing, and
/// no meeting that asks first is ever recorded. Settings is the only surface
/// that can say so, since warning by notification would depend on the very
/// channel that is broken.
@MainActor
final class GeneralSettingsBrowserWarningTests: XCTestCase {
    /// Isolated defaults per call, torn down by the test itself — the idiom
    /// `makeRPCTestState()` uses, which needs no stored properties, no
    /// setUp/tearDown overrides and no implicitly-unwrapped optionals.
    private func makeSettings(browserMeetings: Bool, recordWithoutAsking: [String] = []) throws -> AppSettings {
        let suiteName = "GeneralSettingsBrowserWarningTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.watchBrowserMeetings = browserMeetings
        settings.recordWithoutAskingApps = recordWithoutAsking
        return settings
    }

    /// Authorised and fully visible, then override the one setting under test.
    private func visibility(
        authorization: UNAuthorizationStatus = .authorized,
        alertStyle: UNAlertStyle = .banner,
        timeSensitive: UNNotificationSetting = .enabled,
    ) -> NotificationVisibility {
        NotificationVisibility(
            authorization: authorization,
            alert: .enabled,
            alertStyle: alertStyle,
            timeSensitive: timeSensitive,
            scheduledDelivery: .disabled,
        )
    }

    private func warningText(
        browserMeetings: Bool,
        visibility: NotificationVisibility?,
        recordWithoutAsking: [String] = [],
    ) throws -> String? {
        let view = try GeneralSettingsView(
            settings: makeSettings(browserMeetings: browserMeetings, recordWithoutAsking: recordWithoutAsking),
            notificationVisibility: visibility,
        )
        let found = try? view.inspect().find(viewWithAccessibilityIdentifier: A11yID.browserConsentWarning)
        return try found?.text().string()
    }

    func test_deniedNotifications_showTheWarning() throws {
        let text = try warningText(browserMeetings: true, visibility: visibility(authorization: .denied))
        let warning = try XCTUnwrap(text, "denied notifications must warn in the General tab")
        XCTAssertTrue(warning.lowercased().contains("record"), warning)
    }

    func test_authorizedNotifications_showNoWarning() throws {
        XCTAssertNil(try warningText(browserMeetings: true, visibility: visibility()))
    }

    /// The prompt is no longer the browser's alone: Teams, Zoom and Webex are
    /// watched by default and ask first, so a broken notification channel
    /// stops them being recorded with browser watching off.
    func test_watchedNativeAppThatAsks_showsTheWarningWithBrowserWatchingOff() throws {
        let text = try warningText(browserMeetings: false, visibility: visibility(authorization: .denied))
        XCTAssertNotNil(text, "a watched app that asks first needs a visible prompt")
    }

    func test_everyWatchedAppRecordingWithoutAsking_showsNoWarningEvenWhenDenied() throws {
        XCTAssertNil(try warningText(
            browserMeetings: false,
            visibility: visibility(authorization: .denied),
            recordWithoutAsking: ["Microsoft Teams", "Zoom", "Webex"],
        ))
    }

    /// The regression this whole change is about: authorisation says yes, the
    /// alert style says no banner, and the old view saw only the first half.
    func test_authorizedButNoBanner_showsTheWarning() throws {
        let text = try warningText(browserMeetings: true, visibility: visibility(alertStyle: .none))
        let warning = try XCTUnwrap(text, "an invisible prompt must warn in the General tab")
        XCTAssertTrue(warning.lowercased().contains("record"), warning)
    }

    /// Before the first permission check the status is unknown. Guessing either
    /// way is wrong: claiming a problem would cry wolf on every launch, and
    /// claiming health would hide a real one, so render nothing until it is read.
    func test_unknownAuthorization_showsNoWarningYet() throws {
        XCTAssertNil(try warningText(browserMeetings: true, visibility: nil))
    }

    /// The General tab is reached through `SettingsView`, so the value has to
    /// survive one more hop than the tests above exercise. Without this, passing
    /// nil (or the wrong property) from the scene would go unnoticed.
    func test_settingsView_forwardsAuthorizationToTheGeneralTab() throws {
        let view = try SettingsView(
            settings: makeSettings(browserMeetings: true),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            updateChecker: nil,
            notificationVisibility: visibility(authorization: .denied),
            recognitionStatsLog: RecognitionStatsLog(),
            stageTimingLog: StageTimingLog(),
        )
        let warning = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.browserConsentWarning)
        XCTAssertTrue(try warning.text().string().lowercased().contains("record"))
    }
}
