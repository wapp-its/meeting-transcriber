@testable import MeetingTranscriber
import XCTest

/// A swap that cannot finish ends the re-run as R6 with the meeting as it was, and a
/// stop at any step of it is completed or undone at the next launch.
@MainActor
final class PipelineQueueRerunSwapRecoveryTests: XCTestCase {
    private typealias Fixture = PipelineQueueRerunFixture

    private struct Held {
        let meeting: PipelineJob
        let queue: PipelineQueue
        let marker: MeetingFileRecord.RerunMarker
        let files: [String: Data]
        let record: MeetingFileRecord
        let transcript: URL
    }

    // MARK: - Ends before the commit point

    func testACurrentFileReplacedBeforeTheSwapIsNotRenamedAndTheRerunEnds() async throws {
        for role in [MeetingFile.Role.transcript, .protocol] {
            let fixture = try makeFixture()
            let held = try await hold(fixture)
            let entry = try XCTUnwrap(fixture.record(held.meeting.id).files.last { $0.role == role })
            let replaced = URL(filePath: entry.path)
            try Data("changed by hand".utf8).write(to: replaced, options: .atomic)
            var expected = held.files
            let key = try XCTUnwrap(held.files.keys.first { MeetingFile.resolvedPath(URL(filePath: $0)) == entry.path })
            expected[key] = Data("changed by hand".utf8)

            try await assertEnded(held, fixture, files: expected, "\(role)")
        }
    }

    func testNotesThatAppearedUnderTheNotesNameOfAMeetingWithoutNotesStayAndTheRerunEnds() async throws {
        let fixture = try makeFixture()
        var generator: (any ProtocolGenerating)?
        // The fixture takes several closures; the label says which one this is.
        // swiftlint:disable:next trailing_closure
        let held = try await hold(fixture, fixture.makeQueue(completedJobLifetime: 0, protocolGenerator: { generator })) {
            generator = fixture.protocolGen
        }
        // Generate Meeting Notes from Transcript wrote them meanwhile.
        let notes = held.transcript.deletingPathExtension().appendingPathExtension("md")
        try Data("notes from the transcript".utf8).write(to: notes)
        var expected = held.files
        expected[notes.path] = Data("notes from the transcript".utf8)

        try await assertEnded(held, fixture, files: expected, "notes taken")
    }

    func testNoEarlierNameLeftEndsTheRerun() async throws {
        let fixture = try makeFixture()
        let held = try await hold(fixture)
        var expected = held.files
        var taken = Set<String>()
        while let name = EarlierVersionName.name(for: held.transcript.path, stamp: held.marker.stamp, taken: taken) {
            taken.insert(MeetingReportFolder.folded(name))
            let url = held.transcript.deletingLastPathComponent().appendingPathComponent(name)
            try Data().write(to: url)
            expected[url.path] = Data()
        }

        try await assertEnded(held, fixture, files: expected, "no name")
    }

    // MARK: - After the commit point

