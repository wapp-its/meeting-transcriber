@testable import MeetingTranscriber
import XCTest

/// A job carrying a pause has its marker in every transcript the pipeline
/// saves: after the transcription stage, after the speaker-labelled rewrite,
/// after a late re-diarization, and in the text the protocol is made from.
///
/// Driven through `enqueue` + `processNext`, as `EmptyTrackSurvivesTests` is,
/// because each of those renderings is its own call site in the queue or the
/// naming session, and only a run through them shows that each passes the
/// job's pauses along. The far end says two lines a second apart with the
/// pause between them: one speaker, so the speaker-labelled rendering would
/// merge them into one block and put the marker below words spoken after the
/// resume, unless the merge breaks at the pause.
@MainActor
final class TranscriptPauseMarkerPipelineTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // The shared helper registers its own teardown; the pipeline writes
        // the transcript owner-only, which a hand-rolled removal trips over.
        tmpDir = try makeTempDirectory(prefix: "pausemarker")
    }

    /// Between the far end's two lines, which start at 0 s and 3 s.
    private static let pause = RecordingPause(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_900),
        offsetSeconds: 2.5,
    )

    // MARK: - Harness

    private struct Harness {
        let queue: PipelineQueue
        let engine: MockEngine
        let protocolGen: MockProtocolGen
    }

    private func makeHarness(diarizeEnabled: Bool = false) -> Harness {
        let engine = MockEngine()
        engine.segmentsByPathSuffix = [
            "app_16k.wav": [
                TimestampedSegment(start: 0, end: 2, text: "before the pause"),
                TimestampedSegment(start: 3, end: 5, text: "after the pause"),
            ],
            "mic_16k.wav": [TimestampedSegment(start: 6, end: 9, text: "local answer")],
        ]
        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 5.0],
            autoNames: [:],
            embeddings: ["SPEAKER_00": [1, 0, 0]],
        )
        let protocolGen = MockProtocolGen()
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            diarizeEnabled: diarizeEnabled,
            echoDedupEnabled: false,
        )
        return Harness(queue: queue, engine: engine, protocolGen: protocolGen)
    }

    private func writeTrack(named name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.05, count: 160_000),
            sampleRate: AudioConstants.targetSampleRate,
            url: url,
        )
        return url
    }

    private func run(
        _ h: Harness,
        naming: @escaping (PipelineQueue.SpeakerNamingData) async -> PipelineQueue.SpeakerNamingResult = { _ in .skipped },
    ) async throws {
        h.queue.speakerNamingHandler = naming
        try h.queue.enqueue(PipelineJob(
            meetingTitle: "meeting", appName: "File",
            mixPath: nil,
            appPath: writeTrack(named: "meeting_app.wav"),
            micPath: writeTrack(named: "meeting_mic.wav"),
            micDelay: 0,
            pauses: [Self.pause],
        ))
        await h.queue.processNext()
        await waitFor(h.queue.jobs.first?.state.isTerminal ?? false, timeout: .seconds(10))
    }

    private func transcript(_ h: Harness) throws -> String {
        let path = try XCTUnwrap(h.queue.jobs.first?.transcriptPath)
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// The marker is its own line, directly after the line spoken before the
    /// pause and directly before the one spoken after it. A merged block holds
    /// both texts on one line, which fails the second check.
    private func assertMarkerBetweenTheFarEndLines(
        _ text: String, file: StaticString = #filePath, line: UInt = #line,
    ) throws {
        let lines = text.components(separatedBy: "\n")
        let marker = try XCTUnwrap(
            lines.firstIndex(of: Self.pause.markerLine()), "no marker line:\n\(text)", file: file, line: line,
        )
        let before = try XCTUnwrap(lines.firstIndex { $0.contains("before the pause") }, file: file, line: line)
        let after = try XCTUnwrap(lines.firstIndex { $0.contains("after the pause") }, file: file, line: line)
        XCTAssertEqual(marker, before + 1, "marker under the line before it:\n\(text)", file: file, line: line)
        XCTAssertEqual(after, marker + 1, "marker over the line after it:\n\(text)", file: file, line: line)
    }

    // MARK: - Every saved transcript

    func testTheMarkerSitsBetweenTheRightLinesAfterTheTranscriptionStage() async throws {
        let h = makeHarness()

        try await run(h)

        XCTAssertEqual(h.queue.jobs.first?.state, .done, "error: \(h.queue.jobs.first?.error ?? "none")")
        try assertMarkerBetweenTheFarEndLines(transcript(h))
    }

    /// The protocol is generated from the speaker-labelled transcript and
    /// carries it in full at its end, so the marker has to reach both.
    func testTheMarkerSurvivesTheSpeakerLabelledRewrite() async throws {
        let h = makeHarness(diarizeEnabled: true)

        try await run(h)

        XCTAssertEqual(h.queue.jobs.first?.state, .done, "error: \(h.queue.jobs.first?.error ?? "none")")
        try assertMarkerBetweenTheFarEndLines(transcript(h))
        let marker = Self.pause.markerLine()
        XCTAssertTrue(h.protocolGen.capturedTranscript?.contains(marker) ?? false, "the protocol model's input")
        let protocolPath = try XCTUnwrap(h.queue.jobs.first?.protocolPath)
        XCTAssertTrue(try String(contentsOf: protocolPath, encoding: .utf8).contains(marker), "the protocol file")
    }

    /// The late re-diarization renders again from the cached segments, which
    /// never carried the marker, and writes that over the saved transcript.
    func testTheMarkerSurvivesALateRediarization() async throws {
        let h = makeHarness(diarizeEnabled: true)
        var namingCalls = 0

        try await run(h) { _ in
            namingCalls += 1
            return namingCalls == 1 ? .rerun(2) : .skipped
        }

        XCTAssertEqual(namingCalls, 2, "the rerun has to actually run the late rewrite")
        try assertMarkerBetweenTheFarEndLines(transcript(h))
    }

    // MARK: - The marker must not stand in for a transcript

    func testAMarkerAloneIsNotATranscript() async throws {
        let h = makeHarness()
        h.engine.segmentsByPathSuffix = ["app_16k.wav": [], "mic_16k.wav": []]

        try await run(h)

        XCTAssertEqual(h.queue.jobs.first?.state, .error, "a transcript that is only a pause marker is not a transcript")
        XCTAssertEqual(h.queue.jobs.first?.error, "Empty transcript")
    }
}
