@testable import AudioTapLib
import XCTest

/// The cutter's contract on its own, without audio: no paused frame is ever
/// handed out, and the frames handed out stay within half a frame of the
/// recording clock however many pauses there are, which a plain cut does not.
final class CapturePauseCutterTests: XCTestCase {
    private static let base = 1000.0

    func testWithoutAPauseEveryBufferIsWholeOnTheHostClock() {
        var cutter = CapturePauseCutter()
        let pieces = cutter.pieces(
            of: CapturePauseTimeline(), bufferStartSeconds: Self.base, frameCount: 480, sampleRate: 48000,
        )
        XCTAssertEqual(pieces, [.init(frames: 0 ..< 480, leadingRepeats: 0, recordingSeconds: Self.base)])
    }

    func testABufferInsideAPauseHasNoPieces() {
        var timeline = CapturePauseTimeline()
        timeline.pause(atHostSeconds: Self.base)
        var cutter = CapturePauseCutter()
        XCTAssertEqual(
            cutter.pieces(of: timeline, bufferStartSeconds: Self.base + 0.1, frameCount: 480, sampleRate: 48000), [],
        )
    }

    /// After a pause whose cut came out exact, a later buffer no pause
    /// touches is handed out whole again.
    func testABufferAfterAnExactCutIsWholeAgain() {
        var timeline = CapturePauseTimeline()
        timeline.pause(atHostSeconds: Self.base + 0.01)
        timeline.resume(atHostSeconds: Self.base + 0.02)
        var cutter = CapturePauseCutter()
        for index in 0 ..< 3 {
            _ = cutter.pieces(
                of: timeline, bufferStartSeconds: Self.base + Double(index) * 0.01, frameCount: 480, sampleRate: 48000,
            )
        }
        let later = cutter.pieces(of: timeline, bufferStartSeconds: Self.base + 0.03, frameCount: 480, sampleRate: 48000)
        XCTAssertEqual(later.count, 1)
        XCTAssertTrue(later.first?.isWhole(of: 480) ?? false)
        XCTAssertEqual(later.first?.recordingSeconds ?? 0, Self.base + 0.02, accuracy: 1e-9)
    }

    /// Twenty pauses whose boundaries fall at the same phase between two
    /// frames: at 48 kHz the first pattern cuts almost a frame less than the
    /// paused time each time, the second almost one more, the third a
    /// microphone-like 44.1 kHz grid with 85 ms buffers. A plain cut drifts by
    /// several frames; the cutter stays within half a frame, settles only
    /// right after a cut, and never hands out a paused frame.
    func testRepeatedSubFramePausesStayWithinHalfAFrame() {
        let cases = [
            Pattern(start: 0.520021, end: 0.530041, rate: 48000, frames: 480, offset: 0),
            Pattern(start: 0.520039, end: 0.530001, rate: 48000, frames: 480, offset: 0),
            Pattern(start: 0.630001, end: 0.640019, rate: 44100, frames: 3750, offset: 0.003),
        ]
        for pattern in cases {
            var timeline = CapturePauseTimeline()
            for index in 0 ..< 20 {
                timeline.pause(atHostSeconds: Self.base + pattern.start + 0.1 * Double(index))
                timeline.resume(atHostSeconds: Self.base + pattern.end + 0.1 * Double(index))
            }
            let label = "[\(pattern.start), \(pattern.end)) at \(pattern.rate) Hz"
            let check = drive(timeline, pattern: pattern)
            XCTAssertLessThanOrEqual(check.worstOffset, 0.5 + 1e-6, "\(label): written frames against the recording clock")
            XCTAssertGreaterThan(check.plainCutDrift, 2, "\(label): the case is one a plain cut drifts on")
            XCTAssertEqual(check.pausedFramesHandedOut, 0, "\(label): no paused frame handed out")
            XCTAssertEqual(check.settlementsAwayFromASeam, 0, "\(label): frames settled only right after a cut")
        }
    }

    /// Twenty pauses `[start, end)` a tenth of a second apart, over buffers
    /// of `frames` frames at `rate` that start at `offset`.
    private struct Pattern {
        let start: Double
        let end: Double
        let rate: Double
        let frames: Int
        let offset: Double
    }

    private struct Check {
        var worstOffset = 0.0
        var plainCutDrift = 0.0
        var pausedFramesHandedOut = 0
        var settlementsAwayFromASeam = 0
    }

    /// Feed contiguous buffers for three seconds and compare, at every piece,
    /// the frames handed out before it with the frames the recording clock
    /// allows up to its first frame. A piece is settled when it differs from
    /// the plain cut's range (a frame left out or repeated); a seam is a range
    /// that starts right after cut frames, in its own buffer or the one before.
    private func drive(
        _ timeline: CapturePauseTimeline, pattern: Pattern,
    ) -> Check {
        var cutter = CapturePauseCutter()
        var check = Check()
        let origin = Self.base + pattern.offset
        var written = 0
        var plainKept = 0
        var buffer = 0
        var previousEndedInACut = false
        while Double(buffer * pattern.frames) / pattern.rate < 3 {
            let start = origin + Double(buffer * pattern.frames) / pattern.rate
            let pieces = cutter.pieces(
                of: timeline, bufferStartSeconds: start, frameCount: pattern.frames, sampleRate: pattern.rate,
            )
            let kept = timeline.keptFrameRanges(
                bufferStartSeconds: start, frameCount: pattern.frames, sampleRate: pattern.rate,
            )
            var seamAt: [Int: Bool] = [:]
            var plainEnd = 0
            for range in kept {
                seamAt[range.upperBound] = range.lowerBound > plainEnd || (range.lowerBound == 0 && previousEndedInACut)
                plainEnd = range.upperBound
            }
            for piece in pieces {
                let allowed = (piece.recordingSeconds - origin) * pattern.rate
                check.worstOffset = max(check.worstOffset, abs(Double(written) - allowed))
                let plain = kept.first { $0.upperBound == piece.frames.upperBound }
                let settled = piece.leadingRepeats > 0 || piece.frames.lowerBound != plain?.lowerBound
                if settled, seamAt[piece.frames.upperBound] != true { check.settlementsAwayFromASeam += 1 }
                check.pausedFramesHandedOut += piece.frames.filter { frame in
                    timeline.isPaused(atHostSeconds: start + Double(frame) / pattern.rate)
                }.count
                written += piece.leadingRepeats + piece.frames.count
            }
            previousEndedInACut = plainEnd < pattern.frames
            plainKept += kept.reduce(0) { $0 + $1.count }
            buffer += 1
        }
        let end = origin + Double(buffer * pattern.frames) / pattern.rate
        let allowedAtEnd = (timeline.recordingSeconds(atHostSeconds: end) - origin) * pattern.rate
        check.worstOffset = max(check.worstOffset, abs(Double(written) - allowedAtEnd))
        check.plainCutDrift = abs(Double(plainKept) - allowedAtEnd)
        print("cutter: worst offset \(check.worstOffset), plain cut drift \(check.plainCutDrift) frames")
        return check
    }
}
