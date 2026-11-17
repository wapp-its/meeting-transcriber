@testable import MeetingTranscriber
import XCTest

/// After a re-run's commit point its job moves from this build's re-run file into
/// the queue's snapshot, two files with writers of their own: the re-run file keeps
/// it until the snapshot holding it has landed, and its Notion export starts only
/// then, so a quit at any moment leaves the job, and the export it owes, in one of
/// them, and a cold start runs that export once.
@MainActor
final class PipelineQueueRerunHandOffTests: XCTestCase {
    private typealias Fixture = PipelineQueueRerunFixture

    func testASnapshotWriteThatFailsAfterTheCommitKeepsTheJobInTheRerunFileAndAColdStartExportsOnce() async throws {
        // One row each: the queue's snapshot never takes the job before the quit, or
        // takes it later, so the cold start finds the job in both files.
        for landsLater in [false, true] {
            let row = landsLater ? "in both files" : "in the re-run file only"
            let fixture = try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_hand_off"))
            let log = RerunExportLog()
            let notion = RerunLoggingExporter.configuration("db-record", log)
            let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0, notion: notion), leavingTheQueue: true)
            let callsBefore = await log.calls.count
            let queue = fixture.makeQueue(completedJobLifetime: 0, notion: notion)
            let marker = try await commitWhileTheSnapshotFails(meeting, in: queue, fixture, row)

            var saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
            XCTAssertEqual(saved.map(\.id), [meeting.id], "\(row): the re-run file let go of the job before the snapshot took it")
            XCTAssertEqual(saved.first?.rerun?.marker.runID, marker.runID, row)
            let callsAtCommit = await log.calls.count
            XCTAssertEqual(callsAtCommit, callsBefore, "\(row): the export started before the snapshot took the job")
            if landsLater {
                queue.saveSnapshot()
                await PipelineSnapshotStore.flush(fixture.logDir)
                XCTAssertEqual(try snapshotHolds(meeting.id, fixture), [true], "\(row): test premise: the snapshot took the job")
            }
            // The quit: this process and every write it still owed are gone.
            queue.retire()
            await dropOwedWrites(fixture)

            // A cold start: the launch rows that need no queue, then the first queue.
            PipelineQueue.reconcileOrphanedReruns(in: fixture.store, logDir: fixture.logDir) { _ in false }
            let restarted = fixture.makeQueue(notion: notion)
            restarted.loadSnapshot()
            XCTAssertEqual(restarted.jobs.count { $0.id == meeting.id }, 1, "\(row): the meeting is not restored once")
            try await fixture.poll("\(row): the export") { restarted.job(withID: meeting.id)?.notionExportStatus == .completed }
            try await Task.sleep(for: .milliseconds(300))
            await PipelineSnapshotStore.flush(fixture.logDir)

