@testable import MeetingTranscriber
import XCTest

/// `checkOnce(excluding:)`: while one app's consent prompt is open, a poll must
/// still find another app's call. A poll returns one meeting, so a detector
/// that kept returning the app being asked about would hide every other call
/// behind it for as long as the prompt stays open.
final class MeetingDetectorExclusionTests: XCTestCase {
    private func assertionDetector(confirmationCount: Int = 1) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Microsoft Teams", "Zoom"]),
            confirmationCount: confirmationCount,
        )
        detector.windowListProvider = { [] }
        return detector
    }

    private func micDetector() -> MicInputDetector {
        let detector = MicInputDetector(confirmationCount: 1)
        detector.windowListProvider = { [] }
        detector.processProvider = {
            [
                MicInputDetector.AudioProcessSnapshot(bundleID: "com.tencent.xinWeChat", pid: 11, isRunningInput: true),
                MicInputDetector.AudioProcessSnapshot(bundleID: "net.whatsapp.WhatsApp", pid: 12, isRunningInput: true),
            ]
        }
        return detector
    }

    /// Both orders, so the result cannot come from dictionary order alone.
    func testAssertionDetectorPassesOverTheExcludedApp() {
        let detector = assertionDetector()
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((1, "MSTeams", "call in progress"), (2, "zoom.us", "Zoom call"))
        }
        XCTAssertEqual(detector.checkOnce(excluding: "Microsoft Teams")?.pattern.appName, "Zoom")
        XCTAssertEqual(detector.checkOnce(excluding: "Zoom")?.pattern.appName, "Microsoft Teams")
    }

    /// The excluded app keeps counting, so it is back as soon as its question
    /// is settled rather than starting its confirmation over.
    func testTheExcludedAppKeepsCounting() {
        let detector = assertionDetector(confirmationCount: 3)
        detector.assertionProvider = { PowerAssertionFixture.assertions((1, "MSTeams", "call in progress")) }
        XCTAssertNil(detector.checkOnce(excluding: "Microsoft Teams"))
        XCTAssertNil(detector.checkOnce(excluding: "Microsoft Teams"))
        XCTAssertEqual(detector.checkOnce(excluding: nil)?.pattern.appName, "Microsoft Teams")
    }

    func testMicInputDetectorPassesOverTheExcludedApp() {
        let detector = micDetector()
        XCTAssertEqual(detector.checkOnce(excluding: "WeChat")?.pattern.appName, "WhatsApp")
        XCTAssertEqual(detector.checkOnce(excluding: "WhatsApp")?.pattern.appName, "WeChat")
    }

    /// A mic-input app can now be answered "Never for this app" too. Like the
    /// assertion detector, a denied app must never confirm: re-confirming it
    /// every few polls would reset every other app's count at the gate.
    func testMicInputDetectorNeverConfirmsADeniedApp() {
        let detector = micDetector()
        detector.isIdentityDenied = { $0 == "WeChat" }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "WhatsApp")
        XCTAssertNil(detector.checkOnce(excluding: "WhatsApp"), "WeChat must not confirm while denied")
    }

    /// The first strategy's excluded meeting must not stop the second
    /// strategy from being polled at all.
    func testCompositeAsksTheNextStrategyPastAnExcludedMeeting() {
        let teams = DetectedMeeting(pattern: .teams, windowTitle: "Call", ownerName: "MSTeams", windowPID: 1)
        let weChat = DetectedMeeting(pattern: .wechat, windowTitle: "Call", ownerName: "WeChat", windowPID: 2)
        let composite = CompositeMeetingDetector([FixedMeetingDetector(teams), FixedMeetingDetector(weChat)])
        XCTAssertEqual(composite.checkOnce(excluding: "Microsoft Teams"), weChat)
        XCTAssertEqual(composite.checkOnce(excluding: nil), teams)
    }

    /// The production wiring hands the persisted deny list to both strategies.
    @MainActor
    func testDefaultDetectorsHonourTheDenyListForMicInputApps() throws {
        let suiteName = "MeetingDetectorExclusionTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.watchWeChat = true
        settings.consentDeniedApps = ["WeChat"]
        let mic = try XCTUnwrap(
            WatchingController.defaultDetectors(settings: settings).compactMap { $0 as? MicInputDetector }.first,
        )
        XCTAssertTrue(mic.isIdentityDenied("WeChat"))
        settings.consentDeniedApps = []
        XCTAssertFalse(mic.isIdentityDenied("WeChat"), "read live, so a Settings Remove applies at once")
    }
}
