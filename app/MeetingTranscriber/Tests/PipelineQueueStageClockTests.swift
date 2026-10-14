@testable import MeetingTranscriber
import XCTest

/// The clock behind a running job's menu line, driven through real pipeline
/// runs: when its expected finish appears, and which history it is read from.
@MainActor
final class PipelineQueueStageClockTests: XCTestCase {
    private func makeLog(in dir: URL, _ events: [StageTimingEvent]) async -> StageTimingLog {
        let log = StageTimingLog(path: dir.appendingPathComponent("stage_timing.jsonl"))
        await log.append(events)
        return log
    }

    private func speed(
        _ stage: StageKind, wall: Double, audio: Double, engine: String, mode: DiarizerMode? = nil,
    ) -> StageTimingEvent {
        StageTimingEvent(
            ts: Date(), jobID: UUID(), stage: stage, wallClockSeconds: wall, audioSeconds: audio,
            engine: engine, diarizerMode: mode?.rawValue,
        )
    }

    /// A fresh job's length is unknown when transcription starts, so its line
    /// starts without a finish, and gets one when the length is measured,
    /// for a single recording and for an app track plus microphone alike.
    func testAFreshJobGetsItsFinishWhenItsAudioIsMeasured() async throws {
        for dualSource in [false, true] {
            let dir = try makeTempDirectory(prefix: "stage_clock_fresh")
            // Half a second of transcription per second of audio, for this engine.
            let log = await makeLog(in: dir, [speed(.transcribing, wall: 30, audio: 60, engine: "ParkedEngine")])
            let engine = ParkedEngine()
            engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 0.5, text: "Hello")]
            let queue = PipelineQueue(
                engine: engine,
                diarizationFactory: { MockDiarization() },
                protocolGeneratorFactory: { MockProtocolGen() },
                outputDir: dir, logDir: dir,
                stageTimingLog: log, inFlightRuns: InFlightRunRegistry(),
            )
            var atStart: StageClock?
            queue.onJobStateChange = { job, _, newState in
                if newState == .transcribing { atStart = queue.stageClock(forJobID: job.id) }
            }
            // Each fixture is half a second long.
            let job = try PipelineJob(
                meetingTitle: "Standup", appName: "Teams",
                mixPath: createTestAudioFile(in: dir),
                appPath: dualSource ? createTestAudioFile(in: dir) : nil,
                micPath: dualSource ? createTestAudioFile(in: dir) : nil,
                micDelay: 0,
            )
            queue.insertJobForTesting(job)

            async let run: Void = queue.processNext()
            await waitFor(engine.isParked, timeout: .seconds(10))
            let measured = queue.stageClock(forJobID: job.id)
            engine.release()
            await run

