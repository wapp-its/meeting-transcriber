@testable import MeetingTranscriber
import XCTest

/// The calls answered "Ignore" that "Record (<App>)" may be offered for. Pure
/// value logic: the caller decides what "ended" and "active" mean, so these
/// tests pass the checks in directly.
final class IgnoredCallsTests: XCTestCase {
    private func meeting(_ pattern: AppMeetingPattern, title: String = "Call") -> DetectedMeeting {
        DetectedMeeting(pattern: pattern, windowTitle: "\(pattern.appName) \(title)", ownerName: pattern.appName, windowPID: 4321)
    }

    func testAnIgnoredCallIsKeptPerAppAndALaterOneReplacesItsEntry() {
        var calls = IgnoredCalls()
        let first = meeting(.teams, title: "Standup")
        let later = meeting(.teams, title: "Retro")

        calls.remember(first)
        calls.remember(meeting(.zoom))
        XCTAssertEqual(calls.ignoredApps, ["Microsoft Teams", "Zoom"])

        calls.remember(later)
        XCTAssertEqual(calls.ignoredApps, ["Microsoft Teams", "Zoom"], "one entry per app")
        XCTAssertEqual(calls.ignoredMeetings.map(\.windowTitle), ["Microsoft Teams Retro", "Zoom Call"], "the newer meeting, sorted by app")
    }

    func testReleaseRemovesAndReturnsOnlyTheAppsWhoseMeetingEnded() {
        var calls = IgnoredCalls()
        for pattern in [AppMeetingPattern.webex, .teams, .zoom] {
            calls.remember(meeting(pattern))
        }

        let released = calls.release { $0.pattern.appName != "Zoom" }

        XCTAssertEqual(released, ["Microsoft Teams", "Webex"], "sorted")
        XCTAssertEqual(calls.ignoredApps, ["Zoom"], "the call still running stays")
        XCTAssertTrue(calls.release { _ in false }.isEmpty, "nothing ended, nothing released")
        XCTAssertEqual(calls.ignoredApps, ["Zoom"])
    }

    func testLiftHandsBackTheMeetingOnlyWhileItIsActive() {
        var calls = IgnoredCalls()
        let teams = meeting(.teams)
        calls.remember(teams)
        calls.remember(meeting(.zoom))

        XCTAssertNil(calls.lift("Microsoft Teams") { _ in false }, "the call ended")
        XCTAssertEqual(calls.ignoredApps, ["Microsoft Teams", "Zoom"], "nothing changes then")
        XCTAssertNil(calls.lift("Webex") { _ in true }, "an app without an entry")

        XCTAssertEqual(calls.lift("Microsoft Teams") { $0 == teams }, teams)
        XCTAssertEqual(calls.ignoredApps, ["Zoom"], "only its own entry is lifted")
        XCTAssertNil(calls.lift("Microsoft Teams") { _ in true }, "lifted once")
    }

    func testForgetRemovesOneAppAndRemoveAllEveryApp() {
        var calls = IgnoredCalls()
        calls.remember(meeting(.teams))
        calls.remember(meeting(.zoom))

        calls.forget("Microsoft Teams")
        XCTAssertEqual(calls.ignoredApps, ["Zoom"])
        calls.forget("Webex")
        XCTAssertEqual(calls.ignoredApps, ["Zoom"], "an app without an entry changes nothing")

        calls.remember(meeting(.webex))
        calls.removeAll()
        XCTAssertTrue(calls.ignoredApps.isEmpty)
        XCTAssertTrue(calls.ignoredMeetings.isEmpty)
    }

    func testAnAddedAppIsKeptUnderItsKeyBesideASameNamedBuiltIn() {
        var calls = IgnoredCalls()
        let added = meeting(MicInputDetector.MicPattern(
            appName: "Zoom", bundleIDs: ["com.example.zoom"], matchesHelpers: true, usesBuiltInMeetingPattern: false,
        ).meetingPattern)
        let builtIn = meeting(.zoom)

        calls.remember(added)
        calls.remember(builtIn)
        XCTAssertEqual(calls.ignoredApps, ["custom:com.example.zoom", "Zoom"])

        XCTAssertEqual(calls.release { $0 == added }, ["custom:com.example.zoom"])
        XCTAssertEqual(calls.ignoredApps, ["Zoom"])
    }
}

extension IgnoredCalls {
    /// The apps with an entry, for the assertions here and in the loop tests.
    var ignoredApps: Set<String> {
        Set(ignoredMeetings.map(\.pattern.identityKey))
    }
}
