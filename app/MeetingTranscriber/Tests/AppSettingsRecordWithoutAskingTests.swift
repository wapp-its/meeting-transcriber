import Foundation
@testable import MeetingTranscriber
import XCTest

/// The "record without asking" setting. Its own file because `AppSettingsTests`
/// sits at the 600-line cap.
final class AppSettingsRecordWithoutAskingTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppSettingsRecordWithoutAskingTests.\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func testRecordWithoutAskingIsEmptyByDefaultAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.recordWithoutAskingApps, [], "every app asks first by default")
        settings.recordWithoutAskingApps = ["Microsoft Teams", "WeChat"]
        XCTAssertEqual(AppSettings(defaults: defaults).recordWithoutAskingApps, ["Microsoft Teams", "WeChat"])
    }

    /// Drives the Settings warning that the consent prompt cannot be seen: it
    /// matters exactly when some watched app still asks.
    func testAnyWatchedAppAsksFirst() throws {
        let settings = try AppSettings(defaults: makeDefaults())
        XCTAssertTrue(settings.anyWatchedAppAsksFirst, "Teams, Zoom and Webex are watched and ask by default")

        settings.recordWithoutAskingApps = ["Microsoft Teams", "Zoom", "Webex"]
        XCTAssertFalse(settings.anyWatchedAppAsksFirst, "every watched app records without asking")

        settings.watchWeChat = true
        XCTAssertTrue(settings.anyWatchedAppAsksFirst, "a newly watched app asks")
        settings.watchWeChat = false

        settings.watchBrowserMeetings = true
        XCTAssertTrue(settings.anyWatchedAppAsksFirst, "browser meetings always ask")

        settings.watchBrowserMeetings = false
        settings.watchTeams = false
        settings.watchZoom = false
        settings.watchWebex = false
        settings.recordWithoutAskingApps = []
        XCTAssertFalse(settings.anyWatchedAppAsksFirst, "nothing watched, nothing asks")
    }

    /// An app on the deny list is never asked, so it needs no visible prompt.
    func testADeniedAppDoesNotCountAsAsking() throws {
        let settings = try AppSettings(defaults: makeDefaults())
        settings.watchZoom = false
        settings.watchWebex = false
        settings.consentDeniedApps = ["Microsoft Teams"]
        XCTAssertFalse(settings.anyWatchedAppAsksFirst, "the only watched app is denied")

        // A browser denial names one browser; every other one still asks.
        settings.watchBrowserMeetings = true
        settings.consentDeniedApps = ["Microsoft Teams", "Google Chrome"]
        XCTAssertTrue(settings.anyWatchedAppAsksFirst)
    }
}
