@testable import MeetingTranscriber
import XCTest

/// What a job run through the pipeline leaves in the finished-job history:
/// the fields the Transcriptions window lists, including the recording's
/// length, which stage 1 measures from the 16 kHz audio.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueHistoryRecordTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_history_record_test")
    }

    private func makeQueue(engine: MockEngine, store: TerminalJobStore) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            echoDedupEnabled: false,
            terminalJobStore: store,
        )
    }

    /// One 16 kHz track of `frames` samples.
    private func writeTrack(frames: Int, named name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.05, count: frames),
            sampleRate: AudioConstants.targetSampleRate,
            url: url,
        )
        return url
    }

    /// Run `job` to its end and return the history record it left.
    private func runToHistory(_ job: PipelineJob, engine: MockEngine) async throws -> TerminalJobRecord {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let queue = makeQueue(engine: engine, store: store)
        queue.enqueue(job)
        await queue.awaitProcessing()
        let record = try XCTUnwrap(store.records.first { $0.status.jobID == job.id.uuidString })
        XCTAssertEqual(record.status.state, .done, "test premise: the job finished")
        return record
    }

    func testAFinishedJobLeavesWhatTheWindowLists() async throws {
        let engine = MockEngine()
        // Speech ends well before the recording does: the history carries the
        // recording's length, not the transcript's.
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 0.2, text: "Hello")]
        let meetingStart = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let job = try PipelineJob(
            meetingTitle: "Design Review", appName: "Microsoft Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
            participants: ["Anna Müller", "Ben Okafor"], meetingStartTime: meetingStart,
        )

        let record = try await runToHistory(job, engine: engine)

        XCTAssertEqual(record.status.meetingTitle, "Design Review")
        XCTAssertEqual(record.appName, "Microsoft Teams")
        XCTAssertEqual(record.participants, ["Anna Müller", "Ben Okafor"])
        XCTAssertEqual(record.meetingStartTime, meetingStart)
        XCTAssertEqual(record.enqueuedAt, job.enqueuedAt)
        // `createTestAudioFile` holds 0.5 s at 16 kHz.
        XCTAssertEqual(try XCTUnwrap(record.audioDuration), 0.5, accuracy: 0.05)
    }

    func testADualSourceJobLastsAsLongAsItsLongerTrack() async throws {
        // Either track can be the longer one; a duration read from one fixed
        // side passes exactly one of these.
        let cases: [(app: Int, mic: Int, expected: TimeInterval)] = [
            (app: 16000, mic: 24000, expected: 1.5),
            (app: 32000, mic: 8000, expected: 2.0),
        ]
        for (index, tracks) in cases.enumerated() {
            let engine = MockEngine()
            engine.segmentsByPathSuffix = [
                "app_16k.wav": [TimestampedSegment(start: 0, end: 0.3, text: "far end speaking")],
                "mic_16k.wav": [TimestampedSegment(start: 0.4, end: 0.6, text: "local answer")],
            ]
            let job = try PipelineJob(
                meetingTitle: "Call \(index)", appName: "Zoom", mixPath: nil,
                appPath: writeTrack(frames: tracks.app, named: "call\(index)_app.wav"),
                micPath: writeTrack(frames: tracks.mic, named: "call\(index)_mic.wav"),
                micDelay: 0,
            )

            let record = try await runToHistory(job, engine: engine)

            XCTAssertEqual(
                try XCTUnwrap(record.audioDuration), tracks.expected, accuracy: 0.01,
                "app \(tracks.app) frames, mic \(tracks.mic) frames",
            )
        }
    }
}
