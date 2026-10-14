@testable import MeetingTranscriber
import XCTest

/// The pause record, the log that produces it, and the conversions between the
/// wall clock and the pause-free saved timeline.
///
/// Marker times are pinned in Tokyo, a zone that is neither UTC (a CI runner)
/// nor the zone a developer here sits in, so a rendering that ignored the zone
/// it is handed cannot pass on either machine.
final class RecordingPauseTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "bad fixture date \(iso)")
    }

    /// A wall-clock instant `seconds` after a fixed origin, for the arithmetic
    /// tests where only differences matter.
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
    }

    private func pause(_ start: TimeInterval, _ end: TimeInterval, offset: TimeInterval = 0) -> RecordingPause {
        RecordingPause(startedAt: at(start), endedAt: at(end), offsetSeconds: offset)
    }

    // MARK: - Marker text

    /// An afternoon pause reads 14:05, never 2:05 PM: the formatter is pinned
    /// to the POSIX locale, so a 12-hour user locale cannot reach it.
    func testTheMarkerReadsTwentyFourHourTimesJoinedByAnEnDash() throws {
        let pause = try RecordingPause(
            startedAt: date("2026-10-14T14:05:30+09:00"),
            endedAt: date("2026-10-14T14:20:10+09:00"),
            offsetSeconds: 0,
        )

        XCTAssertEqual(pause.markerLine(in: tokyo), "[Pause 14:05\u{2013}14:20]")
    }

    func testAPauseAcrossMidnightReadsBothClockTimes() throws {
        let pause = try RecordingPause(
            startedAt: date("2026-10-14T23:50:00+09:00"),
            endedAt: date("2026-10-15T00:10:00+09:00"),
            offsetSeconds: 0,
        )

        XCTAssertEqual(pause.markerLine(in: tokyo), "[Pause 23:50\u{2013}00:10]")
    }

    // MARK: - Log

    func testPausingWhilePausedChangesNothing() {
        var log = RecordingPauseLog()

        XCTAssertTrue(log.pause(at: at(10)))
        XCTAssertFalse(log.pause(at: at(15)), "a second pause is a no-op")
        XCTAssertEqual(log.pausedSince, at(10), "the first pause instant stands")
    }

    func testResumingWhileRunningChangesNothing() {
        var log = RecordingPauseLog()

        XCTAssertNil(log.resume(at: at(5)), "nothing was paused")
        XCTAssertTrue(log.pause(at: at(10)))
        XCTAssertEqual(log.resume(at: at(25)), 15, "the resume reports how long the pause lasted")
        XCTAssertNil(log.resume(at: at(30)), "a second resume is a no-op")
        XCTAssertNil(log.pausedSince)
        XCTAssertEqual(
            log.pauses(endingAt: at(40), recordingStartedAt: at(0), capturedOffsets: []),
            [pause(10, 25, offset: 10)],
            "only the one pause that happened",
        )
    }

    func testAPauseStillOpenAtTheStopEndsAtTheStop() {
        var log = RecordingPauseLog()
        XCTAssertTrue(log.pause(at: at(10)))

        let pauses = log.pauses(endingAt: at(60), recordingStartedAt: at(0), capturedOffsets: [])

        XCTAssertEqual(pauses, [pause(10, 60, offset: 10)])
    }

    /// The capture measured where each pause sits on the saved tracks, which
    /// the wall clock cannot know once the Mac slept, so those win.
    func testCapturedOffsetsAreUsedWhenTheirCountMatches() {
        var log = RecordingPauseLog()
        XCTAssertTrue(log.pause(at: at(10)))
        XCTAssertNotNil(log.resume(at: at(20)))
        XCTAssertTrue(log.pause(at: at(30)))

        let pauses = log.pauses(endingAt: at(40), recordingStartedAt: at(0), capturedOffsets: [3.5, 7.25])

        XCTAssertEqual(pauses, [pause(10, 20, offset: 3.5), pause(30, 40, offset: 7.25)])
    }

    /// No positions, or a count that cannot be paired in order, falls back to
    /// the wall clock for every pause: time since the start minus the pauses
    /// before it, since those left nothing on the saved timeline.
    func testTheWallClockFallbackSubtractsEarlierPauses() {
        for captured: [TimeInterval] in [[], [1]] {
            var log = RecordingPauseLog()
            XCTAssertTrue(log.pause(at: at(10)))
            XCTAssertNotNil(log.resume(at: at(20)))
            XCTAssertTrue(log.pause(at: at(30)))
            XCTAssertNotNil(log.resume(at: at(45)))

            let pauses = log.pauses(endingAt: at(60), recordingStartedAt: at(0), capturedOffsets: captured)

            XCTAssertEqual(
                pauses, [pause(10, 20, offset: 10), pause(30, 45, offset: 20)],
                "captured offsets \(captured)",
            )
        }
    }

    func testTheWallClockFallbackIsClampedAtZero() {
        var log = RecordingPauseLog()
        XCTAssertTrue(log.pause(at: at(-3)))

        let pauses = log.pauses(endingAt: at(20), recordingStartedAt: at(0), capturedOffsets: [])

        XCTAssertEqual(pauses.map(\.offsetSeconds), [0])
    }

    // MARK: - Conversions

    func testPausedDurationCountsOnlyThePausedTimeInsideTheInterval() {
        let pauses = [pause(10, 20), pause(30, 40)]
        let cases: [(from: TimeInterval, to: TimeInterval, expected: TimeInterval, what: String)] = [
            (0, 5, 0, "misses both"),
            (20, 30, 0, "touches both only at their edges"),
            (12, 18, 6, "inside one pause"),
            (15, 35, 10, "cuts into both, the second one still running at the end"),
            (0, 50, 20, "contains both"),
        ]
        for c in cases {
            XCTAssertEqual(pauses.pausedDuration(from: at(c.from), to: at(c.to)), c.expected, c.what)
        }
    }

    /// The saved timeline leaves paused time out, so it stands still inside a
    /// pause and runs on after it, behind the wall clock by the time paused.
    func testTimelineOffsetStandsStillInsideAPause() {
        let pauses = [pause(10, 20), pause(30, 40)]
        let cases: [(wall: TimeInterval, expected: TimeInterval, what: String)] = [
            (-5, 0, "before the recording started"),
            (5, 5, "before any pause"),
            (15, 10, "inside the first pause"),
            (20, 10, "at the first resume"),
            (25, 15, "between the pauses"),
            (35, 20, "inside the second pause"),
            (50, 30, "after both"),
        ]
        for c in cases {
            XCTAssertEqual(pauses.timelineOffset(of: at(c.wall), recordingStartedAt: at(0)), c.expected, c.what)
        }
    }

    func testClippingDropsLaterPausesAndEndsTheOneSpanningTheCut() {
        let pauses = [pause(10, 20, offset: 10), pause(30, 40, offset: 20), pause(50, 60, offset: 30)]

        XCTAssertEqual(
            pauses.clipped(at: at(35)),
            [pause(10, 20, offset: 10), pause(30, 35, offset: 20)],
        )
        XCTAssertEqual(
            pauses.clipped(at: at(30)),
            [pause(10, 20, offset: 10)],
            "a pause starting at the cut is after it",
        )
    }
}
