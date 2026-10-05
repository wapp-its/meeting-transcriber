@testable import MeetingTranscriber
import XCTest

final class AppMeetingPatternTests: XCTestCase {
    // MARK: - forAppName Lookup

    func testForAppNameReturnsTeams() {
        let pattern = AppMeetingPattern.forAppName("Microsoft Teams")
        XCTAssertEqual(pattern?.appName, "Microsoft Teams")
    }

    func testForAppNameCaseInsensitive() {
        let pattern = AppMeetingPattern.forAppName("microsoft teams")
        XCTAssertEqual(pattern?.appName, "Microsoft Teams")
    }

    func testForAppNameReturnsNilForUnknown() {
        XCTAssertNil(AppMeetingPattern.forAppName("Unknown App"))
    }

    // MARK: - All Patterns

    func testAllPatternsCount() {
        XCTAssertEqual(AppMeetingPattern.all.count, 9)
    }

    // MARK: - Browser meetings category (issue #503)

    func testBrowserCategoryIsNotReachableByABrowserName() {
        // This used to assert that "Google Chrome" resolved to the browser
        // pattern. It deliberately no longer does: the category is keyed by a
        // token no process carries, so a real Chrome hit cannot resolve back to
        // a family-wide pattern and pick up another fork's owner names.
        XCTAssertNil(AppMeetingPattern.forAppName("Google Chrome"))
        XCTAssertEqual(
            AppMeetingPattern.forAppName("Browser Meetings")?.appName,
            AppMeetingPattern.browserMeetings.appName,
        )
    }

    func testBrowserCategoryRequiresRecordingConsent() {
        XCTAssertTrue(AppMeetingPattern.browserMeetings.requiresRecordingConsent)
    }

    func testNativePatternsDoNotRequireRecordingConsent() {
        // The flag means "always asks, whatever the settings say". Native
        // desktop meeting apps leave it off: whether they ask is the user's
        // per-app "record without asking" choice (see below).
        XCTAssertFalse(AppMeetingPattern.teams.requiresRecordingConsent)
        XCTAssertFalse(AppMeetingPattern.zoom.requiresRecordingConsent)
        XCTAssertFalse(AppMeetingPattern.webex.requiresRecordingConsent)
        XCTAssertFalse(AppMeetingPattern.simulator.requiresRecordingConsent)
    }

    // MARK: - Ask before recording

    func testWhoAsksBeforeRecording() throws {
        let category = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns.first { $0.appName == AppMeetingPattern.browserMeetings.appName },
        )
        let chrome = PowerAssertionDetector.meetingIdentity(pattern: category, processName: "Google Chrome")
        let unknown = AppMeetingPattern(appName: "Slack", ownerNames: ["Slack"], meetingPatterns: [])
        let everyName = AppMeetingPattern.recordWithoutAskingCandidates.map(\.appName)
            + ["Google Chrome", AppMeetingPattern.browserMeetings.appName, "Slack"]

        let cases: [(String, AppMeetingPattern, [String], Bool)] = [
            // Every watchable app asks by default, and stops asking once listed.
            ("Teams by default", .teams, [], true),
            ("Teams listed", .teams, ["Microsoft Teams"], false),
            ("Zoom with only Teams listed", .zoom, ["Microsoft Teams"], true),
            ("WeChat listed", .wechat, ["WeChat"], false),
            // Browser meetings always ask, whatever is stored.
            ("browser identity with everything listed", chrome, everyName, true),
            ("browser category with everything listed", .browserMeetings, everyName, true),
            // A name that matches no app with a switch is ignored.
            ("an app without a switch, listed", unknown, everyName, true),
            // The end-to-end fixture never asks.
            ("simulator", .simulator, [], false),
        ]
        for (label, pattern, listed, asks) in cases {
            XCTAssertEqual(pattern.asksBeforeRecording(recordWithoutAsking: listed), asks, label)
        }
        // Every app with a switch can be listed: none falls through to "asks".
        for pattern in AppMeetingPattern.recordWithoutAskingCandidates {
            XCTAssertFalse(pattern.asksBeforeRecording(recordWithoutAsking: [pattern.appName]), pattern.appName)
        }
    }

    // MARK: - Simulator Pattern

    func testSimulatorPattern() {
        let sim = AppMeetingPattern.simulator
        XCTAssertEqual(sim.appName, "MeetingSimulator")
        XCTAssertEqual(sim.minWindowWidth, 100)
        XCTAssertEqual(sim.minWindowHeight, 100)
    }

    // MARK: - Teams Pattern

    func testTeamsHasMeetingPatterns() {
        XCTAssertFalse(AppMeetingPattern.teams.meetingPatterns.isEmpty)
    }

    func testTeamsHasIdlePatterns() {
        XCTAssertFalse(AppMeetingPattern.teams.idlePatterns.isEmpty)
    }

    func testDefaultMinWindowDimensions() {
        XCTAssertEqual(AppMeetingPattern.teams.minWindowWidth, 200)
        XCTAssertEqual(AppMeetingPattern.teams.minWindowHeight, 200)
    }

    // MARK: - Zoom Pattern

    func testZoomOwnerNames() {
        XCTAssertTrue(AppMeetingPattern.zoom.ownerNames.contains("zoom.us"))
    }

    // MARK: - Webex Pattern

    func testWebexOwnerNames() {
        XCTAssertTrue(AppMeetingPattern.webex.ownerNames.contains("Webex"))
    }
}
