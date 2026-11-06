@testable import MeetingTranscriber
import os
import XCTest

// MARK: - The end of a deletion, when a write fails

/// A deletion ends in writes of its own after the files have gone. The pending
/// mark is what a launch repairs from, so it stays until the rest is on disk: a
/// failed write or a crash in between must not bring a meeting back with no way to
/// finish it, and nothing here may remove a file the mover did not check.
extension PipelineControllerTranscriptionsTests {
    /// A done job the queue keeps for good, so a snapshot listing it brings it back.
    private func meetingWithAFailedExport(in harness: MeetingDeletionHarness) throws -> PipelineJob {
        var job = try harness.recordedMeeting()
        job.beginNotionExport(speakerNames: [], localBackupSaved: true)
        job.finishNotionExport(succeeded: false)
        return job
    }

    /// What the snapshot file says about `job`.
    private func snapshotLists(_ job: PipelineJob, _ harness: MeetingDeletionHarness) throws -> Bool {
        try XCTUnwrap(PipelineSnapshot.load(from: harness.logDir)).contains { $0.id == job.id }
    }

    // MARK: - No file goes by name

    /// The record knows these files went, so the mover has nothing to check, and
    /// what has since taken their path is not the meeting's. The queue's own
    /// cleanup removes by name, folders with their content included.
    func testMoveMeetingLeavesWhatNowSitsAtASidecarPathTheRecordSawGo() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        var job = try harness.recordedMeeting()
        job.namingSlug = "budget"
        job.recordSidecarOutputDir(harness.outputDir)
        controller.queue.insertJobForTesting(job)
        let roles: [(MeetingFile.Role, String)] = [
            (.segments, SpeakerNamingStore.segmentsSuffix),
            (.naming, SpeakerNamingStore.namingJSONSuffix),
            (.mix16k, SpeakerNamingStore.mixSuffix),
        ]
        var inside: [URL] = []
        for (role, suffix) in roles {
            let folder = harness.recordings.appendingPathComponent("budget\(suffix)", isDirectory: true)
            harness.store.update(jobID: job.id) { record in
                var entry = MeetingFile(role: role, url: folder, owned: true)
                entry.state = .gone
                record.files.append(entry)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = folder.appendingPathComponent("kept.txt")
            try Data("kept".utf8).write(to: kept)
            inside.append(kept)
        }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertFalse(controller.queue.jobs.contains { $0.id == job.id }, "test premise: the queue job went")
        for file in inside {
            XCTAssertTrue(harness.isOnDisk(file.path), "\(file.deletingLastPathComponent().lastPathComponent) was removed by name")
        }
    }

    /// The files are the mover's, the memory is still the queue's: naming data kept
    /// for a job that is gone would never be dropped.
    func testMoveMeetingForgetsTheNamingDataOfItsJob() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        controller.queue.insertJobForTesting(job)
        controller.queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id, meetingTitle: job.meetingTitle, mapping: ["SPEAKER_0": "SPEAKER_0"],
            speakingTimes: ["SPEAKER_0": 5], embeddings: [:], audioPath: nil, segments: [],
            participants: [], isDualSource: false,
        )

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertNil(controller.queue.speakerNamingDataByJob[job.id])
    }

    // MARK: - The snapshot

    /// A crash while the write is on its way finds the old snapshot, which lists the
    /// job. Without the mark there would be nothing to take it out again.
    func testTheRecordStaysUntilTheSnapshotWithoutTheMeetingIsOnDisk() async throws {
        let harness = try makeDeletionHarness()
        let release = DispatchSemaphore(value: 0)
        let writer: @Sendable ([PipelineJob], URL) throws -> Void = { jobs, dir in
            release.wait()
            try PipelineSnapshot.save(jobs, to: dir)
        }
        let queue = harness.makeQueue(snapshotWriter: writer)
        let controller = harness.controller(queue: queue)
        let job = try meetingWithAFailedExport(in: harness)
        queue.insertJobForTesting(job)
        try FileManager.default.createDirectory(at: harness.logDir, withIntermediateDirectories: true)
        try PipelineSnapshot.save([job], to: harness.logDir)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertFalse(queue.jobs.contains { $0.id == job.id }, "the row must leave at once")
        XCTAssertNil(harness.history.lookup(jobID: job.id), "the row must leave at once")
        XCTAssertEqual(try harness.record(of: job).pending?.kind, .meetingToTrash, "a crash now leaves nothing to reconcile")
        XCTAssertTrue(try snapshotLists(job, harness), "test premise: the write has not landed")

        release.signal()
        await queue.awaitSnapshotFlush()
        await waitFor(harness.store.record(for: job.id) == nil, timeout: .seconds(5))

        XCTAssertNil(harness.store.record(for: job.id), "the record stayed after the write landed")
        XCTAssertFalse(try snapshotLists(job, harness))
    }

    func testASnapshotWriteThatFailsKeepsTheMarkAndTheNextLaunchFinishes() async throws {
        let harness = try makeDeletionHarness()
        let failing = OSAllocatedUnfairLock(initialState: true)
        let writer: @Sendable ([PipelineJob], URL) throws -> Void = { jobs, dir in
            if failing.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            try PipelineSnapshot.save(jobs, to: dir)
        }
        let queue = harness.makeQueue(snapshotWriter: writer)
        let controller = harness.controller(queue: queue)
        let job = try meetingWithAFailedExport(in: harness)
        queue.insertJobForTesting(job)
        try FileManager.default.createDirectory(at: harness.logDir, withIntermediateDirectories: true)
        try PipelineSnapshot.save([job], to: harness.logDir)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))
        await queue.awaitSnapshotFlush()
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        XCTAssertTrue(queue.isSnapshotWorkerActive, "test premise: the write is still owed")
        XCTAssertEqual(try harness.record(of: job).pending?.kind, .meetingToTrash, "the record went with its job still in the snapshot")
        XCTAssertTrue(try snapshotLists(job, harness))

        // The process ends here. A store this test keeps alive would not exist in
        // the next one, and the file is what the failed write left.
        failing.withLock { $0 = false }
        queue.saveSnapshot()
        await queue.awaitSnapshotFlush()
        try PipelineSnapshot.save([job], to: harness.logDir)
        harness.controller().reconcileInterruptedDeletions { _ in false }

        XCTAssertNil(harness.store.record(for: job.id))
        XCTAssertNil(harness.history.lookup(jobID: job.id))
        XCTAssertFalse(try snapshotLists(job, harness), "the job would come back")
    }

    // MARK: - The history

    /// The row would come back from the file after a restart, with no record, and
    /// every action refuses a row without one.
    func testAHistoryWriteThatFailsKeepsTheMarkAndTheNextLaunchFinishes() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let historyPath = harness.logDir.appendingPathComponent("terminal_jobs.json")
        // Its staging file cannot be written while a folder sits there.
        let staging = harness.logDir.appendingPathComponent("terminal_jobs.json.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertNotNil(TerminalJobStore(path: historyPath).lookup(jobID: job.id), "test premise: the write failed")
        XCTAssertEqual(try harness.record(of: job).pending?.kind, .meetingToTrash, "the record went with its row still on disk")

        try FileManager.default.removeItem(at: staging)
        let nextLaunch = TerminalJobStore(path: historyPath)
        harness.controller(history: nextLaunch).reconcileInterruptedDeletions { _ in false }

        XCTAssertNil(harness.store.record(for: job.id))
        XCTAssertNil(TerminalJobStore(path: historyPath).lookup(jobID: job.id), "the row would come back")
    }
}
