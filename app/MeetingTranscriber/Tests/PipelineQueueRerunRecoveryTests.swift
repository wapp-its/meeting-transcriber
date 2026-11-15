@testable import MeetingTranscriber
import XCTest

/// A re-run across a quit (A24): its job lives in this build's own file beside the
/// queue's snapshot, and at launch the meeting's record decides, row by row of the
/// spec's launch table, whether it resumes, waits or ends as R6.
@MainActor
final class PipelineQueueRerunRecoveryTests: XCTestCase {
    private typealias Fixture = PipelineQueueRerunFixture

    /// A re-run parked for names, as a quit leaves it, with what the meeting was
    /// before it.
    private struct Parked {
        let meeting: PipelineJob
        let marker: MeetingFileRecord.RerunMarker
        let files: [String: Data]
        let record: MeetingFileRecord
    }

    /// A marker read at launch before any queue: what this build's re-run file
    /// holds (nil: the job, as saved), whose build reads it, and whether the
    /// marker's process still runs.
    private struct OrphanRow {
        let name: String
        let file: String?
        var otherBuild = false
        var running = false
        let ends: Bool
    }

    // MARK: - The re-run file

    func testWhileARerunRunsOnlyThisBuildsFileHoldsIt() async throws {
        let fixture = try makeFixture()
        let parked = try await park(fixture, in: fixture.makeQueue(completedJobLifetime: 0))

        let queueFile = try PipelineSnapshot.load(from: fixture.logDir) ?? []
        XCTAssertFalse(queueFile.contains { $0.id == parked.meeting.id || $0.rerun != nil }, "pipeline_queue.json holds the re-run")
        let rerunFile = try XCTUnwrap(PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent))
        XCTAssertEqual(rerunFile.map(\.id), [parked.meeting.id])
        XCTAssertEqual(rerunFile.first?.rerun?.marker.runID, parked.marker.runID)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.rerunFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the re-run file is not owner-only")
    }

    func testAColdStartResumesTheRerunWithItsMarkerAndNoAutomaticNames() async throws {
        let fixture = try makeFixture()
        let parked = try await park(fixture, in: fixture.makeQueue(completedJobLifetime: 0))
        let controller = try makeController(fixture)

        controller.activate { MockEngine() }
        controller.rebuild()

        let restored = try XCTUnwrap(controller.queue.job(withID: parked.meeting.id), "the re-run was not restored")
        XCTAssertEqual(restored.state, .speakerNamingPending)
        XCTAssertEqual(restored.rerun?.marker.runID, parked.marker.runID)
        let record = try fixture.record(parked.meeting.id)
        XCTAssertEqual(record.rerun?.runID, parked.marker.runID, "the record's marker went")
        XCTAssertEqual(record.rerun?.outcomeBefore, parked.record.outcome)
        XCTAssertFalse(record.rerun?.files.contains { $0.role == .protocol } ?? true, "notes were made with automatic names")
    }

    func testWithTheWaitSetToNeverAWaitingRerunStaysWaitingAcrossALaunch() async throws {
        let waits: [(name: String, maxAge: TimeInterval?, stays: Bool)] = [
            ("never", nil, true),
            ("one day", StaleNamingTimeout.oneDay.maxAge, false),
        ]
        for wait in waits {
            let fixture = try makeFixture()
            // The fixture takes several closures; the label says which one this is.
            // swiftlint:disable:next trailing_closure
            let parked = try await park(fixture, in: fixture.makeQueue(completedJobLifetime: 0, staleNamingMaxAge: { wait.maxAge }))
            // Waiting for names for two days when the app quit.
            var saved = try XCTUnwrap(PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent))
            saved[0].namingStartedAt = Date().addingTimeInterval(-2 * 86400)
            try PipelineSnapshot.save(saved, to: fixture.logDir, named: fixture.rerunFile.lastPathComponent)
            // swiftlint:disable:next trailing_closure
            let queue = fixture.makeQueue(completedJobLifetime: 0, staleNamingMaxAge: { wait.maxAge })

            queue.loadSnapshot()
            await queue.awaitProcessing()

            XCTAssertEqual(queue.job(withID: parked.meeting.id)?.state == .speakerNamingPending, wait.stays, wait.name)
            XCTAssertEqual(try fixture.record(parked.meeting.id).rerun == nil, !wait.stays, wait.name)
            if !wait.stays {
                XCTAssertEqual(try fixture.outputFiles(), parked.files, "\(wait.name): the meeting is not as it was")
            }
        }
    }

    // MARK: - Launch rows read through the queue

    func testAStopAfterTheEndBeganIsFinishedAtTheNextLaunch() async throws {
        let fixture = try makeFixture()
        let parked = try await park(fixture, in: fixture.makeQueue(completedJobLifetime: 0))
        XCTAssertNotEqual(try fixture.outputFiles(), parked.files, "test premise: the re-run wrote its files")
        // The end marked the marker as ending, then the app stopped.
        XCTAssertTrue(fixture.store.update(jobID: parked.meeting.id) { $0.rerun?.ending = true })

        try await assertEndedAtLaunch(parked, fixture)
    }

    func testARecordWithoutMarkerOrNoteWhileItsJobIsInTheFileEndsTheRerun() async throws {
        let fixture = try makeFixture()
        let parked = try await park(fixture, in: fixture.makeQueue(completedJobLifetime: 0))
        // A build without the re-run rewrote the record and dropped what it does not know.
        XCTAssertTrue(fixture.store.update(jobID: parked.meeting.id) { $0.rerun = nil })

        try await assertEndedAtLaunch(parked, fixture)
    }

    // MARK: - Launch rows read before any queue

    func testTheLaunchEndsOnlyAnOrphanOfThisBuildWhoseProcessEnded() async throws {
        let rows = [
            OrphanRow(name: "its job in the file", file: nil, ends: false),
            OrphanRow(name: "its job not in the file, its process ended", file: "[]", ends: true),
            OrphanRow(name: "its job not in the file, its process running", file: "[]", running: true, ends: false),
            OrphanRow(name: "of the other build", file: "[]", otherBuild: true, ends: false),
            OrphanRow(name: "the re-run file unreadable", file: "{", ends: false),
        ]
        for row in rows {
            let fixture = try makeFixture()
            let parked = try await park(fixture, in: fixture.makeQueue(completedJobLifetime: 0))
            if let file = row.file { try Data(file.utf8).write(to: fixture.rerunFile) }
            let store = row.otherBuild ? MeetingFileStore(path: fixture.storePath, bundleID: "other.build") : fixture.store
            let otherFile = fixture.logDir.appendingPathComponent(PipelineSnapshot.rerunFilename(bundleID: "other.build"))
            if row.otherBuild { try Data("[]".utf8).write(to: otherFile) }

            PipelineQueue.reconcileOrphanedReruns(in: store, logDir: fixture.logDir) { _ in row.running }

            fixture.store.reload()
            let record = try fixture.record(parked.meeting.id)
            XCTAssertEqual(record.rerun == nil, row.ends, row.name)
            if row.ends {
                XCTAssertEqual(record.rerunNote, .init(stamp: parked.marker.stamp, committed: false), row.name)
                XCTAssertEqual(record.outcome, parked.record.outcome, row.name)
                XCTAssertEqual(try fixture.outputFiles(), parked.files, "\(row.name): the meeting is not as it was")
            } else {
                XCTAssertEqual(record.rerun?.runID, parked.marker.runID, row.name)
                XCTAssertNotEqual(try fixture.outputFiles(), parked.files, "\(row.name): the re-run's files went")
            }
        }
    }

    func testActivateEndsAnOrphanMarkedAsEnding() async throws {
        let fixture = try makeFixture()
        let parked = try await park(fixture, in: fixture.makeQueue(completedJobLifetime: 0))
        try Data("[]".utf8).write(to: fixture.rerunFile)
        XCTAssertTrue(fixture.store.update(jobID: parked.meeting.id) { $0.rerun?.ending = true })

        try makeController(fixture).activate { MockEngine() }

        var expected = parked.record
        expected.rerunNote = .init(stamp: parked.marker.stamp, committed: false)
        XCTAssertEqual(try fixture.record(parked.meeting.id), expected)
        XCTAssertEqual(try fixture.outputFiles(), parked.files, "the meeting is not as it was")
    }

    func testTheRestoreDecisionFollowsTheRecord() throws {
        let fixture = try makeFixture()
        let mine = MeetingFileRecord.RerunMarker(
            stamp: Date(timeIntervalSince1970: 1000), outcomeBefore: .finished(protocolExpected: true), bundleID: fixture.store.bundleID,
            process: .current, runID: UUID(),
        )
        var ending = mine
        ending.ending = true
        let another = MeetingFileRecord.RerunMarker(
            stamp: mine.stamp, outcomeBefore: .finished(protocolExpected: true), bundleID: fixture.store.bundleID, process: .current, runID: UUID(),
        )
        let rows: [(name: String, rerun: MeetingFileRecord.RerunMarker?, note: MeetingFileRecord.RerunNote?, expected: PipelineQueue.RerunRestore)] = [
            ("its marker, running", mine, nil, .resume),
            ("its marker, ending", ending, nil, .finish(ending)),
            ("another run's marker", another, nil, .drop),
            ("its stamp noted as committed", nil, .init(stamp: mine.stamp, committed: true), .keep),
            ("its stamp noted as ended", nil, .init(stamp: mine.stamp, committed: false), .finish(mine)),
            ("no marker and no note", nil, nil, .finish(mine)),
        ]
        for row in rows {
            var record = MeetingFileRecord(jobID: UUID(), origin: .recorded, recordingDate: nil, files: [])
            record.rerun = row.rerun
            record.rerunNote = row.note
            XCTAssertEqual(PipelineQueue.restoreDecision(for: mine, record: record), row.expected, row.name)
        }
        XCTAssertEqual(PipelineQueue.restoreDecision(for: mine, record: nil), .drop, "no record")
    }

    // MARK: - Helpers

    private func makeFixture() throws -> Fixture {
        try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_recovery"))
    }

    /// A finished meeting out of the queue whose re-run waits for names, with
    /// both files on disk.
    private func park(_ fixture: Fixture, in queue: PipelineQueue) async throws -> Parked {
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let files = try fixture.outputFiles()
        let record = try fixture.record(meeting.id)
        fixture.parkForNaming(true)
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        try await fixture.poll("the names") { queue.job(withID: meeting.id)?.state == .speakerNamingPending }
        await queue.awaitProcessing()
        let marker = try fixture.marker(meeting.id, in: queue)
        await PipelineSnapshotStore.flush(fixture.logDir)
        return Parked(meeting: meeting, marker: marker, files: files, record: record)
    }

    /// A new queue over the same folders restores the re-run and ends it as R6.
    private func assertEndedAtLaunch(
        _ parked: Parked, _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        let queue = fixture.makeQueue(completedJobLifetime: 0)

        queue.loadSnapshot()
        await queue.awaitProcessing()
        await PipelineSnapshotStore.flush(fixture.logDir)

        XCTAssertNil(queue.job(withID: parked.meeting.id), "the re-run is in the queue", file: file, line: line)
        XCTAssertEqual(try fixture.outputFiles(), parked.files, "the meeting is not as it was", file: file, line: line)
        var expected = parked.record
        expected.rerunNote = .init(stamp: parked.marker.stamp, committed: false)
        XCTAssertEqual(try fixture.record(parked.meeting.id), expected, "the record is not as it was", file: file, line: line)
        let rerunFile = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
        XCTAssertTrue(rerunFile.isEmpty, "the re-run file still holds the job", file: file, line: line)
    }

    private func makeController(_ fixture: Fixture) throws -> PipelineController {
        let suite = "PipelineQueueRerunRecoveryTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: fixture.outputDir)
        settings.autoOpenSpeakerNaming = false
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: fixture.logDir),
            terminalJobStore: fixture.terminal, meetingFileStore: fixture.store,
        )
    }
}
