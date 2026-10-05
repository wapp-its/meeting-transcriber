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

    /// Without the prompt nothing reminds anyone at the moment recording
    /// starts, so a switched-on app carries that reminder in Settings, and
    /// only while its switch is on.
    func testTheConsentNoteShowsOnlyWhileAnAppsSwitchIsOn() throws {
        let settings = try makeSettings()
        settings.recordWithoutAskingApps = ["Zoom"]
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)
        func note(_ appName: String) throws -> String {
            try view.inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.recordWithoutAskingConsentNote(appName))
                .find(ViewType.Text.self)
                .string()
        }

        XCTAssertEqual(
            try note("Zoom"),
            """
            Without the prompt, making sure everyone agrees to being recorded is entirely \
            up to you (Art. 179bis StGB, Swiss Criminal Code).
            """,
        )
        XCTAssertNil(try? note("Microsoft Teams"), "a switch that is off shows no note")

        try toggle("Microsoft Teams", in: view).tap()
        XCTAssertNoThrow(try note("Microsoft Teams"), "switching on shows the note")
        try toggle("Zoom", in: view).tap()
        XCTAssertNil(try? note("Zoom"), "switching off hides the note")
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
