@testable import MeetingTranscriber
import XCTest

// MARK: - Additional reports in Move Meeting to Trash

/// A meeting's additional reports go to the Trash with it (spec R5, A6, A12): found
/// by name beside its transcript and notes, listed in the record in the same save as
/// the pending mark, and refused, kept or retried under gh-97's rules for every other
/// file. Real files in a temp folder; the Trash is the harness's fake.
extension PipelineControllerTranscriptionsTests {
    /// Writes `names` as reports of `job`'s meeting; their paths as a record lists them.
    private func writeReports(_ names: [String], of job: PipelineJob, _ harness: MeetingDeletionHarness) throws -> [String] {
        let stem = try XCTUnwrap(job.transcriptPath).deletingPathExtension().lastPathComponent
        return try names.map { name in
            let url = harness.recordings.appendingPathComponent("\(stem) (\(name)).md")
            try Data("# \(name)".utf8).write(to: url)
            return MeetingFile.resolvedPath(url)
        }
    }

    private func lockFolder(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    }

    private func unlockFolder(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    // MARK: - Moving

    func testMoveMeetingTakesItsReportsAndLeavesNoneOfItsFiles() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let files = try harness.paths(of: job)
        let reports = try writeReports(["Short", "Minutes"], of: job, harness)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(Set(harness.fakeTrash.moved), Set(harness.names(files + reports)))
        XCTAssertEqual((files + reports).filter(harness.isOnDisk), [])
        XCTAssertNil(harness.store.record(for: job.id))
    }