            let label = dualSource ? "app track and microphone" : "single recording"
            XCTAssertTrue(engine.isParked, "\(label): the run never reached transcription")
            XCTAssertNotNil(atStart, "\(label): no clock when transcription started")
            XCTAssertNil(atStart?.expectedFinish, "\(label): a finish before the audio was measured")
            XCTAssertEqual(measured?.startedAt, atStart?.startedAt, label)
            let finish = try XCTUnwrap(measured?.expectedFinish, "\(label): no finish once the audio was measured")
            XCTAssertEqual(try finish.timeIntervalSince(XCTUnwrap(measured?.startedAt)), 0.25, accuracy: 0.001, label)
        }
    }

    /// Diarization's finish is read from the history of the mode this run
    /// diarizes in: a late re-run in another mode is read from that mode,
    /// not from the mode the earlier run left with the naming data. Protocol
    /// generation is read from the mode the transcript was diarized in.
    func testDiarizationIsReadFromTheModeThisRunUses() async throws {
        let dir = try makeTempDirectory(prefix: "stage_clock_mode")
        // Offline diarizes in one second per second of audio, Sortformer in three.
        let log = await makeLog(in: dir, [
            speed(.diarizing, wall: 10, audio: 10, engine: "MockEngine", mode: .offline),
            speed(.diarizing, wall: 30, audio: 10, engine: "MockEngine", mode: .sortformer),
        ])
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 0.5, text: "Hello")]
        let offline = diarizer(.offline)
        let sortformer = diarizer(.sortformer)
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { offline },
            diarizationFactoryWithMode: { $0 == .sortformer ? sortformer : offline },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir, logDir: dir, diarizeEnabled: true,
            stageTimingLog: log, inFlightRuns: InFlightRunRegistry(),
        )
        var presentations = 0
        queue.speakerNamingHandler = { _ in
            presentations += 1
            return presentations == 1 ? .rerunWithMode(.sortformer, 2) : .confirmed([:])
        }
        var diarizing: [StageClock] = []
        var protocolClock: StageClock?
        let done = expectation(description: "job done")
        queue.onJobStateChange = { job, _, newState in
            if newState == .diarizing, let clock = queue.stageClock(forJobID: job.id) { diarizing.append(clock) }
            if newState == .generatingProtocol { protocolClock = queue.stageClock(forJobID: job.id) }
            if newState == .done { done.fulfill() }
        }
        let job = try PipelineJob(
            meetingTitle: "Retro", appName: "Zoom",
            mixPath: createTestAudioFile(in: dir), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        await queue.processNext()
        await fulfillment(of: [done], timeout: 60)

        XCTAssertEqual(diarizing.map(\.config.diarizerMode), ["offline", "sortformer"])
        let expected: [TimeInterval] = [0.5, 1.5]
        for (clock, seconds) in zip(diarizing, expected) {
            let finish = try XCTUnwrap(clock.expectedFinish, "no finish for \(clock.config)")
            XCTAssertEqual(finish.timeIntervalSince(clock.startedAt), seconds, accuracy: 0.001)
        }
        XCTAssertEqual(protocolClock?.config.diarizerMode, "sortformer")
    }

    /// A job the restore finds mid-protocol starts again right at launch. Its
    /// finish is read from the history all the same: the queue has read it by
    /// the time it exists, since a finish missed at a stage's start is never
    /// filled in later.
    func testAStageResumedAtLaunchReadsTheHistory() async throws {
        let dir = try makeTempDirectory(prefix: "stage_clock_restore")
        // A long history, which a read in the background would still be busy
        // with when the restore starts the job. A tenth of a second per second
        // of audio.
        let log = await makeLog(
            in: dir, Array(repeating: speed(.generatingProtocol, wall: 60, audio: 600, engine: "MockEngine"), count: 1000),
        )
        var job = try PipelineJob(
            meetingTitle: "Resume", appName: "Teams",
            mixPath: createTestAudioFile(in: dir), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .generatingProtocol
        job.audioDuration = 600
        job.namingSlug = "resume"
        let transcript = dir.appendingPathComponent("resume.txt")
        try "[00:00] Speaker: Hello".write(to: transcript, atomically: true, encoding: .utf8)
        job.transcriptPath = transcript
        try JSONEncoder().encode([job]).write(to: dir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir, logDir: dir,
            stageTimingLog: log, inFlightRuns: InFlightRunRegistry(),
        )
        var atStart: StageClock?
        queue.onJobStateChange = { job, _, newState in
            if newState == .generatingProtocol { atStart = queue.stageClock(forJobID: job.id) }
        }
        queue.loadSnapshot()
        await queue.awaitProcessing()

        let clock = try XCTUnwrap(atStart, "the restored job never generated its protocol")
        let finish = try XCTUnwrap(clock.expectedFinish, "no finish for a stage resumed at launch")
        XCTAssertEqual(finish.timeIntervalSince(clock.startedAt), 60, accuracy: 0.001)
    }

    private func diarizer(_ mode: DiarizerMode) -> MockDiarization {
        let mock = MockDiarization()
        mock.mode = mode
        mock.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 0.2, speaker: "SPEAKER_0"), .init(start: 0.2, end: 0.5, speaker: "SPEAKER_1")],
            speakingTimes: ["SPEAKER_0": 0.2, "SPEAKER_1": 0.3],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
        return mock
    }
}
