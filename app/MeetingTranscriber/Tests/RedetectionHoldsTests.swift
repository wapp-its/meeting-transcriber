@testable import MeetingTranscriber
import XCTest

/// The per-app holds that keep a stopped meeting's app out of detection until
/// its call signal has gone once. Pure value logic: the caller decides what
/// "ended" means, so these tests pass the check in directly.
final class RedetectionHoldsTests: XCTestCase {
    private func meeting(_ pattern: AppMeetingPattern) -> DetectedMeeting {
        DetectedMeeting(pattern: pattern, windowTitle: "\(pattern.appName) Call", ownerName: pattern.appName, windowPID: 4321)
    }

    func testAHoldIsReportedNewOnce() {
        var holds = RedetectionHolds()

        XCTAssertTrue(holds.hold(meeting(.teams)))
        XCTAssertFalse(holds.hold(meeting(.teams)), "a repeat is not a new hold")
        XCTAssertEqual(holds.heldApps, ["Microsoft Teams"], "and keeps one entry")
    }

    func testTwoAppsAreHeldIndependently() {
        var holds = RedetectionHolds()

        XCTAssertTrue(holds.hold(meeting(.teams)))
        XCTAssertTrue(holds.hold(meeting(.zoom)), "another app's hold is new")
        XCTAssertEqual(holds.heldApps, ["Microsoft Teams", "Zoom"])
    }

    func testReleaseRemovesAndReturnsOnlyTheAppsWhoseMeetingEnded() {
        var holds = RedetectionHolds()
        for pattern in [AppMeetingPattern.webex, .teams, .zoom] {
            _ = holds.hold(meeting(pattern))
        }

        let released = holds.release { $0.pattern.appName != "Zoom" }

        XCTAssertEqual(released, ["Microsoft Teams", "Webex"], "sorted")
        XCTAssertEqual(holds.heldApps, ["Zoom"], "the meeting still running stays held")
        XCTAssertTrue(holds.release { _ in false }.isEmpty, "nothing ended, nothing released")
        XCTAssertEqual(holds.heldApps, ["Zoom"])
    }

    func testRemoveAllEmptiesIt() {
        var holds = RedetectionHolds()
        _ = holds.hold(meeting(.teams))
        _ = holds.hold(meeting(.zoom))

        holds.removeAll()

        XCTAssertEqual(holds, RedetectionHolds())
        XCTAssertTrue(holds.heldApps.isEmpty)
    }
}
