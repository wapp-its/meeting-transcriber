@testable import MeetingTranscriber
import XCTest

// MARK: - When the check runs, and what the queue tells it

extension RecordingRetentionControllerTests {
    /// Gives tasks already scheduled on the main actor their turn.
    private func settle() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }

    // MARK: - start and requestCheck

    /// `AppState` is built by many unit tests, so nothing happens before `start()`.
    func testNothingHappensBeforeStart() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let controller = bed.controller(interval: .milliseconds(5))

        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(controller.isChecking)
        XCTAssertEqual(bed.clockReads, 0)
        try bed.assertUntouched(record)
    }

    func testStartRunsOneCheckAndASecondStartNoMore() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let controller = bed.controller(interval: .seconds(3600))

        controller.start()
        controller.start()
        await waitFor { bed.clockReads > 0 && !controller.isChecking }
        await settle()

        XCTAssertEqual(bed.clockReads, 1)
        try bed.assertAudioWent(record)

        controller.start()
        await settle()
        XCTAssertEqual(bed.clockReads, 1, "a later start ran a check, and has a timer of its own")
    }

    /// A short interval stands in for the day: the clock moved past the due date
    /// while the app ran, with nothing else to set the check off.
    func testTheTimerChecksAgainOnceTheIntervalHasPassed() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        bed.clock = RetentionFixture.recorded
        let controller = bed.controller(interval: .milliseconds(10))
        controller.start()
        await waitFor { bed.clockReads > 0 }
        try bed.assertUntouched(record)

        bed.clock = RetentionFixture.longAfter
        await waitFor { (try? bed.current(record).audioDeletion) != nil }

        try bed.assertAudioWent(record, at: RetentionFixture.longAfter)
    }

    func testTwoRequestsInARowRunOneCheck() async throws {
        let bed = try makeRetentionCheckBed()
        let controller = bed.controller()

        controller.requestCheck()
        controller.requestCheck()
        await waitFor { bed.clockReads > 0 && !controller.isChecking }
        await settle()

        XCTAssertEqual(bed.clockReads, 1)
    }

    /// A request during a check is not lost, whatever it came for, and never starts a
    /// second check beside the first: the next meeting's files still go in the first.
    func testARequestDuringACheckRunsOneMoreAfterItAndNeverBesideIt() async throws {
        let bed = try makeRetentionCheckBed()
        try bed.meeting()
        try bed.meeting()
        try bed.meeting()
        let controller = bed.controller()
        var checksSeenByARemoval: Set<Int> = []
        bed.beforeRemoval = { _ in
            checksSeenByARemoval.insert(bed.clockReads)
            controller.requestCheck()
            controller.requestCheck()
        }

        controller.requestCheck()
        await waitFor { bed.clockReads > 0 && !controller.isChecking }
        await settle()
        await waitFor { !controller.isChecking }

        XCTAssertEqual(checksSeenByARemoval, [1])
        XCTAssertEqual(bed.removed.count, 18)
        XCTAssertEqual(bed.clockReads, 2)
    }

    func testTwoDirectChecksNeverRunBesideEachOther() async throws {
        let bed = try makeRetentionCheckBed()
        try bed.meeting()
        try bed.meeting()
        let controller = bed.controller()
        var checksSeenByARemoval: Set<Int> = []
        bed.beforeRemoval = { _ in checksSeenByARemoval.insert(bed.clockReads) }

        async let first: Void = controller.checkNow()
        async let second: Void = controller.checkNow()
        _ = await (first, second)
        await waitFor { !controller.isChecking }

        XCTAssertEqual(checksSeenByARemoval, [1])
        XCTAssertEqual(bed.removed.count, 12)
    }

    func testADelayedRequestWaitsForItsDelay() async throws {
        let bed = try makeRetentionCheckBed()
        let controller = bed.controller()

        controller.requestCheck(after: .seconds(1))
        await settle()
        XCTAssertEqual(bed.clockReads, 0, "ran before its delay")

        await waitFor { bed.clockReads > 0 && !controller.isChecking }
        XCTAssertEqual(bed.clockReads, 1)
    }

    /// The earliest one decides, and they all run as one check: a finished meeting
    /// does not wait for a setting's delay, nor does a later request postpone it.
    func testAnEarlierRequestReplacesALaterOneWithNoExtraRun() async throws {
        let bed = try makeRetentionCheckBed()
        let controller = bed.controller()

        controller.requestCheck(after: .milliseconds(100))
        controller.requestCheck()
        controller.requestCheck(after: .seconds(3600))
        await waitFor { bed.clockReads > 0 && !controller.isChecking }
        XCTAssertEqual(bed.clockReads, 1)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(bed.clockReads, 1, "the replaced request ran as well")
    }

    func testARequestWithNeverDeletesNothing() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        let record = try bed.meeting()
        let controller = bed.controller()

        controller.requestCheck()
        await waitFor { bed.clockReads > 0 && !controller.isChecking }

        try bed.assertUntouched(record)
    }

    // MARK: - A real queue

    @MainActor
    private struct QueueRun {
        let harness: MeetingDeletionHarness
        let queue: PipelineQueue
        let pipeline: PipelineController
        let retention: RecordingRetentionController

        func record(of job: PipelineJob) throws -> MeetingFileRecord {
            try harness.record(of: job)
        }

        func audioOnDisk(of job: PipelineJob) throws -> [String] {
            try harness.paths(of: job) { $0.role.isAudio }.filter { harness.isOnDisk($0) }
        }
    }

    /// A queue, its controller and the check, wired as `AppState` wires them.
    private func makeQueueRun(
        parksForNaming: Bool = false, notion: NotionExportConfiguration? = nil,
    ) throws -> QueueRun {
        let harness = try makeRetentionCheckBed().harness
        harness.settings.recordingRetention = .afterProtocol
        let queue = harness.makeQueue(parksForNaming: parksForNaming, notion: notion)
        let pipeline = harness.controller(queue: queue)
        let retention = RecordingRetentionController(pipeline: pipeline)
        pipeline.configureCallbacks()
        return QueueRun(harness: harness, queue: queue, pipeline: pipeline, retention: retention)
    }

    private func waitForDeletion(of job: PipelineJob, in run: QueueRun) async {
        await waitFor { run.harness.store.record(for: job.id)?.audioDeletion != nil }
    }

    /// Everything that was not audio stayed, and the date is the automatic one.
    private func assertAudioWent(_ job: PipelineJob, in run: QueueRun, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try run.record(of: job)
        XCTAssertEqual(
            record.audioDeletion, .init(kind: .automatic, at: MeetingDeletionHarness.now), "no automatic date", file: file, line: line,
        )
        XCTAssertEqual(try run.audioOnDisk(of: job), [], "audio stayed", file: file, line: line)
        XCTAssertTrue(record.files.contains(where: \.role.isAudio), "test premise", file: file, line: line)
        XCTAssertEqual(run.harness.fakeTrash.moved, [], "went to the Trash", file: file, line: line)
        for entry in record.files where !entry.role.isAudio && entry.state == .present {
            XCTAssertTrue(run.harness.isOnDisk(entry.path), "\(entry.role) went", file: file, line: line)
        }
    }

    func testRightAfterTheNotesDeletesAtOnceWhenAMeetingFinishes() async throws {
        let run = try makeQueueRun()
        let job = try run.harness.stagedRecording()

        run.queue.enqueue(job, origin: .recorded)
        await run.queue.awaitProcessing()
        await waitForDeletion(of: job, in: run)

        try assertAudioWent(job, in: run)
        XCTAssertTrue(try run.harness.isOnDisk(XCTUnwrap(run.record(of: job).files.first { $0.role == .protocol }?.path)))
    }

    /// The meeting parks for its names, which holds the audio, and naming finishes it.
    func testAMeetingWhoseSpeakersAreNamedLaterLosesItsAudioWhenTheyAre() async throws {
        let run = try makeQueueRun(parksForNaming: true)
        let job = try run.harness.stagedRecording()
        run.queue.enqueue(job, origin: .recorded)
        await run.queue.awaitProcessing()
        XCTAssertEqual(run.queue.job(withID: job.id)?.state, .speakerNamingPending, "test premise")

        await run.retention.checkNow()
        XCTAssertNil(try run.record(of: job).audioDeletion)
        XCTAssertFalse(try run.audioOnDisk(of: job).isEmpty, "parked for its names")

        run.queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))
        await run.queue.awaitProcessing()
        await waitForDeletion(of: job, in: run)

        try assertAudioWent(job, in: run)
    }

    #if !APPSTORE
        /// The notices end a noticed job's callback early, so a request chained before
        /// them never hears of it.
        func testAJobEndingWithALocalModelNoticeStillSetsOffACheck() async throws {
            let run = try makeQueueRun()
            let job = try run.harness.stagedRecording()
            run.queue.onLocalModelEvent?(.notWritten(.noModel, LocalModelNoticeMeeting(
                jobID: job.id, title: job.meetingTitle, folder: run.harness.outputDir, basename: "x",
                template: .builtIn, background: nil,
            )))

            run.queue.enqueue(job, origin: .recorded)
            await run.queue.awaitProcessing()
            await waitForDeletion(of: job, in: run)

            try assertAudioWent(job, in: run)
        }
    #endif

    private actor FailingExporter: NotionExporting {
        struct Failed: Error {}

        private let gate = AsyncGate()

        func release() async {
            await gate.open()
        }

        func exportMeeting( // swiftlint:disable:this function_parameter_count
            title _: String, date _: Date?, tags _: [String], markdown _: String,
            transcript _: String?, existingPageID _: String?,
            onPageCreated: @Sendable (NotionPageResult) async -> Void,
        ) async throws -> NotionPageResult {
            await onPageCreated(NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"))
            await gate.wait()
            throw Failed()
        }
    }

    /// Runs a meeting with its export held open: the audio stays through it, Markdown
    /// on disk or not, and the end of the export is what sets off the check.
    private func assertTheExportHoldsTheAudio(
        run: QueueRun, release: () async -> Void, file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        let job = try run.harness.stagedRecording()
        run.queue.enqueue(job, origin: .recorded)
        await waitFor { run.queue.job(withID: job.id)?.state == .done }
        XCTAssertEqual(run.queue.job(withID: job.id)?.notionExportStatus, .inProgress, "test premise", file: file, line: line)

        await run.retention.checkNow()

        XCTAssertNil(try run.record(of: job).audioDeletion, file: file, line: line)
        XCTAssertFalse(try run.audioOnDisk(of: job).isEmpty, "went while the export ran", file: file, line: line)

        await release()
        await run.queue.awaitNotionExports()
        await waitForDeletion(of: job, in: run)

        try assertAudioWent(job, in: run, file: file, line: line)
    }

    func testAnExportThatCompletesKeepsTheAudioUntilItEnds() async throws {
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let run = try makeQueueRun(notion: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"))
        try await assertTheExportHoldsTheAudio(run: run) { await exporter.release() }
    }

    /// A8: the local file goes with a completed export, and the page is the saved copy.
    func testAnExportThatCompletesAndRemovesTheMarkdownEndsInTheSameDeletion() async throws {
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let run = try makeQueueRun(notion: NotionExportConfiguration(
            exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
        ))
        try await assertTheExportHoldsTheAudio(run: run) { await exporter.release() }
        XCTAssertEqual(
            run.harness.store.records.first.flatMap { $0.files.first { $0.role == .protocol }?.state },
            .gone, "test premise: the local file was removed",
        )
    }

    /// A failed export whose Markdown is on disk counts as saved through that file.
    func testAnExportThatFailsWithItsMarkdownOnDiskEndsInADeletion() async throws {
        let exporter = FailingExporter()
        let run = try makeQueueRun(notion: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"))
        try await assertTheExportHoldsTheAudio(run: run) { await exporter.release() }
    }

    /// In a chain the first export's end flips the status to completed before the
    /// second begins, so the status alone would let the check through in between.
    func testAReExportChainedBehindAnotherHoldsTheAudioThroughTheGapBetweenThem() async throws {
        let older = GatedNotionExporter(pageCreation: .beforeRelease, pageID: "page-a")
        let newer = GatedNotionExporter(pageCreation: .beforeRelease, pageID: "page-b")
        let run = try makeQueueRun()
        let job = try run.harness.recordedMeeting()
        let jobID = run.queue.seedFinishedJobWithRunningExport(exporter: older, job: job, databaseID: "database-a")
        await waitFor { await older.startedExports == 1 }
        run.queue.queueReExport(exporter: newer, databaseID: "database-b", jobID: jobID)
        var seenAtTheFirstEnd: [LiveMeetingState?] = []
        let requestCheck = run.pipeline.onMeetingSettled
        run.pipeline.onMeetingSettled = {
            seenAtTheFirstEnd.append(run.pipeline.liveMeetingState(jobID: jobID))
            requestCheck?()
        }

        await older.release()
        await waitFor { await newer.startedExports == 1 }
        await run.retention.checkNow()

        XCTAssertEqual(seenAtTheFirstEnd.first??.notionExportRunning, true)
        XCTAssertNil(try run.record(of: job).audioDeletion)
        XCTAssertFalse(try run.audioOnDisk(of: job).isEmpty)

        await newer.release()
        await run.queue.awaitNotionExports()
        await waitForDeletion(of: job, in: run)

        try assertAudioWent(job, in: run)
    }

    // MARK: - The queue's answers

    func testAFinishedJobLeftInTheQueueIsListedAndSettled() throws {
        let run = try makeQueueRun()
        let queue = run.queue
        var job = try run.harness.recordedMeeting()
        job.state = .done
        queue.insertJobForTesting(job)

        XCTAssertEqual(run.pipeline.liveMeetingState(jobID: job.id), .init(state: .done, notionExportRunning: false))
        XCTAssertTrue(run.pipeline.listsMeeting(jobID: job.id))
    }

    func testAMeetingOnlyInTheFinishedListIsListedAndHasNoLiveState() throws {
        let run = try makeQueueRun()
        let job = try run.harness.recordedMeeting()

        XCTAssertNil(run.pipeline.liveMeetingState(jobID: job.id))
        XCTAssertTrue(run.pipeline.listsMeeting(jobID: job.id))
        XCTAssertFalse(run.pipeline.listsMeeting(jobID: UUID()))
    }

    // MARK: - The launch: a queue that has not read the snapshot

    /// A launch runs the check before anything builds the queue, which would resume
    /// the saved jobs. Those jobs are in the snapshot file only.
    private func bareRun() throws -> (harness: MeetingDeletionHarness, pipeline: PipelineController, retention: RecordingRetentionController) {
        let harness = try makeRetentionCheckBed().harness
        harness.settings.recordingRetention = .afterProtocol
        let pipeline = harness.controller()
        return (harness, pipeline, RecordingRetentionController(pipeline: pipeline))
    }

    /// The record says finished, the snapshot that the job was still at it: the crash
    /// window between the two writes. Its own Notion export can be running too.
    func testAJobStillBusyInAnUnreadSnapshotKeepsItsAudio() async throws {
        let cases: [(JobState, Bool)] = [
            (.generatingProtocol, false), (.speakerNamingPending, false), (.waiting, false), (.done, true),
        ]
        for (state, exporting) in cases {
            let (harness, pipeline, retention) = try bareRun()
            var job = try harness.recordedMeeting()
            job.state = state
            if exporting { job.beginNotionExport(speakerNames: [], localBackupSaved: true) }
            try PipelineSnapshot.save([job], to: harness.logDir)

            await retention.checkNow()

            XCTAssertEqual(pipeline.queue.jobs.count, 0, "the check built the queue's jobs")
            XCTAssertNil(try harness.record(of: job).audioDeletion, "\(state)")
            XCTAssertEqual(harness.deletedForGood, [], "\(state)")
        }
    }

    func testAJobFinishedInAnUnreadSnapshotLosesItsAudioAndTheFileStays() async throws {
        let (harness, pipeline, retention) = try bareRun()
        var job = try harness.recordedMeeting()
        job.state = .done
        try PipelineSnapshot.save([job], to: harness.logDir)

        await retention.checkNow()

        XCTAssertEqual(harness.deletedForGood.count, 3)
        XCTAssertNotNil(try harness.record(of: job).audioDeletion)
        XCTAssertEqual(pipeline.queue.jobs.count, 0)
        XCTAssertEqual(try PipelineSnapshot.load(from: harness.logDir)?.map(\.id), [job.id], "the snapshot is not the check's to write")
    }

    /// Not knowing what the queue has is no reason to delete or to forget.
    func testAnUnreadableSnapshotKeepsTheAudioAndTheRecord() async throws {
        let (harness, _, retention) = try bareRun()
        let job = try harness.recordedMeeting()
        let snapshot = harness.logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        try Data("not json".utf8).write(to: snapshot)
        let empty = makeEmptyRecord(in: harness)

        await retention.checkNow()

        XCTAssertEqual(harness.deletedForGood, [])
        XCTAssertNil(try harness.record(of: job).audioDeletion)
        XCTAssertNotNil(harness.store.record(for: empty), "may have a row in the unreadable file")
    }

    /// Having an engine says the queue tried, not that it read anything: it stays
    /// empty when the file does not read. So the job may still be in there, also once
    /// another queue has taken over from that one.
    func testASnapshotTheQueueCouldNotReadKeepsTheAudioAndTheRecord() async throws {
        let (harness, pipeline, retention) = try bareRun()
        let job = try harness.recordedMeeting()
        let snapshot = harness.logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        try Data("not json".utf8).write(to: snapshot)
        let empty = makeEmptyRecord(in: harness)
        pipeline.activate { MockEngine() }

        for step in ["the first queue", "the queue after it"] {
            pipeline.rebuild()
            XCTAssertNotNil(pipeline.queue.engine, "test premise")
            XCTAssertEqual(pipeline.queue.jobs.count, 0, "test premise")

            await retention.checkNow()

            XCTAssertEqual(pipeline.liveMeetingState(jobID: job.id), .init(state: .waiting, notionExportRunning: false), step)
            XCTAssertTrue(pipeline.listsMeeting(jobID: empty), step)
            XCTAssertEqual(harness.deletedForGood, [], step)
            XCTAssertNil(try harness.record(of: job).audioDeletion, step)
            XCTAssertNotNil(harness.store.record(for: empty), "\(step): may have a row in the unreadable file")
        }
    }

    /// A queue that read its snapshot is what the answers go by, so a meeting it does
    /// not hold has no live state and no row, whatever the file says from then on.
    func testAQueueThatReadItsSnapshotAnswersForItsMeetings() async throws {
        let (harness, pipeline, _) = try bareRun()
        let job = try harness.recordedMeeting()
        try PipelineSnapshot.save([], to: harness.logDir)
        let empty = makeEmptyRecord(in: harness)
        pipeline.activate { MockEngine() }

        pipeline.rebuild()
        await pipeline.queue.awaitSnapshotFlush()
        try Data("not json".utf8).write(to: harness.logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        XCTAssertNil(pipeline.liveMeetingState(jobID: job.id))
        XCTAssertFalse(pipeline.listsMeeting(jobID: empty))
    }

    /// Its names are lost, so the restore finishes it, before the queue has any
    /// callbacks. Nothing else would tell the check until the next day.
    func testAJobTheRestoreFinishesSetsOffACheck() async throws {
        let (harness, pipeline, retention) = try bareRun()
        var job = try harness.recordedMeeting()
        job.state = .speakerNamingPending
        try PipelineSnapshot.save([job], to: harness.logDir)

        await retention.checkNow()
        XCTAssertEqual(harness.deletedForGood, [], "parked for its names")

        pipeline.activate { MockEngine() }
        pipeline.rebuild()
        XCTAssertEqual(pipeline.queue.job(withID: job.id)?.state, .done, "test premise")

        await waitFor { harness.store.record(for: job.id)?.audioDeletion != nil }

        XCTAssertEqual(harness.deletedForGood.count, 3)
    }

    func testAJobInAnUnreadSnapshotKeepsItsEmptyRecord() async throws {
        let (harness, _, retention) = try bareRun()
        let job = PipelineJob(
            meetingTitle: "Saved", appName: "Teams", mixPath: harness.recordings.appendingPathComponent("x.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let empty = makeEmptyRecord(in: harness, id: job.id)
        try PipelineSnapshot.save([job], to: harness.logDir)

        await retention.checkNow()

        XCTAssertNotNil(harness.store.record(for: empty))
    }

    func testAnEmptyRecordWithNoRowAnywhereGoesAtLaunch() async throws {
        let (harness, _, retention) = try bareRun()
        let empty = makeEmptyRecord(in: harness)

        await retention.checkNow()

        XCTAssertNil(harness.store.record(for: empty))
    }

    /// A record listing one file that is gone, for a meeting with no row.
    private func makeEmptyRecord(in harness: MeetingDeletionHarness, id: UUID = UUID()) -> UUID {
        let file = MeetingFile(
            role: .mix, path: harness.recordings.appendingPathComponent("\(id.uuidString).wav").path,
            identity: nil, owned: true, state: .gone,
        )
        XCTAssertTrue(harness.store.create(MeetingFileRecord(
            jobID: id, origin: .recorded, recordingDate: nil, files: [file], outcome: .leftUnfinished,
        )), "test premise")
        return id
    }

    // MARK: - AppState

    /// `AppState` builds it and leaves it alone; the launch `.task` starts it.
    func testAppStateBuildsTheCheckAndOnlyStartRunsIt() async throws {
        let state = try makeIsolatedAppState()
        let pipeline = state.pipeline
        pipeline.settings.recordingRetention = .afterProtocol
        let store = pipeline.meetingFileStore
        let folder = try makeTempDirectory(prefix: "retention_appstate")
        let names = ["a_mix.wav", "a.md"]
        let urls = names.map { folder.appendingPathComponent($0) }
        for url in urls {
            try Data("x".utf8).write(to: url)
        }
        let record = MeetingFileRecord(
            jobID: UUID(), origin: .recorded, recordingDate: RetentionFixture.recorded,
            files: [MeetingFile(role: .mix, url: urls[0], owned: true), MeetingFile(role: .protocol, url: urls[1], owned: true)],
            outcome: .finished(protocolExpected: true), createdBy: store.bundleID,
        )
        XCTAssertTrue(store.create(record), "test premise")

        await settle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path), "ran before start")

        state.recordingRetention.start()
        await waitFor { store.record(for: record.jobID)?.audioDeletion != nil }

        XCTAssertEqual(store.record(for: record.jobID)?.audioDeletion?.kind, .automatic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[1].path))
    }
}
