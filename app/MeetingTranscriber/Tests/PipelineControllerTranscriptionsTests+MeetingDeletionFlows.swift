@testable import MeetingTranscriber
import XCTest

// MARK: - Deleting after a real run, shared paths and the launch reconcile

/// What the other tests' prepared meetings cannot show: the files a real run left
/// (the app rewrites a transcript when speakers are named, and must not refuse its
/// own file afterwards), a Notion export running, a path two meetings list, and a
/// deletion a crash interrupted.
extension PipelineControllerTranscriptionsTests {
    private struct Refused: Error {}

    // MARK: - After a real run

    /// A recorded meeting run through the queue and parked for its speaker names.
    private func parkedMeeting(
        _ harness: MeetingDeletionHarness,
    ) async throws -> (controller: PipelineController, queue: PipelineQueue, job: PipelineJob) {
        let queue = harness.makeQueue(parksForNaming: true)
        let job = try harness.stagedRecording()
        queue.enqueue(job, origin: .recorded)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: job.id)?.state, .speakerNamingPending, "test premise")
        return (harness.controller(queue: queue), queue, job)
    }

    /// Everything the run left must go, and nothing may read as replaced. The mover
    /// is the only thing removing a file here, so a sidecar the record never listed
    /// would stay behind for good.
    private func assertMovesToTheTrashCompletely(
        _ job: PipelineJob, _ harness: MeetingDeletionHarness, _ controller: PipelineController,
        file: StaticString = #filePath, line: UInt = #line,
    ) throws {
        let listed = try harness.paths(of: job) { $0.state != .gone }
        XCTAssertTrue(listed.contains { $0.hasSuffix(".txt") }, "test premise: a transcript is listed", file: file, line: line)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id), file: file, line: line)

        XCTAssertNil(harness.store.record(for: job.id)?.incomplete?.reason, file: file, line: line)
        XCTAssertNil(harness.store.record(for: job.id), "the deletion did not complete", file: file, line: line)
        XCTAssertEqual(listed.filter(harness.isOnDisk), [], file: file, line: line)
        XCTAssertEqual(harness.fakeTrash.moved.count, listed.count, file: file, line: line)
        let left = try FileManager.default.subpathsOfDirectory(atPath: harness.outputDir.path).filter { path in
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: harness.outputDir.appendingPathComponent(path).path, isDirectory: &isFolder)
            return !isFolder.boolValue
        }
        XCTAssertEqual(left, [], "a file the record did not list stayed behind", file: file, line: line)
    }

    func testAMeetingWhoseTranscriptWasRewrittenOnConfirmedNamesMovesCompletely() async throws {
        let harness = try makeDeletionHarness()
        let (controller, queue, job) = try await parkedMeeting(harness)

        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))
        await waitFor(queue.job(withID: job.id)?.state == .done, timeout: .seconds(10))

        try assertMovesToTheTrashCompletely(job, harness, controller)
    }

    func testAMeetingWithALateRediarizationMovesCompletely() async throws {
        let harness = try makeDeletionHarness()
        let (controller, queue, job) = try await parkedMeeting(harness)

        XCTAssertNil(queue.completeSpeakerNaming(jobID: job.id, result: .rerun(2)))
        await waitFor(queue.job(withID: job.id)?.state == .speakerNamingPending, timeout: .seconds(10))
        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))
        await waitFor(queue.job(withID: job.id)?.state == .done, timeout: .seconds(10))

        try assertMovesToTheTrashCompletely(job, harness, controller)
    }

    // MARK: - Notion

    /// The export stays in charge of the job until it ends. Once it has, the page
    /// is simply left where it is: nothing in this path talks to Notion.
    func testAMeetingWhoseExportRunsIsLeftUntouchedAndAMeetingWithAPageMakesNoNotionCall() async throws {
        let harness = try makeDeletionHarness()
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let queue = harness.makeQueue(notion: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"))
        let controller = harness.controller(queue: queue)
        let job = try harness.stagedRecording()
        queue.enqueue(job, origin: .recorded)
        await waitFor { queue.job(withID: job.id)?.notionPageID != nil }
        XCTAssertEqual(queue.job(withID: job.id)?.notionExportStatus, .inProgress, "test premise")
        let before = try harness.record(of: job)

        XCTAssertFalse(controller.moveMeetingToTrash(jobID: job.id))
        XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id))

        XCTAssertEqual(try harness.record(of: job), before)
        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertTrue(queue.jobs.contains { $0.id == job.id })

        await exporter.release()
        await queue.awaitProcessing()
        await queue.awaitNotionExports()
        XCTAssertEqual(queue.job(withID: job.id)?.notionExportStatus, .completed, "test premise")

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertNil(harness.store.record(for: job.id))
        let exports = await exporter.startedExports
        XCTAssertEqual(exports, 1, "the deletion called Notion")
    }

    /// A failed export holds nothing back (A9), and its job is one the queue keeps
    /// for good, so the removal has to take it out too.
    func testAMeetingWithAFailedExportMovesAndLeavesTheQueue() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        var job = try harness.recordedMeeting()
        job.beginNotionExport(speakerNames: [], localBackupSaved: true)
        job.finishNotionExport(succeeded: false)
        controller.queue.insertJobForTesting(job)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertFalse(controller.queue.jobs.contains { $0.id == job.id })
        XCTAssertNil(harness.store.record(for: job.id))
    }

    // MARK: - A job only the snapshot knows

    /// The record says finished, and only the snapshot knows better. An action has
    /// to read it first, or the menu of a window that has not opened yet could act
    /// on a meeting that is not finished after all.
    func testAnActionAsksAboutAJobStillOnlyInTheSnapshot() throws {
        let harness = try makeDeletionHarness()
        var job = try harness.recordedMeeting()
        job.state = .error
        try FileManager.default.createDirectory(at: harness.logDir, withIntermediateDirectories: true)
        try PipelineSnapshot.save([job], to: harness.logDir)
        let controller = harness.controller()
        controller.activate { MockEngine() }
        let before = try harness.record(of: job)

        XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id))

        XCTAssertEqual(try harness.record(of: job), before)
        XCTAssertEqual(harness.fakeTrash.moved, [])
    }

    /// A done job with a failed export survives in the snapshot, so it would come
    /// back the next time the queue is built.
    func testMoveMeetingKeepsAJobFromTheSnapshotGone() async throws {
        let harness = try makeDeletionHarness()
        var job = try harness.recordedMeeting()
        job.beginNotionExport(speakerNames: [], localBackupSaved: true)
        job.finishNotionExport(succeeded: false)
        try FileManager.default.createDirectory(at: harness.logDir, withIntermediateDirectories: true)
        try PipelineSnapshot.save([job], to: harness.logDir)
        let controller = harness.controller()
        controller.activate { MockEngine() }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))
        await controller.queue.awaitSnapshotFlush()

        XCTAssertNil(harness.store.record(for: job.id))
        let saved = try XCTUnwrap(PipelineSnapshot.load(from: harness.logDir))
        XCTAssertFalse(saved.contains { $0.id == job.id }, "the job would come back")
    }

    // MARK: - Shared paths

    /// A recorded meeting whose audio was later imported as its own meeting, the
    /// realistic way one path gets into two records. The import never owns it, so
    /// whichever goes first, the file stays until no other record lists it.
    func testASharedPathGoesWithTheLastMeetingWhenTheRecordingIsDeletedFirst() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let recording = try harness.recordedMeeting()
        let shared = try XCTUnwrap(recording.mixPath)
        let imported = try harness.importedMeeting(source: shared)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: recording.id))

        XCTAssertTrue(harness.isOnDisk(shared.path), "a path another record lists went")
        let blocked = try harness.record(of: recording)
        XCTAssertEqual(blocked.incomplete?.reason, "1 file is also listed by another meeting")
        XCTAssertEqual(blocked.incomplete?.paths, [MeetingFile.resolvedPath(shared)])
        XCTAssertEqual(blocked.files.first { $0.role == .mix }?.state, .present, "it stays listed")

        XCTAssertTrue(controller.retryDeletion(jobID: recording.id))
        XCTAssertTrue(harness.isOnDisk(shared.path), "a retry while it is still shared removed it")

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: imported.id))
        XCTAssertTrue(harness.isOnDisk(shared.path), "the import took a file it does not own")

        XCTAssertTrue(controller.retryDeletion(jobID: recording.id))
        XCTAssertFalse(harness.isOnDisk(shared.path))
        XCTAssertNil(harness.store.record(for: recording.id))
    }

    func testASharedPathGoesWithTheLastMeetingWhenTheImportIsDeletedFirst() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let recording = try harness.recordedMeeting()
        let shared = try XCTUnwrap(recording.mixPath)
        let imported = try harness.importedMeeting(source: shared)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: imported.id))
        XCTAssertTrue(harness.isOnDisk(shared.path), "the import took a file it does not own")

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: recording.id))

        XCTAssertFalse(harness.isOnDisk(shared.path))
        XCTAssertNil(harness.store.record(for: recording.id))
    }

    func testMoveAudioIsBlockedTheSameWay() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let recording = try harness.recordedMeeting()
        let shared = try XCTUnwrap(recording.mixPath)
        let imported = try harness.importedMeeting(source: shared)

        XCTAssertTrue(controller.moveAudioToTrash(jobID: recording.id))

        XCTAssertTrue(harness.isOnDisk(shared.path))
        XCTAssertEqual(try harness.record(of: recording).incomplete?.kind, .audioToTrash)
        XCTAssertNil(try harness.record(of: recording).audioDeletion)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: imported.id))
        XCTAssertTrue(controller.retryDeletion(jobID: recording.id))

        XCTAssertFalse(harness.isOnDisk(shared.path))
        XCTAssertEqual(try harness.record(of: recording).audioDeletion, .init(kind: .manual, at: MeetingDeletionHarness.now))
    }

    // MARK: - Launch reconcile

    private func noteInterruptedDeletion(
        of job: PipelineJob, kind: MeetingFileRecord.DeletionKind, _ harness: MeetingDeletionHarness,
    ) throws {
        let paths = try harness.paths(of: job)
        // No process has this ID, so the real liveness check answers.
        let dead = DeletionProcess(pid: .max, launchTime: .distantPast)
        harness.store.update(jobID: job.id) { $0.pending = .init(kind: kind, paths: paths, process: dead) }
    }

    /// A launch reconciles without being asked, and a manual deletion it finds
    /// half done is offered as a retry of the same kind.
    func testALaunchTurnsAnInterruptedDeletionIntoARetry() throws {
        let harness = try makeDeletionHarness()
        let job = try harness.recordedMeeting()
        try noteInterruptedDeletion(of: job, kind: .meetingToTrash, harness)
        let controller = harness.controller()

        controller.activate { MockEngine() }

        let record = try harness.record(of: job)
        XCTAssertNil(record.pending)
        XCTAssertEqual(record.incomplete?.kind, .meetingToTrash)
        XCTAssertNotNil(harness.history.lookup(jobID: job.id), "files are left, so the row stays")
    }

    /// Nothing was left to move, so it ends as the action would have. The job is
    /// only in the unread snapshot here, because a failed export keeps it there,
    /// and it must not come back. The queue is not built for this, since that would
    /// resume the waiting job beside it, and it must not write its empty list over
    /// the snapshot either: `removeJob` on a bare queue does exactly that.
    func testALaunchFinishesAnInterruptedMeetingDeletionWithNothingLeft() throws {
        let harness = try makeDeletionHarness()
        var finished = try harness.recordedMeeting()
        finished.beginNotionExport(speakerNames: [], localBackupSaved: true)
        finished.finishNotionExport(succeeded: false)
        let files = try harness.paths(of: finished)
        for path in files {
            try FileManager.default.removeItem(atPath: path)
        }
        try noteInterruptedDeletion(of: finished, kind: .meetingToTrash, harness)
        let waiting = try PipelineJob(
            meetingTitle: "Next", appName: "Teams",
            mixPath: createTestAudioFile(in: harness.recordings), appPath: nil, micPath: nil, micDelay: 0,
        )
        try FileManager.default.createDirectory(at: harness.logDir, withIntermediateDirectories: true)
        try PipelineSnapshot.save([finished, waiting], to: harness.logDir)
        let controller = harness.controller()

        controller.activate { MockEngine() }

        XCTAssertNil(harness.store.record(for: finished.id))
        XCTAssertNil(harness.history.lookup(jobID: finished.id))
        XCTAssertNil(controller.queue.engine, "the queue was built, which resumes the waiting job")
        let saved = try XCTUnwrap(PipelineSnapshot.load(from: harness.logDir))
        XCTAssertEqual(saved.map(\.id), [waiting.id], "the snapshot lost the wrong job")
    }

    /// A retry after the launch is the ordinary action again.
    func testARetryAfterALaunchCompletesTheInterruptedDeletion() throws {
        let harness = try makeDeletionHarness()
        let job = try harness.recordedMeeting()
        let first = try XCTUnwrap(job.mixPath)
        try FileManager.default.removeItem(at: first)
        try noteInterruptedDeletion(of: job, kind: .audioToTrash, harness)
        let controller = harness.controller()
        controller.activate { MockEngine() }
        XCTAssertEqual(try harness.record(of: job).incomplete?.kind, .audioToTrash, "test premise")

        XCTAssertTrue(controller.retryDeletion(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, [job.appPath, job.micPath].compactMap { $0?.lastPathComponent })
        XCTAssertEqual(try harness.record(of: job).audioDeletion, .init(kind: .manual, at: MeetingDeletionHarness.now))
        XCTAssertNil(try harness.record(of: job).incomplete)
    }

    /// In the sandboxed build a probe outside the scope reads every file as out of
    /// reach, which would call a finished deletion unfinished.
    func testALaunchReconcilesInsideTheScopeOfTheChosenFolderAndNotWithoutAPendingDeletion() throws {
        let harness = try makeDeletionHarness()
        harness.settings.setCustomOutputDir(harness.outputDir)
        let job = try harness.recordedMeeting()
        let idle = harness.controller()

        idle.activate { MockEngine() }
        XCTAssertEqual(harness.scopes.opened, [], "a launch with nothing to reconcile opened the folder")

        try noteInterruptedDeletion(of: job, kind: .audioToTrash, harness)
        harness.controller().reconcileInterruptedDeletions { _ in false }

        XCTAssertEqual(harness.scopes.opened.count, 1)
        XCTAssertEqual(harness.scopes.closed.count, 1)
    }
}