    func testTheReportsAreListedInTheSameSaveAsThePendingMarkBeforeAnyMove() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let reports = try writeReports(["Short"], of: job, harness)
        var atFirstMove: MeetingFileRecord?
        harness.fakeTrash.beforeMove = { [recordPath = harness.recordPath] _ in
            if atFirstMove == nil { atFirstMove = MeetingFileStore(path: recordPath).record(for: job.id) }
        }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        let saved = try XCTUnwrap(atFirstMove)
        XCTAssertEqual(saved.pending?.paths.contains(reports[0]), true)
        let listed = try XCTUnwrap(saved.files.first { $0.path == reports[0] })
        XCTAssertEqual(listed.role, .previousProtocol)
        XCTAssertTrue(listed.owned)
        XCTAssertNotNil(listed.identity)
    }

    func testAFailedSaveMovesNoReport() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let reports = try writeReports(["Short"], of: job, harness)
        let folder = harness.logDir.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        XCTAssertFalse(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertEqual(reports.filter(harness.isOnDisk), reports)
    }

    /// "Move Audio to Trash…" and the automatic deletion leave the reports, like the
    /// transcript and the notes.
    func testMoveAudioAndTheAutomaticDeletionLeaveTheReports() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let reports = try writeReports(["Short"], of: job, harness)

        XCTAssertTrue(controller.moveAudioToTrash(jobID: job.id))

        XCTAssertEqual(reports.filter(harness.isOnDisk), reports)
        XCTAssertFalse(try harness.record(of: job).files.contains { $0.role == .previousProtocol })
        var listed = try harness.record(of: job)
        listed.files.append(MeetingFile(role: .previousProtocol, path: reports[0], identity: nil, owned: true, state: .present))
        XCTAssertFalse(listed.filesCovered(by: .automatic).contains { $0.path == reports[0] })
        XCTAssertFalse(listed.filesCovered(by: .audioToTrash).contains { $0.path == reports[0] })
    }

    // MARK: - Deletion incomplete

    func testAReportTheTrashRefusesLeavesTheMeetingIncompleteAndARetryFindsOneAddedSince() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let reports = try writeReports(["Short"], of: job, harness)
        harness.fakeTrash.refusal = { $0.lastPathComponent.hasSuffix("(Short).md") ? CocoaError(.featureUnsupported) : nil }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        let incomplete = try harness.record(of: job)
        XCTAssertEqual(incomplete.incomplete?.reason, "this volume has no Trash")
        XCTAssertEqual(incomplete.incomplete?.paths, reports)
        XCTAssertEqual(incomplete.files.first { $0.path == reports[0] }?.state, .present)
        XCTAssertNotNil(harness.history.lookup(jobID: job.id), "the row stays")

        harness.fakeTrash.refusal = { _ in nil }
        let added = try writeReports(["Minutes"], of: job, harness)
        XCTAssertTrue(controller.retryDeletion(jobID: job.id))

        XCTAssertEqual((reports + added).filter(harness.isOnDisk), [])
        XCTAssertNil(harness.store.record(for: job.id))
    }

    func testAReportReplacedAfterTheFirstRunIsRefusedAsReplacedOnTheRetry() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let reports = try writeReports(["Short"], of: job, harness)
        harness.fakeTrash.refusal = { $0.lastPathComponent.hasSuffix("(Short).md") ? CocoaError(.featureUnsupported) : nil }
        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))
        harness.fakeTrash.refusal = { _ in nil }
        try FileManager.default.removeItem(atPath: reports[0])
        try Data("# Someone else's".utf8).write(to: URL(fileURLWithPath: reports[0]))

        XCTAssertTrue(controller.retryDeletion(jobID: job.id))

        XCTAssertEqual(try harness.record(of: job).incomplete?.reason, "1 file was replaced")
        XCTAssertTrue(harness.isOnDisk(reports[0]))
    }

    func testAnUnreadableFolderMovesNothingAndTheRetryReadsItAgain() throws {
        for everyListedFileGone in [false, true] {
            let harness = try makeDeletionHarness()
            let controller = harness.controller(queue: harness.makeQueue())
            let job = try harness.recordedMeeting()
            let reports = try writeReports(["Short"], of: job, harness)
            if everyListedFileGone {
                for path in try harness.paths(of: job) {
                    try FileManager.default.removeItem(atPath: path)
                }
                harness.store.update(jobID: job.id) { record in
                    for index in record.files.indices {
                        record.files[index].state = .gone
                    }
                }
            }
            try lockFolder(harness.recordings)

            XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id), "\(everyListedFileGone)")

            let record = try harness.record(of: job)
            XCTAssertEqual(harness.fakeTrash.moved, [], "\(everyListedFileGone)")
            XCTAssertNil(record.pending, "\(everyListedFileGone)")
            XCTAssertEqual(record.incomplete?.reason, MeetingReportScan.unreadableFolderReason, "\(everyListedFileGone)")
            XCTAssertEqual(record.incomplete?.kind, .meetingToTrash, "\(everyListedFileGone)")
            XCTAssertEqual(
                RecordingAudioLine.resolve(
                    record: record, live: nil, audio: RecordingAudioLine.AudioOnDisk(presentCount: 0, unreachableCount: 0, totalCount: 3, bytes: 0),
                    retention: .never, bundleID: nil, now: .now, calendar: .current, locale: .current,
                ).incompleteText,
                "Deletion incomplete: the notes folder could not be read to look for additional reports",
            )

            try unlockFolder(harness.recordings)
            XCTAssertTrue(controller.retryDeletion(jobID: job.id), "\(everyListedFileGone)")
            XCTAssertFalse(harness.isOnDisk(reports[0]), "\(everyListedFileGone)")
            XCTAssertNil(harness.store.record(for: job.id), "\(everyListedFileGone)")
        }
    }

    func testAMeetingAnotherRecordSharesKeepsItsReports() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let reports = try writeReports(["Short", "Minutes"], of: job, harness)
        let transcript = try XCTUnwrap(job.transcriptPath)
        let other = MeetingFileRecord(
            jobID: UUID(), origin: .recorded, recordingDate: nil,
            files: [MeetingFile(role: .transcript, url: transcript, owned: true)], createdBy: harness.store.bundleID,
        )
        XCTAssertTrue(harness.store.create(other), "test premise")

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(reports.filter(harness.isOnDisk), reports)
        XCTAssertEqual(try harness.record(of: job).incomplete?.reason, "3 files are also listed by another meeting")
    }

    // MARK: - Links

    func testAReportNamedLinkOrAFolderReplacedByALinkNeverLeadsToAMove() throws {
        let harness = try makeDeletionHarness()
        let job = try harness.recordedMeeting()
        let stem = try XCTUnwrap(job.transcriptPath).deletingPathExtension().lastPathComponent
        let elsewhere = harness.root.appendingPathComponent("elsewhere.md")
        try Data("# Not a report".utf8).write(to: elsewhere)
        let link = harness.recordings.appendingPathComponent("\(stem) (Short).md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        XCTAssertEqual(try MeetingReportScan.scan(harness.record(of: job)), MeetingReportScan())

        let moved = harness.outputDir.appendingPathComponent("moved-recordings")
        try FileManager.default.moveItem(at: harness.recordings, to: moved)
        try FileManager.default.createSymbolicLink(at: harness.recordings, withDestinationURL: moved)
        try FileManager.default.removeItem(at: moved.appendingPathComponent(link.lastPathComponent))
        try Data("# A real report".utf8).write(to: moved.appendingPathComponent(link.lastPathComponent))

        XCTAssertEqual(
            try MeetingReportScan.scan(harness.record(of: job)), MeetingReportScan(reports: [], unreadableFolder: true),
            "a folder that now resolves elsewhere counts as unreadable",
        )
        let controller = harness.controller(queue: harness.makeQueue())
        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))
        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertEqual(try harness.record(of: job).incomplete?.reason, MeetingReportScan.unreadableFolderReason)
    }

    // MARK: - Confirmation and crash

    func testAReportFoundAfterTheDialogOpenedStopsTheConfirmedAction() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let named = try Set(harness.record(of: job).filesCovered(by: .meetingToTrash).map(\.path))
        let reports = try writeReports(["Short"], of: job, harness)

        XCTAssertFalse(controller.moveMeetingToTrash(jobID: job.id, named: named))

        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertNil(try harness.record(of: job).pending)
        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id, named: named.union(reports)))
        XCTAssertFalse(harness.isOnDisk(reports[0]))
    }

    /// A crash after the save: the launch finds the reports in the record and offers
    /// the retry, which moves them.
    func testAnInterruptedDeletionComesBackWithItsReports() throws {
        let harness = try makeDeletionHarness()
        let job = try harness.recordedMeeting()
        let reports = try writeReports(["Short"], of: job, harness)
        let record = try harness.record(of: job)
        let covered = record.filesCovered(by: .meetingToTrash).map(\.path)
        XCTAssertTrue(harness.store.beginDeletion(
            jobID: job.id, kind: .meetingToTrash, paths: covered, adding: MeetingReportScan.scan(record).reports,
        ))
        harness.store.update(jobID: job.id) { record in
            record.pending = record.pending.map { .init(kind: $0.kind, paths: $0.paths, process: DeletionProcess(pid: .max, launchTime: .distantPast)) }
        }
        let controller = harness.controller()

        controller.activate { MockEngine() }

        let settled = try harness.record(of: job)
        XCTAssertEqual(settled.incomplete?.reason, MeetingFileRecord.interruptedReason)
        XCTAssertEqual(settled.incomplete?.paths.contains(reports[0]), true)
        XCTAssertTrue(controller.retryDeletion(jobID: job.id))
        XCTAssertFalse(harness.isOnDisk(reports[0]))
    }
}
