@testable import MeetingTranscriber
import XCTest

/// `makeAssertionDict` is shared from PowerAssertionDetectorTests (internal);
/// the mic snapshot helper is file-private there, so keep a local one.
private func micSnapshot(_ bundleID: String) -> MicInputDetector.AudioProcessSnapshot {
    MicInputDetector.AudioProcessSnapshot(bundleID: bundleID, pid: 4321, isRunningInput: true)
}

final class CompositeMeetingDetectorTests: XCTestCase {
    private func micDetector(bundleID: String = "com.tencent.xinWeChat") -> MicInputDetector {
        let detector = MicInputDetector(confirmationCount: 1)
        detector.windowListProvider = { [] }
        detector.processProvider = { [micSnapshot(bundleID)] }
        return detector
    }

    private func assertionDetector(active: Bool) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            active
                ? makeAssertionDict(pid: 55, processName: "MSTeams", assertName: "Microsoft Teams Call in progress")
                : [:]
        }
        return detector
    }

    func testFirstHitWins() {
        let composite = CompositeMeetingDetector([assertionDetector(active: true), micDetector()])
        XCTAssertEqual(composite.checkOnce()?.pattern.appName, "Microsoft Teams")
    }

    func testFallsThroughToLaterDetector() {
        let composite = CompositeMeetingDetector([assertionDetector(active: false), micDetector()])
        XCTAssertEqual(composite.checkOnce()?.pattern.appName, "WeChat")
    }

    func testNoStrategySeesAnythingReturnsNil() {
        let mic = MicInputDetector(confirmationCount: 1)
        mic.windowListProvider = { [] }
        mic.processProvider = { [] }
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        XCTAssertNil(composite.checkOnce())
    }

    func testResetReachesEveryStrategy() throws {
        // Observable proof that the fan-out happens: after a reset naming the
        // app, the mic strategy's cooldown suppresses the very same process
        // snapshot that fired a moment earlier.
        let mic = micDetector()
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        let meeting = try XCTUnwrap(composite.checkOnce())

        composite.reset(appName: meeting.pattern.appName)
        XCTAssertNil(composite.checkOnce(), "the reset must have reached the mic strategy's cooldown")
    }

    func testLivenessIsPerStrategyOr() throws {
        let mic = micDetector()
        let composite = CompositeMeetingDetector([assertionDetector(active: false), mic])
        let meeting = try XCTUnwrap(composite.checkOnce())
        XCTAssertTrue(composite.isMeetingActive(meeting))
        mic.processProvider = { [] }
        XCTAssertFalse(composite.isMeetingActive(meeting))
    }

    /// An app added under the name "Zoom" next to the built-in Zoom: once the
    /// added app has released the microphone, the built-in's call assertion
    /// must not keep its recording running.
    func testABuiltInCallDoesNotKeepASameNamedAddedAppsMeetingActive() throws {
        let assertions = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Zoom"]), confirmationCount: 1,
        )
        assertions.windowListProvider = { [] }
        assertions.assertionProvider = { [:] }
        let mic = MicInputDetector(
            patterns: [
                MicInputDetector.MicPattern(
                    appName: "Zoom", bundleIDs: ["com.example.zoom"], matchesHelpers: true, usesBuiltInMeetingPattern: false,
                ),
            ],
            confirmationCount: 1,
        )
        mic.windowListProvider = { [] }
        mic.mainAppPIDProvider = { _ in nil }
        mic.processProvider = { [micSnapshot("com.example.zoom")] }
        let composite = CompositeMeetingDetector([assertions, mic])
        let added = try XCTUnwrap(composite.checkOnce())
        XCTAssertEqual(added.pattern.identityKey, "custom:com.example.zoom", "precondition: the added app's meeting")

        mic.processProvider = { [] }
        assertions.assertionProvider = { PowerAssertionFixture.assertions((3, "zoom.us", "Zoom call")) }
        XCTAssertFalse(composite.isMeetingActive(added), "the built-in Zoom's call must not keep the added app's meeting active")

        // Control: the built-in's own meeting is active under that assertion.
        let builtIn = try XCTUnwrap(composite.checkOnce())
        XCTAssertEqual(builtIn.pattern, .zoom)
        XCTAssertTrue(composite.isMeetingActive(builtIn))
    }
}
