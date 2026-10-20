@testable import MeetingTranscriber
import XCTest

/// `signallingMeetings()`: every meeting whose call signal is present now,
/// listed the way detection would report it, without confirmation and without
/// touching the detector's confirmation counts or cooldowns.
final class SignallingMeetingsTests: XCTestCase {
    /// Lists a fixed set of meetings and detects nothing, for the composite.
    private final class ListedDetector: MeetingDetecting {
        private let listed: [DetectedMeeting]

        init(_ listed: [DetectedMeeting]) {
            self.listed = listed
        }

        func checkOnce() -> DetectedMeeting? {
            nil
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            false
        }

        func signallingMeetings() -> [DetectedMeeting] {
            listed
        }

        func reset(appName _: String?) {}
    }

    private static let teamsCall = "Microsoft Teams Call in progress"

    private func assertionDetector(
        _ assertions: [Int32: [[String: Any]]],
        confirmationCount: Int = 2,
    ) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Microsoft Teams", AppMeetingPattern.browserMeetings.appName]),
            confirmationCount: confirmationCount,
        )
        detector.windowListProvider = { [] }
        detector.assertionProvider = { assertions }
        return detector
    }

    private func micSnapshot(_ bundleID: String, pid: pid_t, running: Bool = true) -> MicInputDetector.AudioProcessSnapshot {
        MicInputDetector.AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: running)
    }

    // MARK: - Power assertions

    /// Listed on the very first call, before any poll could have confirmed
    /// them, and each exactly as a confirmed detection of that identity
    /// reports it: two browsers are two meetings.
    func testListsEveryMatchingIdentityOnTheFirstCallAsDetectionReportsIt() throws {
        let assertions = PowerAssertionFixture.assertions(
            (55, "MSTeams", Self.teamsCall),
            (7, "Brave Browser", PowerAssertionFixture.webRTC),
            (8, "Microsoft Edge", PowerAssertionFixture.webRTC),
        )
        let listed = assertionDetector(assertions).signallingMeetings()

        let keys = listed.map(\.pattern.identityKey)
        XCTAssertEqual(Set(keys), ["Microsoft Teams", "Brave Browser", "Microsoft Edge"])
        XCTAssertEqual(keys.count, 3, "one entry per identity")
        for meeting in listed {
            let key = meeting.pattern.identityKey
            let confirmed = try XCTUnwrap(
                assertionDetector(assertions, confirmationCount: 1).checkOnce(excluding: Set(keys).subtracting([key])), key,
            )
            XCTAssertEqual(meeting.pattern, confirmed.pattern, key)
            XCTAssertEqual(meeting.windowPID, confirmed.windowPID, key)
            XCTAssertEqual(meeting.ownerName, confirmed.ownerName, key)
            XCTAssertEqual(meeting.windowTitle, confirmed.windowTitle, key)
        }

        let teamsTwice = assertionDetector(PowerAssertionFixture.assertions(
            (55, "MSTeams", Self.teamsCall),
            (56, "Microsoft Teams WebView", Self.teamsCall),
        ))
        XCTAssertEqual(
            teamsTwice.signallingMeetings().map(\.pattern.identityKey), ["Microsoft Teams"],
            "one app asserting from two processes is one meeting",
        )
    }

    /// Detection's own exclusions apply: a deny-listed identity, a native
    /// client's process under the browser pattern, and an added app's process,
    /// which the microphone path owns.
    func testExcludedProcessesAreNotListed() {
        let cases: [(label: String, processName: String, configure: (PowerAssertionDetector) -> Void)] = [
            ("deny-listed", "Brave Browser", { detector in detector.isIdentityDenied = { key in key == "Brave Browser" } }),
            ("native client", "MSTeams", { _ in }),
            ("added app", "Slack", { detector in
                detector.addedAppBundleIDs = ["com.example.slack"]
                detector.bundleIDForPID = { _ in "com.example.slack" }
            }),
        ]
        for testCase in cases {
            let detector = PowerAssertionFixture.browserDetector()
            detector.assertionProvider = {
                PowerAssertionFixture.assertionDict(processName: testCase.processName, assertName: PowerAssertionFixture.webRTC)
            }
            testCase.configure(detector)
            XCTAssertTrue(detector.signallingMeetings().isEmpty, testCase.label)
        }
    }

    /// Taking the list neither counts as a poll nor resets the count a poll
    /// made, and a meeting in cooldown is listed without its cooldown ending.
    func testTakingTheListLeavesConfirmationAndCooldownsAsTheyWere() {
        let detector = assertionDetector(PowerAssertionFixture.assertions((55, "MSTeams", Self.teamsCall)))

        XCTAssertEqual(detector.signallingMeetings().map(\.pattern.identityKey), ["Microsoft Teams"])
        XCTAssertNil(detector.checkOnce(), "the list did not count as the first poll")
        XCTAssertEqual(detector.signallingMeetings().count, 1)
        XCTAssertEqual(detector.checkOnce()?.pattern.identityKey, "Microsoft Teams", "nor reset the first poll's count")

        detector.reset(appName: "Microsoft Teams")
        XCTAssertEqual(
            detector.signallingMeetings().map(\.pattern.identityKey), ["Microsoft Teams"],
            "a meeting in cooldown is listed",
        )
        XCTAssertNil(detector.checkOnce())
        XCTAssertNil(detector.checkOnce(), "the cooldown still runs: two polls confirm nothing")
    }

    // MARK: - Microphone

    func testMicListsEachWatchedAppHoldingTheMicrophone() {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: ["WeChat", "WhatsApp", "FaceTime"]), confirmationCount: 2,
        )
        detector.windowListProvider = { [] }
        let processes = [
            micSnapshot("com.tencent.xinWeChat", pid: 777),
            micSnapshot("net.whatsapp.WhatsApp", pid: 778),
            micSnapshot("com.apple.FaceTime", pid: 779, running: false),
            micSnapshot("com.tencent.meeting", pid: 780),
        ]
        detector.processProvider = { processes }

        let listed = detector.signallingMeetings()
        XCTAssertEqual(Set(listed.map(\.pattern.identityKey)), ["WeChat", "WhatsApp"], "watched and holding the microphone")
        let weChat = listed.first { $0.pattern.identityKey == "WeChat" }
        XCTAssertEqual(weChat?.windowPID, 777)
        XCTAssertEqual(weChat?.ownerName, "WeChat")
        XCTAssertEqual(weChat?.windowTitle, "WeChat Call")

        detector.isIdentityDenied = { $0 == "WeChat" }
        XCTAssertEqual(detector.signallingMeetings().map(\.pattern.identityKey), ["WhatsApp"], "a deny-listed app is skipped")
    }

    func testMicWithNoWatchedAppsListsNothingWithoutEnumerating() {
        let detector = MicInputDetector(patterns: [], confirmationCount: 1)
        var providerCalls = 0
        detector.processProvider = {
            providerCalls += 1
            return [self.micSnapshot("com.tencent.xinWeChat", pid: 777)]
        }
        XCTAssertTrue(detector.signallingMeetings().isEmpty)
        XCTAssertEqual(providerCalls, 0)
    }

    // MARK: - Composite

    /// The union, each identity once and from the strategy asked first; two
    /// added apps sharing a display name are two identities.
    func testCompositeListsTheUnionOnceForEachIdentity() {
        func meeting(_ pattern: AppMeetingPattern, pid: pid_t) -> DetectedMeeting {
            DetectedMeeting(pattern: pattern, windowTitle: "Call", ownerName: pattern.appName, windowPID: pid)
        }
        func addedApp(_ bundleID: String) -> AppMeetingPattern {
            AppMeetingPattern(
                appName: "Meet", ownerNames: ["Meet"], meetingPatterns: [], requiresRecordingConsent: true,
                identityKey: AddedAppIdentity.key(bundleID: bundleID),
            )
        }
        let composite = CompositeMeetingDetector([
            ListedDetector([meeting(.teams, pid: 1), meeting(addedApp("com.acme.meet"), pid: 2)]),
            ListedDetector([meeting(.teams, pid: 3), meeting(addedApp("com.acme.meet.beta"), pid: 4), meeting(.zoom, pid: 5)]),
        ])

        let listed = composite.signallingMeetings()
        XCTAssertEqual(listed.map(\.windowPID), [1, 2, 4, 5])
        XCTAssertEqual(listed.map(\.pattern.identityKey), [
            "Microsoft Teams", AddedAppIdentity.key(bundleID: "com.acme.meet"),
            AddedAppIdentity.key(bundleID: "com.acme.meet.beta"), "Zoom",
        ])
    }
}
