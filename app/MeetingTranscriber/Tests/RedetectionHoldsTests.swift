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

    func testAnAddedAppIsHeldUnderItsKeyBesideASameNamedBuiltIn() {
        var holds = RedetectionHolds()
        let added = meeting(MicInputDetector.MicPattern(
            appName: "Zoom", bundleIDs: ["com.example.zoom"], matchesHelpers: true, usesBuiltInMeetingPattern: false,
        ).meetingPattern)
        let builtIn = meeting(.zoom)

        XCTAssertTrue(holds.hold(added))
        XCTAssertEqual(holds.heldApps, ["custom:com.example.zoom"])
        XCTAssertTrue(holds.hold(builtIn), "the built-in Zoom's hold is new")
        XCTAssertEqual(holds.heldApps, ["custom:com.example.zoom", "Zoom"])

        XCTAssertEqual(holds.release { $0 == added }, ["custom:com.example.zoom"])
        XCTAssertEqual(holds.heldApps, ["Zoom"])
        XCTAssertEqual(holds.release { $0 == builtIn }, ["Zoom"])
        XCTAssertTrue(holds.heldApps.isEmpty)
    }

    // MARK: - Offered for "Record Again"

    /// Only an offered hold is offered, sorted by app; a released one is
    /// forgotten, so the same app held again later is offered only if that
    /// hold is.
    func testOnlyOfferedHoldsAreOffered() {
        var holds = RedetectionHolds()
        let (teams, zoom) = (meeting(.teams), meeting(.zoom))
        _ = holds.hold(zoom, offered: true)
        _ = holds.hold(meeting(.webex))
        _ = holds.hold(teams, offered: true)

        XCTAssertEqual(holds.offeredMeetings, [teams, zoom])
        XCTAssertEqual(holds.heldApps, ["Microsoft Teams", "Webex", "Zoom"])

        _ = holds.release { $0 == teams }
        _ = holds.hold(teams)
        XCTAssertEqual(holds.offeredMeetings, [zoom], "the new hold is not offered")
    }

    /// Lifting hands back the meeting of an offered hold whose meeting still
    /// runs and removes only that hold; anything else changes nothing.
    func testLiftOfferedTakesOnlyAnOfferedHoldWhoseMeetingRuns() {
        var holds = RedetectionHolds()
        let teams = meeting(.teams)
        _ = holds.hold(teams, offered: true)
        _ = holds.hold(meeting(.zoom))
        let before = holds

        XCTAssertNil(holds.liftOffered("Zoom") { _ in true }, "not offered")
        XCTAssertNil(holds.liftOffered("Webex") { _ in true }, "not held")
        XCTAssertNil(holds.liftOffered("Microsoft Teams") { _ in false }, "its meeting is over")
        XCTAssertEqual(holds, before)

        XCTAssertEqual(holds.liftOffered("Microsoft Teams") { _ in true }, teams)
        XCTAssertEqual(holds.heldApps, ["Zoom"], "every other hold stays")
        XCTAssertTrue(holds.offeredMeetings.isEmpty)
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
