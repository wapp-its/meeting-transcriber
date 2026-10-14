@testable import MeetingTranscriber
import XCTest

/// The identity key: an app added through "Add App…" is keyed by its bundle
/// ID, every built-in app and browser identity by its name, unchanged.
final class AddedAppIdentityTests: XCTestCase {
    func testKeyFormatAndRoundTrip() {
        let key = AddedAppIdentity.key(bundleID: "com.example.zoom")
        XCTAssertEqual(key, "custom:com.example.zoom")
        XCTAssertEqual(AddedAppIdentity.bundleID(fromKey: key), "com.example.zoom")
    }

    func testANameIsNotAnAddedAppKey() {
        for name in ["Zoom", "", "Google Chrome"] {
            XCTAssertNil(AddedAppIdentity.bundleID(fromKey: name), name)
        }
    }

    func testBuiltInAndBrowserIdentitiesAreKeyedByTheirName() throws {
        for pattern in AppMeetingPattern.all {
            XCTAssertEqual(pattern.identityKey, pattern.appName, pattern.appName)
        }
        let browser = try PowerAssertionDetector.meetingIdentity(
            pattern: PowerAssertionFixture.browserPattern(), processName: "Google Chrome",
        )
        XCTAssertEqual(browser.identityKey, "Google Chrome")
    }

    func testAnAddedAppIsKeyedByItsBundleIDAndShowsItsName() {
        let pattern = MicInputDetector.MicPattern(
            appName: "Zoom", bundleIDs: ["com.example.zoom"], matchesHelpers: true, usesBuiltInMeetingPattern: false,
        ).meetingPattern
        XCTAssertEqual(pattern.identityKey, "custom:com.example.zoom")
        XCTAssertEqual(pattern.appName, "Zoom")
    }
}
