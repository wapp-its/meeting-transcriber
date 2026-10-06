@testable import MeetingTranscriber
import XCTest

/// An app added through "Add App…" goes through the same consent gate as the
/// built-in apps: it asks before every recording, and "Never for this app"
/// keeps it from being detected at all.
final class CustomWatchedAppConsentTests: XCTestCase {
    private func customPattern(appName: String, bundleID: String) -> MicInputDetector.MicPattern {
        MicInputDetector.MicPattern(
            appName: appName, bundleIDs: [bundleID], matchesHelpers: true, usesBuiltInMeetingPattern: false,
        )
    }

    func testCustomAppAsksBeforeRecording() {
        let pattern = customPattern(appName: "CallApp", bundleID: "com.example.callapp").meetingPattern
        XCTAssertTrue(pattern.asksBeforeRecording(recordWithoutAsking: []))
    }

    /// "Add App…" refuses an app whose bundle ID or executable matches a
    /// built-in, but not one whose name does, and the "record without
    /// asking" switches are keyed by name. Switching Zoom to record without
    /// asking must not switch off the prompt for another app called "Zoom".
    func testCustomAppNamedLikeABuiltInStillAsksWhenTheBuiltInRecordsWithoutAsking() {
        let pattern = customPattern(appName: "Zoom", bundleID: "com.example.zoom").meetingPattern
        XCTAssertTrue(pattern.asksBeforeRecording(recordWithoutAsking: ["Zoom"]))
    }

    /// The meeting simulator records at once because the end-to-end lanes
    /// have nobody to answer; an added app that shares its name must not.
    func testCustomAppNamedLikeTheSimulatorStillAsks() {
        let name = AppMeetingPattern.simulator.appName
        let pattern = customPattern(appName: name, bundleID: "com.example.sim").meetingPattern
        XCTAssertTrue(pattern.asksBeforeRecording(recordWithoutAsking: []))
        XCTAssertFalse(AppMeetingPattern.simulator.asksBeforeRecording(recordWithoutAsking: []))
    }

    func testTheBuiltInAppStillRecordsWithoutAskingWhenSwitchedSo() throws {
        let zoom = try XCTUnwrap(AppMeetingPattern.forAppName("Zoom"))
        XCTAssertFalse(zoom.asksBeforeRecording(recordWithoutAsking: ["Zoom"]))
        XCTAssertTrue(zoom.asksBeforeRecording(recordWithoutAsking: []))
    }

    func testDeniedCustomAppIsNotDetected() {
        let detector = MicInputDetector(
            patterns: [customPattern(appName: "CallApp", bundleID: "com.example.callapp")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in nil }
        detector.processProvider = {
            [MicInputDetector.AudioProcessSnapshot(bundleID: "com.example.callapp.helper", pid: 555, isRunningInput: true)]
        }
        detector.isIdentityDenied = { $0 == "CallApp" }

        XCTAssertNil(detector.checkOnce())

        detector.isIdentityDenied = { _ in false }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "CallApp")
    }
}
