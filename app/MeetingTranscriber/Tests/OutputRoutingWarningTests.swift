@testable import MeetingTranscriber
import XCTest

/// The routing decision and its strings. What feeds it, and when, is
/// `OutputDeviceControllerTests`.
final class OutputRoutingWarningTests: XCTestCase {
    private typealias Decision = OutputRoutingWarning.Decision
    private let teams = OutputRoutingWarning.teamsLoopbackUID

    func testTheTeamsDeviceWarnsARecordingWithAnAppTrackOnceForTheRouting() {
        let first = OutputRoutingWarning.decide(uid: teams, capturesApp: true, warnedForCurrentRouting: false)
        let again = OutputRoutingWarning.decide(uid: teams, capturesApp: true, warnedForCurrentRouting: true)

        XCTAssertEqual(first, Decision(warn: true, warnedForCurrentRouting: true))
        XCTAssertEqual(again, Decision(warn: false, warnedForCurrentRouting: true))
    }

    /// Other virtual outputs record fine, so nothing but the exact Teams UID
    /// counts, and leaving the Teams device ends the routing it warned for.
    func testAnyOtherOutputNeverWarnsAndEndsTheRouting() {
        for uid in ["BuiltInSpeakerDevice", "BlackHole2ch_UID", "msloopbackdriverdevice_uid", "\(teams)2"] {
            let decision = OutputRoutingWarning.decide(uid: uid, capturesApp: true, warnedForCurrentRouting: true)
            XCTAssertEqual(decision, Decision(warn: false, warnedForCurrentRouting: false), uid)
        }
    }

    /// An unreadable output proves nothing: no warning, and a routing already
    /// warned for is not forgotten, or the next reading would warn again.
    func testAnUnreadableOutputNeitherWarnsNorForgets() {
        XCTAssertEqual(
            OutputRoutingWarning.decide(uid: nil, capturesApp: true, warnedForCurrentRouting: true),
            Decision(warn: false, warnedForCurrentRouting: true),
        )
        XCTAssertEqual(
            OutputRoutingWarning.decide(uid: nil, capturesApp: true, warnedForCurrentRouting: false),
            Decision(warn: false, warnedForCurrentRouting: false),
        )
    }

    func testARecordingWithoutAnAppTrackIsNeverWarned() {
        let decision = OutputRoutingWarning.decide(uid: teams, capturesApp: false, warnedForCurrentRouting: false)

        XCTAssertEqual(decision, Decision(warn: false, warnedForCurrentRouting: false))
    }

    func testTheNotificationNamesTheDeviceAndWhereToFixIt() {
        let body = OutputRoutingWarning.notificationBody(deviceName: "Microsoft Teams Audio")

        XCTAssertEqual(OutputRoutingWarning.notificationTitle, "Meeting Audio May Not Be Recorded")
        XCTAssertTrue(body.hasPrefix("Microsoft Teams Audio is your Mac's sound output"), body)
        XCTAssertTrue(body.contains("may not reach the recording"), body)
        XCTAssertTrue(body.contains("under Output in the menu bar menu, or in Control Center"), body)
    }

    func testTheNotificationFallsBackToTheTeamsNameWhenCoreAudioGivesNone() {
        let body = OutputRoutingWarning.notificationBody(deviceName: nil)

        XCTAssertTrue(body.hasPrefix("Microsoft Teams Audio is your Mac's sound output"), body)
    }

    func testTheLogLineNamesTheTriggerAndTheUID() {
        XCTAssertEqual(
            OutputRoutingWarning.logLine(trigger: .start, uid: teams),
            "Output routing: default output is MSLoopbackDriverDevice_UID at start; the app track may record silence; warned the user",
        )
        XCTAssertEqual(
            OutputRoutingWarning.logLine(trigger: .outputChange, uid: teams),
            "Output routing: default output is MSLoopbackDriverDevice_UID at output change; the app track may record silence; warned the user",
        )
    }
}