            let calls = await log.calls.dropFirst(callsBefore)
            XCTAssertEqual(calls.map(\.page), ["page-1"], "\(row): not one update of the recorded page")
            XCTAssertEqual(calls.map(\.database), ["db-record"], row)
            let notes = try XCTUnwrap(fixture.finishedEntry(meeting.id)?.status.protocolPath, "\(row): the entry names no notes")
            XCTAssertEqual(FileIdentity.of(notes), marker.files.last { $0.role == .protocol }?.identity, "\(row): the entry is not the new result")
            saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
            XCTAssertTrue(saved.isEmpty, "\(row): the re-run file still holds the job")
            XCTAssertEqual(try snapshotHolds(meeting.id, fixture), [true], "\(row): the snapshot does not hold the finished job")
        }
    }

    /// A queue that replaces the one whose hand-off did not land (a folder change, a
    /// watch start) finishes it once the snapshot's write lands, and the export runs
    /// there once instead of waiting for the next launch.
    func testAQueueThatAdoptsTheJobsFinishesAHandOffTheReplacedQueueLeftAndExportsOnce() async throws {
        let fixture = try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_hand_off_adopted"))
        let log = RerunExportLog()
        let notion = RerunLoggingExporter.configuration("db-record", log)
        let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0, notion: notion), leavingTheQueue: true)
        let callsBefore = await log.calls.count
        let queue = fixture.makeQueue(completedJobLifetime: 0, notion: notion)
        _ = try await commitWhileTheSnapshotFails(meeting, in: queue, fixture, "adopted")
        let replacement = fixture.makeQueue(notion: notion)

        replacement.adoptJobs(of: queue)
        queue.retire()

        try await fixture.poll("the export") { replacement.job(withID: meeting.id)?.notionExportStatus == .completed }
        try await Task.sleep(for: .milliseconds(300))
        await PipelineSnapshotStore.flush(fixture.logDir)
        let calls = await log.calls.dropFirst(callsBefore)
        XCTAssertEqual(calls.map(\.page), ["page-1"], "not one update of the recorded page")
        XCTAssertEqual(calls.map(\.database), ["db-record"])
        let saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
        XCTAssertTrue(saved.isEmpty, "the re-run file still holds the job")
        XCTAssertEqual(try snapshotHolds(meeting.id, fixture), [true], "the snapshot does not hold the finished job")
    }

    /// A hand-off a quit interrupted gives the meeting's summary when a launch replays
    /// it, once, from the notes the re-run made current; the quit queue gave none
    /// (spec R5).
    func testAHandOffReplayedAtLaunchHandsTheNewNotesOnOnce() async throws {
        let fixture = try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_hand_off_summary"))
        let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0), leavingTheQueue: true)
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        var handedOn: [String] = []
        queue.onNotesSaved = { _, notes, _ in handedOn.append("quit queue \(notes)") }
        let marker = try await commitWhileTheSnapshotFails(meeting, in: queue, fixture, "summary")
        queue.retire()
        await dropOwedWrites(fixture)

        PipelineQueue.reconcileOrphanedReruns(in: fixture.store, logDir: fixture.logDir) { _ in false }
        let restarted = fixture.makeQueue()
        restarted.onNotesSaved = { id, notes, _ in
            guard case let .file(url) = notes else { return handedOn.append("text") }
            handedOn.append("\(id == meeting.id) \(FileIdentity.of(url.path) == marker.files.last { $0.role == .protocol }?.identity)")
        }
        restarted.loadSnapshot()
        try await fixture.poll("the replayed hand-off") { !handedOn.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        await PipelineSnapshotStore.flush(fixture.logDir)

        XCTAssertEqual(handedOn, ["true true"], "the new notes, once, from the replay")
    }

    // MARK: - Helpers

    /// `meeting`'s re-run in `queue` run to its commit point while no write of the
    /// queue's snapshot lands, its retry included: the snapshot's staging name is
    /// taken by a folder from the re-run's done state on. The re-run file's writes
    /// land. Returns the re-run's marker; the folder is gone again.
    private func commitWhileTheSnapshotFails(
        _ meeting: PipelineJob, in queue: PipelineQueue, _ fixture: Fixture, _ row: String,
    ) async throws -> MeetingFileRecord.RerunMarker {
        queue.isRegenerationRunning = { true }
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued, row)
        await queue.awaitProcessing()
        let marker = try fixture.marker(meeting.id, in: queue)
        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .done, "\(row): test premise: the re-run succeeded")
        await PipelineSnapshotStore.flush(fixture.logDir)
        let staging = fixture.logDir.appendingPathComponent(PipelineSnapshot.stagingFilename)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        queue.isRegenerationRunning = { false }
        try await fixture.poll("\(row): the commit") { (try? fixture.record(meeting.id).rerunNote?.committed) == true }
        try await Task.sleep(for: .milliseconds(300))
        await PipelineSnapshotStore.flush(fixture.logDir)
        XCTAssertNotNil(PipelineSnapshotStore.existing(for: fixture.logDir), "\(row): test premise: a write of the snapshot landed")
        XCTAssertEqual(try snapshotHolds(meeting.id, fixture), [], "\(row): test premise: the snapshot took the job")
        try FileManager.default.removeItem(at: staging)
        return marker
    }

    /// For each job of `id` in the queue's snapshot on disk, whether it is an
    /// ordinary job rather than a re-run.
    private func snapshotHolds(_ id: UUID, _ fixture: Fixture) throws -> [Bool] {
        try (PipelineSnapshot.load(from: fixture.logDir) ?? []).filter { $0.id == id }.map { $0.rerun == nil }
    }

    /// What a cold start finds: each file as its last write that landed left it,
    /// and no write owed, since the process that owed one is gone. A store still
    /// owing a write is handed the file's own contents, which lands and lets go.
    private func dropOwedWrites(_ fixture: Fixture) async {
        for name in [PipelineSnapshot.snapshotFilename, fixture.rerunFile.lastPathComponent]
            where PipelineSnapshotStore.existing(for: fixture.logDir, named: name) != nil {
            let onDisk = (try? PipelineSnapshot.load(from: fixture.logDir, named: name)) ?? []
            PipelineSnapshotStore.save(onDisk, to: fixture.logDir, named: name) { jobs, dir in
                try PipelineSnapshot.save(jobs, to: dir, named: name)
            }
        }
        await PipelineSnapshotStore.flush(fixture.logDir)
    }
}
