@testable import MeetingTranscriber
import XCTest

private let webRTC = PowerAssertionFixture.webRTC

/// PID 7 is the added app, PID 9 its helper, PID 11 an app whose bundle ID
/// only shares the added one's text without being its helper, PID 8 a
/// browser; anything else does not resolve.
private let bundleIDs: [pid_t: String] = [
    7: "com.example.slack",
    8: "com.brave.Browser",
    9: "com.example.slack.helper",
    11: "com.example.slacker",
]

/// An app added through "Add App…" is watched through the microphone and keyed
/// by its bundle ID there, so the browser-meeting path must leave its process
/// alone: otherwise one call in an added Electron app would be detected twice,
/// under two identities, and answering one prompt would leave the other.
final class PowerAssertionDetectorAddedAppTests: XCTestCase {
    private func addedSlackDetector() -> PowerAssertionDetector {
        let detector = PowerAssertionFixture.browserDetector()
        detector.addedAppBundleIDs = ["com.example.slack"]
        detector.bundleIDForPID = { bundleIDs[$0] }
        return detector
    }

    /// Every identity one poll state would report, found by excluding each
    /// one already reported until nothing is left.
    private func detectedIdentities(_ detector: PowerAssertionDetector) -> Set<String> {
        var found: Set<String> = []
        while let meeting = detector.checkOnce(excluding: found) {
            guard found.insert(meeting.pattern.identityKey).inserted else { break }
        }
        return found
    }

    func testAnAddedAppAndItsHelperAreNeverBrowserMeetings() {
        let detector = addedSlackDetector()
        detector.assertionProvider = {
            PowerAssertionFixture.assertions(
                (7, "Slack", webRTC),
                (8, "Brave Browser", webRTC),
                (9, "Slack Helper", webRTC),
                (10, PowerAssertionFixture.unknownBrowser, webRTC),
                (11, "Slacker", webRTC),
            )
        }

        XCTAssertEqual(
            detectedIdentities(detector),
            ["Brave Browser", PowerAssertionFixture.unknownBrowser, "Slacker"],
            "the added app and its helper are left to the microphone path; a browser, an unresolvable process and a bundle ID that is not a helper are not",
        )
    }

    func testWithNoAddedAppsTheBrowserPathIsUnchangedAndLooksNothingUp() throws {
        let detector = PowerAssertionFixture.browserDetector()
        var lookups = 0
        detector.bundleIDForPID = { pid in
            lookups += 1
            return bundleIDs[pid]
        }
        detector.assertionProvider = { PowerAssertionFixture.assertions((7, "Slack", webRTC)) }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Slack")
        XCTAssertTrue(detector.isMeetingActive(meeting))
        XCTAssertEqual(lookups, 0, "a default install must pay nothing for the exclusion")
    }

    func testAnAddedAppDoesNotKeepABrowserMeetingOfItsNameActive() throws {
        let detector = addedSlackDetector()
        detector.assertionProvider = { PowerAssertionFixture.assertions((7, "Slack", webRTC)) }
        let meeting = try DetectedMeeting(
            pattern: PowerAssertionDetector.meetingIdentity(
                pattern: PowerAssertionFixture.browserPattern(), processName: "Slack",
            ),
            windowTitle: "Slack Call",
            ownerName: "Slack",
            windowPID: 7,
        )

        XCTAssertFalse(detector.isMeetingActive(meeting), "an added app's assertion must not keep a browser meeting alive")

        detector.addedAppBundleIDs = []
        XCTAssertTrue(detector.isMeetingActive(meeting), "removing the app from the list gives today's behaviour back")
    }

    func testNativeAppsAreDetectedEvenWhenTheirBundleIDIsAdded() {
        // The exclusion is the browser path's alone: a native pattern names its
        // processes, so an added bundle ID must not take a Zoom call away from it.
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Zoom", AppMeetingPattern.browserMeetings.appName]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.addedAppBundleIDs = ["us.zoom.xos"]
        detector.bundleIDForPID = { _ in "us.zoom.xos" }
        detector.assertionProvider = { PowerAssertionFixture.assertions((5, "zoom.us", "Zoom call")) }

        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Zoom")
    }

    @MainActor
    func testDefaultDetectorPassesTheAddedAppsToTheBrowserPath() throws {
        func detector(customApps: [String]) throws -> PowerAssertionDetector {
            let suite = "AddedAppBrowserWiring-\(getpid())-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            let settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
            settings.watchBrowserMeetings = true
            settings.watchCustomApps = customApps
            let assertions = try XCTUnwrap(
                WatchingController.defaultDetectors(settings: settings)
                    .compactMap { $0 as? PowerAssertionDetector }.first,
            )
            assertions.windowListProvider = { [] }
            assertions.bundleIDForPID = { bundleIDs[$0] }
            assertions.assertionProvider = { PowerAssertionFixture.assertions((7, "Slack", webRTC)) }
            return assertions
        }

        // The default confirmation count is 2, so each detector polls twice.
        let added = try detector(customApps: ["com.example.slack"])
        _ = added.checkOnce()
        XCTAssertNil(added.checkOnce(), "an added app's process is not a browser meeting")

        let notAdded = try detector(customApps: [])
        _ = notAdded.checkOnce()
        XCTAssertEqual(notAdded.checkOnce()?.pattern.appName, "Slack", "without the entry it is one, as today")
    }
}
