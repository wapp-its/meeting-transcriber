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

    func testACurrentSegmentsFileStaysAsItWasWhenTheSwapIsUndone() async throws {
        let fixture = try makeFixture()
        var generator: (any ProtocolGenerating)?
        // swiftlint:disable:next trailing_closure
        let held = try await hold(fixture, fixture.makeQueue(completedJobLifetime: 0, protocolGenerator: { generator })) {
            generator = fixture.protocolGen
        }
        // Word timings the meeting kept, renamed out of the way by the swap before
        // the notes rename below fails.
        let entry = try XCTUnwrap(held.record.files.last { $0.role == .segments }, "test premise: no segments entry")
        let segments = URL(filePath: entry.path)
        try Data("earlier word timings".utf8).write(to: segments)
        let listed = MeetingFile(role: .segments, url: segments, owned: true)
        XCTAssertTrue(fixture.store.update(jobID: held.meeting.id) { $0.list(listed) })
        var record = held.record
        record.list(listed)
        let notes = held.transcript.deletingPathExtension().appendingPathExtension("md")
        try Data("notes from the transcript".utf8).write(to: notes)
        // By resolved path: the folder walk spells the kept file with `/private` or without.
        var expected = resolved(held.files)
        expected[segments.path] = Data("earlier word timings".utf8)
        expected[notes.path] = Data("notes from the transcript".utf8)
        let undone = Held(meeting: held.meeting, queue: held.queue, marker: held.marker, files: expected, record: record, transcript: held.transcript)

        try await assertEnded(undone, fixture, files: expected, "segments")
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

    func testADoneStateTheRerunFileDidNotTakeEndsTheRerunBeforeAnyRename() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let (files, record) = try (fixture.outputFiles(), fixture.record(meeting.id))
        let transcript = try URL(filePath: XCTUnwrap(fixture.finishedEntry(meeting.id)?.status.transcriptPath))
        // From the notes on, no write of the re-run file lands, its retry included:
        // its staging name is taken by a folder.
        let staging = fixture.rerunFile.deletingPathExtension().appendingPathExtension("tmp")
        queue.onJobStateChange = { _, _, state in
            guard state == .generatingProtocol else { return }
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        let marker = try fixture.marker(meeting.id, in: queue)
        await queue.awaitProcessing()
        let held = Held(meeting: meeting, queue: queue, marker: marker, files: files, record: record, transcript: transcript)

        try await assertEnded(held, fixture, files: files, "done not saved")

        let saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
        XCTAssertNotEqual(saved.first { $0.id == meeting.id }?.state, .done, "test premise: the done state landed")
        // The next launch reads the job as the file kept it and leaves the meeting as it was.
        try FileManager.default.removeItem(at: staging)
        await restart(fixture)
        XCTAssertEqual(try resolved(fixture.outputFiles()), resolved(files), "the launch changed the meeting")
        XCTAssertNil(try fixture.record(meeting.id).rerun)
    }

    // MARK: - After the commit point

    func testAFailedEntryWriteKeepsTheJobInTheRerunFileAndAColdStartFinishesItOnce() async throws {
        // One row each: the first launch writes the entry, or its write fails too and
        // the export stays owed to the launch after it.
        for failedLaunches in [0, 1] {
            let row = "failed launches \(failedLaunches)"
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

            XCTAssertNotNil(queue.job(withID: meeting.id)?.rerun, "\(row): the job turned ordinary before its entry landed")
            var saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
            XCTAssertEqual(saved.map(\.id), [meeting.id], "\(row): the re-run file let go of the job")
            let callsAtCommit = await log.calls.count
            XCTAssertEqual(callsAtCommit, callsBefore, "\(row): the export started before the entry landed")
            for _ in 0 ..< failedLaunches {
                PipelineQueue.reconcileOrphanedReruns(in: fixture.store, logDir: fixture.logDir) { _ in false }
                let failed = fixture.makeQueue(completedJobLifetime: 0, notion: notion)
                failed.loadSnapshot()
                try await Task.sleep(for: .milliseconds(300))
                await PipelineSnapshotStore.flush(fixture.logDir)
                XCTAssertNotNil(failed.job(withID: meeting.id)?.rerun, "\(row): the job turned ordinary before its entry landed")
            }
            try FileManager.default.removeItem(at: staging)

            // A cold start: the launch rows that need no queue, then the first queue.
            PipelineQueue.reconcileOrphanedReruns(in: fixture.store, logDir: fixture.logDir) { _ in false }
            // The app's lifetime of a finished job: with none, the job could leave the
            // list before its hand-off starts the export, which the app's minute
            // does not allow.
            let restarted = fixture.makeQueue(notion: notion)
            restarted.loadSnapshot()
            // The job turns ordinary before its hand-off starts the export, so the
            // export's own end is what to wait for.
            try await fixture.poll("the export") {
                restarted.job(withID: meeting.id)?.rerun == nil && restarted.job(withID: meeting.id)?.notionExportStatus == .completed
            }
            try await Task.sleep(for: .milliseconds(300))
            await PipelineSnapshotStore.flush(fixture.logDir)

            let calls = await log.calls.dropFirst(callsBefore)
            XCTAssertEqual(calls.map(\.page), ["page-1"], "\(row): not one update of the recorded page")
            XCTAssertEqual(calls.map(\.database), ["db-record"], row)
            let entry = try XCTUnwrap(fixture.finishedEntry(meeting.id), row)
            let notes = try XCTUnwrap(entry.status.protocolPath, "\(row): the entry names no notes")
            XCTAssertEqual(FileIdentity.of(notes), marker.files.last { $0.role == .protocol }?.identity, "\(row): the entry is not the new result")
            XCTAssertEqual(fixture.terminal.records.last?.status.jobID, meeting.id.uuidString, row)
            saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
            XCTAssertTrue(saved.isEmpty, "\(row): the re-run file still holds the job")
        }
    }

    func testALaunchAfterTheCommitLeavesACurrentTranscriptReplacedMeanwhile() async throws {
        let fixture = try makeFixture()
        let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0), leavingTheQueue: true)
        // Admitted with "Save raw transcript separately" off.
        let queue = fixture.makeQueue(saveRawTranscriptSeparately: false, completedJobLifetime: 0)
        queue.isRegenerationRunning = { true }
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .done, "test premise: the re-run succeeded")
        // A stop right after the commit point: every rename made and the record committed.
        let record = try fixture.record(meeting.id)
        var marker = try XCTUnwrap(record.rerun)
        let base = PipelineQueue.namingSlug(title: meeting.meetingTitle, jobID: meeting.id, startTime: fixture.meetingStart)
        let plan = PipelineQueue.swapRenames(marker: marker, record: record, base: base)
        XCTAssertNil(plan.refusal)
        XCTAssertNil(PipelineQueue.performRenames(plan.renames, jobID: meeting.id))
        marker.renames = plan.renames
        let current = plan.renames.filter { !$0.earlier }.map { MeetingFile(role: $0.role, url: URL(filePath: $0.to), owned: true) }
        let earlier = plan.renames.filter(\.earlier).map { MeetingFile(role: .previousProtocol, url: URL(filePath: $0.to), owned: true) }
        XCTAssertTrue(fixture.store.update(jobID: meeting.id) { _ = $0.commitRerun(marker, current: current, kept: earlier, protocolExpected: true) })
        // The current transcript is replaced while the app is closed.
        let transcript = try URL(filePath: XCTUnwrap(plan.renames.first { $0.role == .transcript && !$0.earlier }).to)
        try Data("changed by hand".utf8).write(to: transcript, options: .atomic)
        await PipelineSnapshotStore.flush(fixture.logDir)

        await restart(fixture)

        XCTAssertEqual(try fixture.record(meeting.id).rerunNote, .init(stamp: marker.stamp, committed: true), "test premise")
        XCTAssertEqual(try? Data(contentsOf: transcript), Data("changed by hand".utf8), "the replaced transcript was removed")
    }

    func testARenameThatCannotGoBackKeepsTheMarkerAndItsFileUntilALaterTryMovesItBack() async throws {
        let fixture = try makeFixture()
        let stopped = try await stoppedSwap(fixture, after: 1)
        let moved = try XCTUnwrap(stopped.renames.first)
        XCTAssertTrue(moved.earlier && moved.role == .transcript, "test premise: the current transcript moves first")
        let transcriptBytes = try Data(contentsOf: URL(filePath: moved.to))
        // Its name is taken meanwhile, and a file of the re-run is gone, so the launch undoes the swap.
        try Data("taken".utf8).write(to: URL(filePath: moved.from))
        let gone = try XCTUnwrap(stopped.renames.last)
        try FileManager.default.removeItem(atPath: gone.from)

        await restart(fixture)

        let record = try fixture.record(stopped.held.meeting.id)
        XCTAssertEqual(record.rerun?.isEnding, true, "the marker went with a rename not undone")
        XCTAssertEqual(record.rerun?.files.map(\.path), [moved.to])
        XCTAssertEqual(record.rerunRefusal, .filesLeft)
        // The next try leaves the file at the rename's target: it is the meeting's own.
        PipelineQueue.reconcileOrphanedReruns(in: fixture.store, logDir: fixture.logDir) { _ in false }
        XCTAssertEqual(try? Data(contentsOf: URL(filePath: moved.to)), transcriptBytes, "the meeting's transcript was removed")
        // Once its name is free, a later try moves it back and the re-run ends.
        try FileManager.default.removeItem(atPath: moved.from)
        PipelineQueue.reconcileOrphanedReruns(in: fixture.store, logDir: fixture.logDir) { _ in false }
        XCTAssertEqual(try? Data(contentsOf: URL(filePath: moved.from)), transcriptBytes)
        XCTAssertNil(try fixture.record(stopped.held.meeting.id).rerun)
    }

    func testAFileOfTheRerunALaterTryMovesBackIsRemovedBeforeTheMarkerGoes() async throws {
        let fixture = try makeFixture()
        let stopped = try await stoppedSwap(fixture, after: .max) // every rename made
        let id = stopped.held.meeting.id
        let own = stopped.renames.filter { !$0.earlier }
        let folder = try URL(filePath: XCTUnwrap(own.first?.from)).deletingLastPathComponent()
        // The folder the re-run wrote to takes no file for a while, so its files
        // cannot go back to their own names.
        let marker = try XCTUnwrap(fixture.record(id).rerun)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        _ = PipelineQueue.closeRerun(marker, jobID: id, in: fixture.store)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let kept = try Set(XCTUnwrap(fixture.record(id).rerun, "test premise: the marker went with renames not undone").files.map(\.path))
        XCTAssertTrue(kept.isDisjoint(with: own.map(\.from)), "test premise: the marker lists a file at the re-run's own name")

        // A later try moves them back and ends the re-run.
        _ = try PipelineQueue.closeRerun(XCTUnwrap(fixture.record(id).rerun), jobID: id, in: fixture.store)

        XCTAssertEqual(try resolved(fixture.outputFiles()), resolved(stopped.held.files), "the meeting is not as it was")
        XCTAssertNil(try fixture.record(id).rerun)
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

    /// `files` by the path the disk resolves: a record lists a path that way, and
    /// the folder walk may spell it with `/private`.
    private func resolved(_ files: [String: Data]) -> [String: Data] {
        Dictionary(files.map { (MeetingFile.resolvedPath(URL(filePath: $0.key)), $0.value) }) { first, _ in first }
    }

    /// The swap released and run to its end, which leaves the meeting as `files`.
    private func assertEnded(
        _ held: Held, _ fixture: Fixture, files: [String: Data], _ name: String, file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        held.queue.isRegenerationRunning = { false }
        try await fixture.poll("\(name): the re-run to end") { held.queue.job(withID: held.meeting.id) == nil }
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
