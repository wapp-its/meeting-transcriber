@testable import MeetingTranscriber
import XCTest

/// The record of a meeting nothing is left of goes, and only then; and what the
/// queue answers for a meeting before the window or the pruner acts on it.
@MainActor
final class MeetingRecordPrunerTests: XCTestCase {
    /// Gives tasks already scheduled on the main actor their turn.
    private func settle() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }

    private func makeHarness() throws -> MeetingDeletionHarness {
        let suite = "MeetingRecordPrunerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let root = try makeTempDirectory(prefix: "record_pruner")
        let settings = AppSettings(defaults: defaults, defaultOutputDir: root.appendingPathComponent("output", isDirectory: true))
        return try MeetingDeletionHarness(root: root, settings: settings)
    }

    /// A finished meeting with every file deleted behind the app, and no row.
    private func emptyMeeting(
        _ harness: MeetingDeletionHarness, jobID: UUID = UUID(), _ change: (inout MeetingFileRecord) -> Void = { _ in },
    ) throws -> MeetingFileRecord {
        let stem = UUID().uuidString.prefix(8)
        let files = try ["mix.wav", "txt", "md"].enumerated().map { index, name in
            let url = harness.recordings.appendingPathComponent("\(stem)_\(name)")
            try Data(name.utf8).write(to: url)
            return MeetingFile(role: [MeetingFile.Role.mix, .transcript, .protocol][index], url: url, owned: true)
        }
        var record = MeetingFileRecord(
            jobID: jobID, origin: .recorded, recordingDate: RetentionFixture.recorded, files: files,
            outcome: .leftUnfinished, createdBy: harness.store.bundleID,
        )
        change(&record)
        XCTAssertTrue(harness.store.create(record), "test premise")
        for file in files {
            try FileManager.default.removeItem(atPath: file.path)
        }
        return record
    }

    func testARecordWithNothingLeftGoesOnceItsRowIsGone() async throws {
        let harness = try makeHarness()
        let record = try emptyMeeting(harness)
        let rows = Rows()
        rows.listed = [record.jobID]
        let pruner = MeetingRecordPruner(store: harness.store) { rows.listed.contains($0) }

        await pruner.prune()
        XCTAssertNotNil(harness.store.record(for: record.jobID), "its row is still listed")

        rows.listed = []
        await pruner.prune()
        XCTAssertNil(harness.store.record(for: record.jobID))
    }

    func testARecordStaysWhileAnythingOfItMayStillExist() async throws {
        let harness = try makeHarness()
        let present = harness.recordings.appendingPathComponent("back-from-the-trash.md")
        try Data("x".utf8).write(to: present)
        // A file marked gone that came back from the Trash.
        let restored = try emptyMeeting(harness) { record in
            var file = MeetingFile(role: .protocol, url: present, owned: true)
            file.state = .gone
            record.files.append(file)
        }
        let pending = try emptyMeeting(harness) { $0.pending = .init(kind: .audioToTrash, paths: []) }
        // Another build may be between moving a file and listing its new path.
        let inProgress = try emptyMeeting(harness) { $0.outcome = .inProgress }
        let pruner = MeetingRecordPruner(store: harness.store) { _ in false }

        await pruner.prune()

        XCTAssertNotNil(harness.store.record(for: restored.jobID), "a file is back")
        XCTAssertNotNil(harness.store.record(for: pending.jobID), "a deletion is under way")
        XCTAssertNotNil(harness.store.record(for: inProgress.jobID), "in progress")
    }

    /// The probe suspends, so the row is asked again after it: before the pass,
    /// for the record, and once the disk has answered.
    func testARowThatAppearsWhileTheDiskIsAskedKeepsTheRecord() async throws {
        let harness = try makeHarness()
        let record = try emptyMeeting(harness)
        let rows = Rows()
        let pruner = MeetingRecordPruner(store: harness.store) { id in
            guard id == record.jobID else { return false }
            rows.lookups += 1
            return rows.lookups >= 3
        }

        await pruner.prune()

        XCTAssertNotNil(harness.store.record(for: record.jobID))
    }

    /// Under the lock, so another build's change after the pass's read survives.
    func testRemovingARecordIsRefusedWhenItChangedSinceItWasRead() throws {
        let harness = try makeHarness()
        let read = try emptyMeeting(harness)
        let otherBuild = MeetingFileStore(path: harness.recordPath)
        otherBuild.update(jobID: read.jobID) { $0.keep = true }

        XCTAssertFalse(harness.store.remove(unchanged: read))
        XCTAssertNotNil(harness.store.record(for: read.jobID))

        harness.store.reload()
        XCTAssertTrue(try harness.store.remove(unchanged: XCTUnwrap(harness.store.record(for: read.jobID))))
        XCTAssertNil(harness.store.record(for: read.jobID))
    }

    // MARK: - What the queue answers

    func testAFinishedJobLeftInTheQueueIsListedAndSettled() throws {
        let harness = try makeHarness()
        let queue = harness.makeQueue()
        let pipeline = harness.controller(queue: queue)
        var job = try harness.recordedMeeting()
        job.state = .done
        queue.insertJobForTesting(job)

        XCTAssertEqual(pipeline.liveMeetingState(jobID: job.id), .init(state: .done, notionExportRunning: false))
        XCTAssertTrue(pipeline.listsMeeting(jobID: job.id))
    }

    func testAMeetingOnlyInTheFinishedListIsListedAndHasNoLiveState() throws {
        let harness = try makeHarness()
        let pipeline = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()

        XCTAssertNil(pipeline.liveMeetingState(jobID: job.id))
        XCTAssertTrue(pipeline.listsMeeting(jobID: job.id))
        XCTAssertFalse(pipeline.listsMeeting(jobID: UUID()))
    }

    /// At launch the queue has not read its snapshot yet, so the pruner reads it:
    /// a saved job keeps its record, a record with no row anywhere goes.
    func testAtLaunchAJobInTheUnreadSnapshotKeepsItsRecordAndNoOtherDoes() async throws {
        let harness = try makeHarness()
        let pipeline = harness.controller()
        let job = PipelineJob(
            meetingTitle: "Saved", appName: "Teams", mixPath: harness.recordings.appendingPathComponent("x.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        try PipelineSnapshot.save([job], to: harness.logDir)
        let saved = try emptyMeeting(harness, jobID: job.id)
        let orphan = try emptyMeeting(harness)

        await MeetingRecordPruner(pipeline: pipeline).prune()

        XCTAssertNotNil(harness.store.record(for: saved.jobID))
        XCTAssertNil(harness.store.record(for: orphan.jobID))
    }

    /// `AppState` builds it and leaves it alone; the launch `.task` starts it.
    func testAppStateBuildsThePrunerAndOnlyStartRunsIt() async throws {
        let state = try makeIsolatedAppState()
        let store = state.pipeline.meetingFileStore
        // In a folder that exists: a missing folder reads as a drive out of reach.
        let folder = try makeTempDirectory(prefix: "record_pruner_appstate")
        let file = MeetingFile(
            role: .mix, path: folder.appendingPathComponent("gone.wav").path, identity: nil, owned: true, state: .gone,
        )
        let record = MeetingFileRecord(
            jobID: UUID(), origin: .recorded, recordingDate: nil, files: [file], outcome: .leftUnfinished,
        )
        XCTAssertTrue(store.create(record), "test premise")

        await settle()
        XCTAssertNotNil(store.record(for: record.jobID), "ran before start")

        state.meetingRecordPruner.start()
        await waitFor { store.record(for: record.jobID) == nil }

        XCTAssertNil(store.record(for: record.jobID))
    }
}

/// What the window lists, as the pruner asks it, and how often it asked.
@MainActor
private final class Rows {
    var listed: Set<UUID> = []
    var lookups = 0
}