    func testAFailedEntryWriteKeepsTheJobInTheRerunFileAndAColdStartFinishesItOnce() async throws {
        let fixture = try makeFixture()
        let log = RerunExportLog()
        let notion = RerunLoggingExporter.configuration("db-record", log)
        let first = fixture.makeQueue(completedJobLifetime: 0, notion: notion)
        let meeting = try await fixture.finishedMeeting(in: first, leavingTheQueue: true)
        let callsBefore = await log.calls.count
        let queue = fixture.makeQueue(completedJobLifetime: 0, notion: notion)
        queue.isRegenerationRunning = { true }
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        let marker = try fixture.marker(meeting.id, in: queue)
        // The finished-job history cannot be written: its staging name is taken by a folder.
        let staging = fixture.tmpDir.appendingPathComponent("records/terminal_jobs.json.tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        queue.isRegenerationRunning = { false }
        try await fixture.poll("the commit") { (try? fixture.record(meeting.id).rerunNote?.committed) == true }
        try await Task.sleep(for: .milliseconds(300))
        await PipelineSnapshotStore.flush(fixture.logDir)

        XCTAssertNotNil(queue.job(withID: meeting.id)?.rerun, "the job turned ordinary before its entry landed")
        var saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
        XCTAssertEqual(saved.map(\.id), [meeting.id], "the re-run file let go of the job")
        let callsAtCommit = await log.calls.count
        XCTAssertEqual(callsAtCommit, callsBefore, "the export started before the entry landed")
        try FileManager.default.removeItem(at: staging)

        // A cold start: the launch rows that need no queue, then the first queue.
        PipelineQueue.reconcileOrphanedReruns(in: fixture.store, logDir: fixture.logDir) { _ in false }
        let restarted = fixture.makeQueue(completedJobLifetime: 0, notion: notion)
        restarted.loadSnapshot()
        try await fixture.poll("the export") { restarted.notionExportTasks[meeting.id] == nil && restarted.job(withID: meeting.id)?.rerun == nil }
        try await Task.sleep(for: .milliseconds(300))
        await PipelineSnapshotStore.flush(fixture.logDir)

        let calls = await log.calls.dropFirst(callsBefore)
        XCTAssertEqual(calls.map(\.page), ["page-1"], "not one update of the recorded page")
        XCTAssertEqual(calls.map(\.database), ["db-record"])
        let entry = try XCTUnwrap(fixture.finishedEntry(meeting.id))
        let notes = try XCTUnwrap(entry.status.protocolPath, "the entry names no notes")
        XCTAssertEqual(FileIdentity.of(notes), marker.files.last { $0.role == .protocol }?.identity, "the entry is not the new result")
        XCTAssertEqual(fixture.terminal.records.last?.status.jobID, meeting.id.uuidString)
        saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
        XCTAssertTrue(saved.isEmpty, "the re-run file still holds the job")
    }

    // MARK: - A stop between two steps

    func testALaunchAfterAStopAtEachStepCompletesTheSwap() async throws {
        let fixture = try makeFixture()
        let count = try await stoppedSwap(fixture, after: 0).renames.count
        XCTAssertGreaterThanOrEqual(count, 4, "test premise: two earlier versions and two new files")
        for step in 0 ... count {
            let fixture = try makeFixture()
            let stopped = try await stoppedSwap(fixture, after: step)

            await restart(fixture)

            let record = try fixture.record(stopped.held.meeting.id)
            XCTAssertEqual(record.rerunNote, .init(stamp: stopped.held.marker.stamp, committed: true), "step \(step)")
            // The segments file goes with the naming data once the finished job leaves.
            for rename in stopped.renames where rename.role != .segments {
                XCTAssertEqual(FileIdentity.of(rename.to), rename.identity, "step \(step): \(URL(filePath: rename.to).lastPathComponent)")
            }
            XCTAssertEqual(fixture.finishedEntry(stopped.held.meeting.id)?.status.transcriptPath, stopped.held.transcript.path, "step \(step)")
        }
    }

    func testALaunchUndoesTheSwapWhenAFileOfItsListIsMissing() async throws {
        for step in [0, 2, 3] {
            let fixture = try makeFixture()
            let stopped = try await stoppedSwap(fixture, after: step)
            // A file of the re-run, wherever the swap left it, is gone.
            let gone = try XCTUnwrap(stopped.renames.last)
            for path in [gone.from, gone.to] where FileIdentity.of(path) == gone.identity {
                try FileManager.default.removeItem(atPath: path)
            }

            await restart(fixture)

            XCTAssertEqual(try fixture.outputFiles(), stopped.held.files, "step \(step): the meeting is not as it was")
            var expected = stopped.held.record
            expected.rerunNote = .init(stamp: stopped.held.marker.stamp, committed: false)
            XCTAssertEqual(try fixture.record(stopped.held.meeting.id), expected, "step \(step)")
        }
    }

    func testARenameFailingAtEachStepIsUndoneFromItsList() throws {
        let names = ["a.txt", "a.md", "a.rerun.txt", "a.rerun.md"]
        let moves = [("a.txt", "a.until.txt"), ("a.md", "a.until.md"), ("a.rerun.txt", "a.txt"), ("a.rerun.md", "a.md")]
        for failing in moves.indices {
            let folder = try makeTempDirectory(prefix: "rerun_renames")
            for name in names {
                try Data(name.utf8).write(to: folder.appendingPathComponent(name))
            }
            let renames = moves.map { from, to in
                let source = MeetingFile.resolvedPath(folder.appendingPathComponent(from))
                return MeetingFileRecord.Rename(
                    role: .transcript, from: source, to: URL(filePath: source).deletingLastPathComponent().appendingPathComponent(to).path,
                    identity: FileIdentity.of(source), earlier: false,
                )
            }
            // The step's file was replaced by another with the same bytes: it is no
            // longer the file the list names.
            let replaced = folder.appendingPathComponent(moves[failing].0)
            try Data(contentsOf: replaced).write(to: replaced, options: .atomic)

            XCTAssertEqual(PipelineQueue.performRenames(renames, jobID: UUID()), failing)
            PipelineQueue.undoRenames(renames, jobID: UUID())

            let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            XCTAssertEqual(left, names.sorted(), "step \(failing)")
            for name in names {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), Data(name.utf8), "step \(failing): \(name)")
            }
        }
    }

    // MARK: - Helpers

    private func makeFixture() throws -> Fixture {
        try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_swap_recovery"))
    }

    /// A finished meeting whose re-run is held at its success before the swap.
    /// `beforeRerun` runs after the first run.
    private func hold(_ fixture: Fixture, _ queue: PipelineQueue? = nil, beforeRerun: () -> Void = {}) async throws -> Held {
        let queue = queue ?? fixture.makeQueue(completedJobLifetime: 0)
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let (files, record) = try (fixture.outputFiles(), fixture.record(meeting.id))
        let transcript = try URL(filePath: XCTUnwrap(fixture.finishedEntry(meeting.id)?.status.transcriptPath))
        beforeRerun()
        queue.isRegenerationRunning = { true }
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .done, "test premise: the re-run succeeded")
        let marker = try fixture.marker(meeting.id, in: queue)
        return Held(meeting: meeting, queue: queue, marker: marker, files: files, record: record, transcript: transcript)
    }

    /// The swap released and run to its end, which leaves the meeting as `files`.
    private func assertEnded(
        _ held: Held, _ fixture: Fixture, files: [String: Data], _ name: String, file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        held.queue.isRegenerationRunning = { false }
        try await fixture.poll("\(name): the re-run to end") { held.queue.job(withID: held.meeting.id) == nil }
        // A record lists a path as the disk resolves it, the folder walk may spell it with `/private`.
        func resolved(_ files: [String: Data]) -> [String: Data] {
            Dictionary(files.map { (MeetingFile.resolvedPath(URL(filePath: $0.key)), $0.value) }) { first, _ in first }
        }
        XCTAssertEqual(try resolved(fixture.outputFiles()), resolved(files), "\(name): the meeting is not as it was", file: file, line: line)
        var expected = held.record
        expected.rerunNote = .init(stamp: held.marker.stamp, committed: false)
        XCTAssertEqual(try fixture.record(held.meeting.id), expected, name, file: file, line: line)
        guard case .failed = held.queue.rerunWarnings[held.meeting.id]?.cause else {
            XCTFail("\(name): no failure line", file: file, line: line)
            return
        }
    }

    /// A re-run held at its success whose swap wrote its list of renames and made
    /// the first `step` of them, as a stop there leaves it.
    private func stoppedSwap(_ fixture: Fixture, after step: Int) async throws -> (held: Held, renames: [MeetingFileRecord.Rename]) {
        let held = try await hold(fixture)
        let record = try fixture.record(held.meeting.id)
        let marker = try XCTUnwrap(record.rerun)
        let base = PipelineQueue.namingSlug(title: held.meeting.meetingTitle, jobID: held.meeting.id, startTime: fixture.meetingStart)
        let plan = PipelineQueue.swapRenames(marker: marker, record: record, base: base)
        XCTAssertNil(plan.refusal)
        XCTAssertTrue(fixture.store.update(jobID: held.meeting.id) { $0.rerun?.renames = plan.renames })
        XCTAssertNil(PipelineQueue.performRenames(Array(plan.renames.prefix(step)), jobID: held.meeting.id))
        await PipelineSnapshotStore.flush(fixture.logDir)
        return (held, plan.renames)
    }

    private func restart(_ fixture: Fixture) async {
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        queue.loadSnapshot()
        await queue.awaitProcessing()
        await PipelineSnapshotStore.flush(fixture.logDir)
    }
}
