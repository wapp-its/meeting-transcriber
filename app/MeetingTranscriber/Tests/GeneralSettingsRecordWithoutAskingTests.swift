@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring test for the "record without asking" switches in the General tab.
/// `AppMeetingPatternTests` owns who asks; this proves each switch exists,
/// writes back to `AppSettings.recordWithoutAskingApps`, and is off by default.
@MainActor
final class GeneralSettingsRecordWithoutAskingTests: XCTestCase {
    private func makeSettings() throws -> AppSettings {
        let suiteName = "GeneralSettingsRecordWithoutAskingTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        // Watch every app with a switch, so none of them is disabled.
        settings.watchWeChat = true
        settings.watchTencentMeeting = true
        settings.watchFaceTime = true
        settings.watchWhatsApp = true
        return settings
    }

    private func toggle(_ appName: String, in view: GeneralSettingsView) throws -> InspectableView<ViewType.Toggle> {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.recordWithoutAskingToggle(appName))
            .find(ViewType.Toggle.self)
    }

    func testEachAppsSwitchIsOffByDefaultAndWritesBack() throws {
        let settings = try makeSettings()
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)
        let apps = AppMeetingPattern.recordWithoutAskingCandidates.map(\.appName)
        XCTAssertEqual(
            apps,
            ["Microsoft Teams", "Zoom", "Webex", "WeChat", "Tencent Meeting", "FaceTime", "WhatsApp"],
        )

        for app in apps {
            XCTAssertFalse(try toggle(app, in: view).isOn(), "\(app) must ask first by default")
            try toggle(app, in: view).tap()
        }
        XCTAssertEqual(settings.recordWithoutAskingApps, apps, "each switch adds its own app")

        try toggle("Zoom", in: view).tap()
        XCTAssertEqual(
            settings.recordWithoutAskingApps,
            apps.filter { $0 != "Zoom" },
            "switching one off leaves the others alone",
        )
    }

    /// The switch has no effect while its app is not watched, so it says so.
    func testASwitchIsDisabledWhileItsAppIsNotWatched() throws {
        let settings = try makeSettings()
        settings.watchZoom = false
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)
        XCTAssertTrue(try toggle("Zoom", in: view).isDisabled())
        XCTAssertFalse(try toggle("Microsoft Teams", in: view).isDisabled())
    }

    /// Browser meetings always ask, so they get no switch.
    func testBrowserMeetingsHaveNoSwitch() throws {
        let settings = try makeSettings()
        settings.watchBrowserMeetings = true
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)
        XCTAssertNil(try? view.inspect().find(
            viewWithAccessibilityIdentifier: A11yID.recordWithoutAskingToggle(AppMeetingPattern.browserMeetings.appName),
        ))
    }
}
