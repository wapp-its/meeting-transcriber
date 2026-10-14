@testable import MeetingTranscriber
import XCTest

/// Where a pause marker lands in the rendered transcript, and that merging
/// same-speaker lines never swallows one.
///
/// The marker's wording is pinned in `RecordingPauseTests`; these compare
/// against `markerLine(in:)` in a fixed zone and assert only the position.
final class TranscriptPauseMarkerTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let utc = TimeZone(identifier: "UTC")!
    private let note = "[Recording note: the microphone track was empty.]"

    private func segment(
        _ start: TimeInterval, _ text: String, speaker: String = "", suppressed: Bool = false,
    ) -> TimestampedSegment {
        TimestampedSegment(start: start, end: start + 2, text: text, speaker: speaker, suppressed: suppressed)
    }

    /// Three lines at 0 s, 5 s and 10 s.
    private var lines: [TimestampedSegment] {
        [segment(0, "one"), segment(5, "two"), segment(10, "three")]
    }

    /// A pause at `offset` on the transcript timeline; `minute` makes its
    /// marker text differ from the others in the same test.
    private func pause(at offset: TimeInterval, minute: Int) -> RecordingPause {
        let start = Date(timeIntervalSince1970: TimeInterval(minute * 60))
        return RecordingPause(startedAt: start, endedAt: start.addingTimeInterval(30), offsetSeconds: offset)
    }

    private func marker(_ pause: RecordingPause) -> String {
        pause.markerLine(in: utc)
    }

    private func render(
        _ segments: [TimestampedSegment], pauses: [RecordingPause], note: String? = nil,
    ) -> String {
        segments.transcriptText(note: note, pauses: pauses, timeZone: utc)
    }

    // MARK: - Rendering

    /// Every recording made before pauses existed renders through here, so
    /// without a pause the text is byte for byte what it was.
    func testWithoutPausesTheTranscriptIsUnchanged() {
        XCTAssertEqual(render(lines, pauses: []), "[00:00] one\n[00:05] two\n[00:10] three")
        XCTAssertEqual(
            render(lines, pauses: [], note: note),
            note + "\n\n[00:00] one\n[00:05] two\n[00:10] three",
        )
    }

    /// A line starting exactly at the offset was spoken after the resume, so
    /// the marker goes above it.
    func testTheMarkerGoesBeforeTheFirstLineStartingAtOrAfterItsOffset() {
        let atTwo = pause(at: 5, minute: 1)
        XCTAssertEqual(
            render(lines, pauses: [atTwo]),
            "[00:00] one\n\(marker(atTwo))\n[00:05] two\n[00:10] three",
        )

        let afterTwo = pause(at: 6, minute: 1)
        XCTAssertEqual(
            render(lines, pauses: [afterTwo]),
            "[00:00] one\n[00:05] two\n\(marker(afterTwo))\n[00:10] three",
        )
    }

    func testAPauseAtTheStartOpensTheTranscriptUnderTheNote() {
        let first = pause(at: 0, minute: 1)

        XCTAssertEqual(
            render(lines, pauses: [first], note: note),
            note + "\n\n\(marker(first))\n[00:00] one\n[00:05] two\n[00:10] three",
        )
    }

    /// A recording that ended while paused has nothing after its last pause.
    func testAPauseAfterTheLastLineClosesTheTranscript() {
        let last = pause(at: 30, minute: 1)

        XCTAssertEqual(
            render(lines, pauses: [last]),
            "[00:00] one\n[00:05] two\n[00:10] three\n\(marker(last))",
        )
    }

    /// Handed over out of order on purpose: the order is the timeline's.
    func testSeveralMarkersAppearInTimelineOrder() {
        let early = pause(at: 3, minute: 1)
        let later = pause(at: 4, minute: 3)
        let latest = pause(at: 8, minute: 2)

        XCTAssertEqual(
            render(lines, pauses: [latest, early, later]),
            "[00:00] one\n\(marker(early))\n\(marker(later))\n[00:05] two\n\(marker(latest))\n[00:10] three",
        )
    }

    func testASuppressedLineNeitherRendersNorHoldsAMarker() {
        let segments = [segment(0, "one"), segment(5, "echo copy", suppressed: true), segment(10, "three")]
        let gap = pause(at: 4, minute: 1)

        XCTAssertEqual(render(segments, pauses: [gap]), "[00:00] one\n\(marker(gap))\n[00:10] three")
    }

    // MARK: - Merging same-speaker lines

    /// Two lines of one speaker a second apart merge into one block, unless a
    /// pause lies after the block's start and no later than the second line's
    /// start: the marker belongs between them. A pause at the block's own
    /// start goes above the whole block, so it does not split it.
    func testSameSpeakerLinesAroundAPauseStaySeparate() {
        let segments = [segment(0, "before", speaker: "A"), segment(3, "after", speaker: "A")]
        let cases: [(offsets: [TimeInterval], blocks: Int, what: String)] = [
            ([], 1, "no pause merges as before"),
            ([2.5], 2, "pause in the gap"),
            ([3], 2, "pause at the second line's start"),
            ([0], 1, "pause at the block's start"),
            ([7], 1, "pause after both"),
        ]
        for c in cases {
            let merged = DiarizationProcess.mergeConsecutiveSpeakers(segments, breakingAt: c.offsets)
            XCTAssertEqual(merged.count, c.blocks, c.what)
        }
    }
}
