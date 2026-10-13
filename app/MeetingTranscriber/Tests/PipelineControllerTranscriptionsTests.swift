@testable import MeetingTranscriber
import XCTest

/// What the Transcriptions window does through `PipelineController`: list the
/// live jobs with the history, start the pipeline when it opens, and remove a
/// failed job for good.
@MainActor
final class PipelineControllerTranscriptionsTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    /// Settings over a per-test `UserDefaults` suite, never `.standard`.
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerTranscriptionsTests")
        let suite = "PipelineControllerTranscriptionsTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
    }

    /// Where a controller built without an injected store keeps its history.
    private var historyPath: URL {
        tmpDir.appendingPathComponent("terminal_jobs.json")
    }

    /// A controller over this test's folders. Without `queue:` it starts with
    /// a bare queue that has not read the snapshot, as the app does at launch.
    private func makeController(terminalJobStore: TerminalJobStore? = nil, queue: PipelineQueue? = nil) -> PipelineController {
        PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            terminalJobStore: terminalJobStore,
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: queue),
        )
    }

    /// A controller whose queue is already wired to an engine, so the
    /// pipeline counts as started and nothing reads the snapshot.
    private func makeWiredController(store: TerminalJobStore) -> PipelineController {
        makeController(terminalJobStore: store, queue: PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            terminalJobStore: store,
        ))
    }

    private func failedJob(_ title: String, mixPath: URL) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: mixPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .error
        job.error = "Transcription failed"
        return job
    }

    private func processedRecordings() -> Set<String> {
        ProcessedRecordingsLedger(logDir: tmpDir).load()
    }

    // MARK: - Remove

    func testRemovingALiveFailedJobTakesItOutOfQueueAndHistoryAndMarksItsAudio() throws {
        let store = TerminalJobStore(path: historyPath)
        let pc = makeWiredController(store: store)
        let mixPath = try createTestAudioFile(in: tmpDir)
        // Inserted already failed, so no transition marked the audio before
        // the removal does.
        let job = failedJob("Broken Sync", mixPath: mixPath)
        pc.queue.insertJobForTesting(job)
        store.record(TerminalJobRecord(job: job))
        XCTAssertFalse(processedRecordings().contains(mixPath.standardizedFileURL.path), "test premise")

        pc.removeFailedJob(id: job.id)

        XCTAssertFalse(pc.queue.jobs.contains { $0.id == job.id }, "the job is still in the queue")
        XCTAssertNil(store.lookup(jobID: job.id), "the job is still in the history")
        XCTAssertTrue(
            processedRecordings().contains(mixPath.standardizedFileURL.path),
            "the audio was not marked processed, so orphan recovery would bring the job back",
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixPath.path), "removing a job deleted its audio")
        XCTAssertFalse(pc.transcriptionEntries.contains { $0.id == job.id })
    }

    /// A failed job from an earlier session whose audio is gone is not restored
    /// into the queue, so the history is the only place it is listed from.
    func testRemovingAFailedJobKnownOnlyFromTheHistoryDropsItsRecord() {
        let store = TerminalJobStore(path: historyPath)
        let pc = makeWiredController(store: store)
        let job = failedJob("Gone Sync", mixPath: tmpDir.appendingPathComponent("gone_mix.wav"))
        store.record(TerminalJobRecord(job: job))

        pc.removeFailedJob(id: job.id)

        XCTAssertNil(store.lookup(jobID: job.id))
        XCTAssertNil(TerminalJobStore(path: historyPath).lookup(jobID: job.id), "the record came back after a restart")
    }

    func testRemoveLeavesADoneRecordAndAnUnfinishedJobAlone() {
        let store = TerminalJobStore(path: historyPath)
        let pc = makeWiredController(store: store)
        var done = failedJob("Finished Sync", mixPath: tmpDir.appendingPathComponent("finished_mix.wav"))
        done.state = .done
        done.error = nil
        store.record(TerminalJobRecord(job: done))
        let waitingMix = tmpDir.appendingPathComponent("waiting_mix.wav")
        let waitingID = pc.queue.insertJobForTesting(mixPath: waitingMix, state: .waiting)

        pc.removeFailedJob(id: done.id)
        pc.removeFailedJob(id: waitingID)

        XCTAssertEqual(store.lookup(jobID: done.id)?.state, .done, "a finished job's record was removed")
        XCTAssertEqual(pc.queue.jobs.first { $0.id == waitingID }?.state, .waiting, "an unfinished job was removed")
        XCTAssertFalse(processedRecordings().contains(waitingMix.standardizedFileURL.path))
    }

    // MARK: - Restart

    /// What a quit leaves of a failed job with its audio still there: the job
    /// in the pipeline snapshot, its outcome in the history.
    private func failedJobFromTheLastSession() throws -> PipelineJob {
        let job = try failedJob("Last Session", mixPath: createTestAudioFile(in: tmpDir))
        try PipelineSnapshot.save([job], to: tmpDir)
        TerminalJobStore(path: historyPath).record(TerminalJobRecord(job: job))
        return job
    }

    /// A launch over this test's files, before the pipeline has started.
    private func launchApp() -> PipelineController {
        let controller = makeController()
        controller.activate { MockEngine() }
        return controller
    }

    /// After a restart a failed job sits in the snapshot, which only a started
    /// pipeline reads. Opening the window starts it, so the job is live and can
    /// be retried; once removed it stays gone on the next launch.
    func testAFailedJobFromTheLastSessionIsRetryableOnceTheWindowOpensAndStaysRemoved() async throws {
        let job = try failedJobFromTheLastSession()

        let launch = launchApp()
        XCTAssertEqual(launch.transcriptionEntries.map(\.isLive), [false], "test premise: known from the history only")
        XCTAssertFalse(launch.canRetryJob(id: job.id), "test premise: nothing to retry before the pipeline loads it")

        launch.prepareTranscriptionsWindow()

        let entry = try XCTUnwrap(launch.transcriptionEntries.first { $0.id == job.id })
        XCTAssertEqual(launch.transcriptionEntries.count, 1)
        XCTAssertTrue(entry.isLive, "opening the window did not load the failed job")
        XCTAssertEqual(entry.state, .error)
        XCTAssertTrue(launch.canRetryJob(id: job.id))

        launch.removeFailedJob(id: job.id)
        await launch.queue.awaitSnapshotFlush()

        let relaunch = launchApp()
        relaunch.prepareTranscriptionsWindow()

        XCTAssertFalse(relaunch.transcriptionEntries.contains { $0.id == job.id }, "the removed job came back")
    }

    /// The menu offers Remove on a failed job it knows only from the history,
    /// before anything has started the pipeline. Dropping the record alone
    /// would leave the job in the snapshot, and it would be back, live, the
    /// next time the pipeline starts.
    func testRemovingBeforeThePipelineStartedKeepsTheJobGone() async throws {
        let job = try failedJobFromTheLastSession()
        let launch = launchApp()

        launch.removeFailedJob(id: job.id)
        await launch.queue.awaitSnapshotFlush()

        let relaunch = launchApp()
        relaunch.prepareTranscriptionsWindow()

        XCTAssertFalse(relaunch.transcriptionEntries.contains { $0.id == job.id }, "the removed job came back")
    }
}
