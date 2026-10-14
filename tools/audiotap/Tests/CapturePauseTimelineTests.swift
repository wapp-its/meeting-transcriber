@testable import AudioTapLib
import XCTest

/// The pause clock both capture tracks consult per buffer. Times are host
/// seconds; the values are chosen so every difference is exact in binary, so
/// a frame boundary in these tests is never a rounding question.
final class CapturePauseTimelineTests: XCTestCase {
    /// One closed pause on [101, 103).
    private func onePause() -> CapturePauseTimeline {
        var timeline = CapturePauseTimeline()
        timeline.pause(atHostSeconds: 101)
        timeline.resume(atHostSeconds: 103)
        return timeline
    }

    func testWithoutAPauseTheRecordingClockIsHostTimeAndEveryFrameIsKept() {
        let timeline = CapturePauseTimeline()

        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 123.456), 123.456)
        XCTAssertFalse(timeline.isPaused(atHostSeconds: 123.456))
        XCTAssertFalse(timeline.hasOpenPause)
        XCTAssertEqual(
            timeline.keptFrameRanges(bufferStartSeconds: 100, frameCount: 480, sampleRate: 48000),
            [0 ..< 480],
        )
    }

    func testAClosedPauseCoversExactlyItsHalfOpenSpan() {
        let timeline = onePause()

        XCTAssertFalse(timeline.isPaused(atHostSeconds: 100.75))
        XCTAssertTrue(timeline.isPaused(atHostSeconds: 101), "the pause instant itself is paused")
        XCTAssertTrue(timeline.isPaused(atHostSeconds: 102.5))
        XCTAssertFalse(timeline.isPaused(atHostSeconds: 103), "the resume instant is recorded again")
        XCTAssertFalse(timeline.hasOpenPause)
    }

    func testTheRecordingClockStandsStillInsideAPauseAndIsShiftedAfterIt() {
        let timeline = onePause()

        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 100.5), 100.5, "before: untouched")
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 101), 101)
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 102.25), 101, "inside: flat at the pause start")
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 103), 101)
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 104.5), 102.5, "after: shifted by the 2 s pause")
    }

    /// Buffers at 100 Hz (frame `i` at `start + i / 100`) placed around the
    /// pause on [101, 103).
    func testKeptFrameRangesAroundOneClosedPause() {
        let timeline = onePause()
        let cases: [(String, start: Double, frames: Int, kept: [Range<Int>])] = [
            ("before", 100, 50, [0 ..< 50]),
            ("ending exactly at the pause", 100.5, 50, [0 ..< 50]),
            ("inside", 101.5, 50, []),
            ("straddling the start", 100.5, 100, [0 ..< 50]),
            ("straddling the end", 102.5, 100, [50 ..< 100]),
            ("starting exactly at the resume", 103, 25, [0 ..< 25]),
        ]
        for (name, start, frames, kept) in cases {
            XCTAssertEqual(
                timeline.keptFrameRanges(bufferStartSeconds: start, frameCount: frames, sampleRate: 100),
                kept, name,
            )
        }
    }

    func testABufferContainingAWholeShortPauseKeepsBothSides() {
        var timeline = CapturePauseTimeline()
        timeline.pause(atHostSeconds: 100.25)
        timeline.resume(atHostSeconds: 100.5)

        XCTAssertEqual(
            timeline.keptFrameRanges(bufferStartSeconds: 100, frameCount: 100, sampleRate: 100),
            [0 ..< 25, 50 ..< 100],
        )
    }

    func testAnOpenPauseCutsEverythingFromItsStart() {
        var timeline = CapturePauseTimeline()
        timeline.pause(atHostSeconds: 101)

        XCTAssertTrue(timeline.hasOpenPause)
        XCTAssertTrue(timeline.isPaused(atHostSeconds: 5000))
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 5000), 101, "an open pause holds the clock")
        XCTAssertEqual(
            timeline.keptFrameRanges(bufferStartSeconds: 100.5, frameCount: 100, sampleRate: 100),
            [0 ..< 50],
        )
        XCTAssertEqual(timeline.keptFrameRanges(bufferStartSeconds: 102, frameCount: 100, sampleRate: 100), [])
    }

    func testSeveralPausesAddUpAndEachCutsItsOwnFrames() {
        var timeline = CapturePauseTimeline()
        timeline.pause(atHostSeconds: 100.25)
        timeline.resume(atHostSeconds: 100.5)
        timeline.pause(atHostSeconds: 100.75)
        timeline.resume(atHostSeconds: 101.25)
        timeline.pause(atHostSeconds: 102)

        XCTAssertEqual(timeline.pauses.count, 3)
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 101.5), 100.75, "0.25 s + 0.5 s paused before")
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 103), 101.25, "plus the open pause from 102")
        XCTAssertEqual(
            timeline.keptFrameRanges(bufferStartSeconds: 100, frameCount: 300, sampleRate: 100),
            [0 ..< 25, 50 ..< 75, 125 ..< 200],
        )
    }

    func testRepeatedPauseAndResumeChangeNothing() {
        var timeline = onePause()
        let settled = timeline

        timeline.resume(atHostSeconds: 104)
        XCTAssertEqual(timeline, settled, "a resume while running is a no-op")

        timeline.pause(atHostSeconds: 105)
        let paused = timeline
        timeline.pause(atHostSeconds: 106)
        XCTAssertEqual(timeline, paused, "a second pause keeps the first one's start")
        XCTAssertEqual(timeline.pauses.last?.start, 105)
    }

    func testAResumeEarlierThanItsPauseClampsToThePauseStart() {
        var timeline = CapturePauseTimeline()
        timeline.pause(atHostSeconds: 101)
        timeline.resume(atHostSeconds: 100)

        XCTAssertEqual(timeline.pauses, [.init(start: 101, end: 101)])
        XCTAssertFalse(timeline.isPaused(atHostSeconds: 101), "an empty pause cuts nothing")
        XCTAssertEqual(timeline.recordingSeconds(atHostSeconds: 102), 102)
    }

    func testAPauseEarlierThanTheLastResumeStartsAtThatResume() {
        var timeline = onePause()
        timeline.pause(atHostSeconds: 102)

        XCTAssertEqual(timeline.pauses.last?.start, 103, "pauses stay ordered and never overlap")
    }
}
