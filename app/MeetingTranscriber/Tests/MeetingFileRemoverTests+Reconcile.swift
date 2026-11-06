@testable import MeetingTranscriber
import XCTest

// MARK: - The pending mark, and what a launch makes of it

/// A deletion saves what it is about to do first, so a crash during it can be told
/// from one that never started, and from one the other running build is doing now.
extension MeetingFileRemoverTests {
    private static let deadProcess = DeletionProcess(pid: 41, launchTime: .distantPast)

    // MARK: - Pending deletion

    func testAPendingDeletionIsSavedBeforeItStartsAndOnlyOneAtATime() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)

        XCTAssertTrue(store.beginDeletion(jobID: jobID, kind: .audioToTrash, paths: [file.path]))

        let onFile = MeetingFileStore(path: dir.appendingPathComponent("logs/meeting_files.json"))
        let pending = try XCTUnwrap(onFile.record(for: jobID)?.pending)
        XCTAssertEqual(pending.kind, .audioToTrash)
        XCTAssertEqual(pending.paths, [file.path])
        XCTAssertEqual(pending.process, .current)
        XCTAssertFalse(store.beginDeletion(jobID: jobID, kind: .meetingToTrash, paths: []), "a second one started")
        XCTAssertEqual(store.record(for: jobID)?.pending?.kind, .audioToTrash)
        XCTAssertFalse(store.beginDeletion(jobID: UUID(), kind: .audioToTrash, paths: []), "a meeting without a record")
    }

    /// Takes write permission from the record's folder for the rest of the test.
    private func makeRecordFolderReadOnly() throws {
        let folder = dir.appendingPathComponent("logs")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let path = folder.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    func testAPendingWriteThatFailsStartsNothing() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)
        try makeRecordFolderReadOnly()

        XCTAssertFalse(store.beginDeletion(jobID: jobID, kind: .audioToTrash, paths: [file.path]))
        XCTAssertNil(store.record(for: jobID)?.pending)
    }

    /// A file is only ever touched with its mark on disk, so a crash cannot leave
    /// one gone that the record calls present.
    func testAMarkThatCannotBeSavedLeavesTheFile() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)
        try makeRecordFolderReadOnly()

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .failed(.recordNotSaved))])
        XCTAssertTrue(onDisk(file))
        XCTAssertEqual(fakeTrash.moved, [])
    }

    // MARK: - Whether the owner of a pending deletion still runs

    func testThisProcessIsRunningAndOthersAreToldByPIDAndLaunchTime() {
        let current = DeletionProcess.current
        XCTAssertEqual(current.pid, getpid())
        XCTAssertGreaterThan(current.launchTime, Date(timeIntervalSince1970: 1_000_000_000), "not the kernel's start time")
        XCTAssertLessThanOrEqual(current.launchTime, Date())
        XCTAssertTrue(DeletionProcess.isRunning(current))
        XCTAssertFalse(
            DeletionProcess.isRunning(.init(pid: current.pid, launchTime: current.launchTime.addingTimeInterval(-1))),
            "a later process that reuses the ID read as the owner",
        )
        XCTAssertFalse(DeletionProcess.isRunning(.init(pid: .max, launchTime: current.launchTime)), "no such process")
    }

    func testAProcessSurvivesTheRecordFile() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)
        XCTAssertTrue(store.beginDeletion(jobID: jobID, kind: .audioToTrash, paths: [file.path]))

        let onFile = MeetingFileStore(path: dir.appendingPathComponent("logs/meeting_files.json"))

        XCTAssertTrue(try DeletionProcess.isRunning(XCTUnwrap(onFile.record(for: jobID)?.pending?.process)))
    }

    // MARK: - Launch reconcile

    /// Three files, stopped between the first and the second: the first went, the
    /// second was marked and may or may not have gone, the third was not reached.
    private func interruptedDeletion(
        kind: MeetingFileRecord.DeletionKind, secondWent: Bool = false, process: DeletionProcess? = nil,
    ) throws -> [MeetingFile] {
        let files = try storeMeeting(["first.wav", "second.wav", "third.wav"])
        try FileManager.default.removeItem(atPath: files[0].path)
        if secondWent { try FileManager.default.removeItem(atPath: files[1].path) }
        store.update(jobID: jobID) { record in
            record.files[0].state = .gone
            record.files[1].state = .deleting
            record.pending = .init(kind: kind, paths: files.map(\.path), process: process ?? Self.deadProcess)
        }
        return files
    }

    private func reconcile(isRunning: (DeletionProcess) -> Bool = { _ in false }) -> [UUID] {
        store.reconcileInterruptedDeletions(now: Date(timeIntervalSinceReferenceDate: 800_000_000), isRunning: isRunning)
    }

    func testAnInterruptedManualDeletionBecomesIncompleteWithTheSameKind() throws {
        for kind in [MeetingFileRecord.DeletionKind.audioToTrash, .meetingToTrash] {
            let files = try interruptedDeletion(kind: kind)

            XCTAssertEqual(reconcile(), [], "\(kind): files are left, so the meeting stays")

            let record = try XCTUnwrap(store.record(for: jobID))
            XCTAssertNil(record.pending, "\(kind)")
            XCTAssertEqual(record.incomplete?.kind, kind)
            XCTAssertEqual(record.incomplete?.paths, [files[1].path, files[2].path], "\(kind)")
            XCTAssertEqual(record.incomplete?.reason, "the app quit before the deletion finished")
            XCTAssertEqual(record.files.map(\.state), [.gone, .present, .present], "\(kind)")
            XCTAssertNil(record.audioDeletion, "\(kind)")
            store.remove(jobID: jobID)
        }
    }

    /// The move landed and the crash came before the mark.
    func testAFileMarkedDeletingThatWentIsGoneAfterTheReconcile() throws {
        let files = try interruptedDeletion(kind: .audioToTrash, secondWent: true)

        _ = reconcile()

        XCTAssertEqual(state(of: files[1]), .gone)
        XCTAssertEqual(store.record(for: jobID)?.incomplete?.paths, [files[2].path])
    }

    func testAFileMarkedDeletingThatCannotBeReachedStaysListedAsPresent() throws {
        let files = try interruptedDeletion(kind: .audioToTrash)
        try FileManager.default.moveItem(at: recordings, to: dir.appendingPathComponent("unplugged"))

        _ = reconcile()

        XCTAssertEqual(state(of: files[1]), .present)
        XCTAssertEqual(store.record(for: jobID)?.incomplete?.paths, [files[1].path, files[2].path])
    }

    /// An interrupted automatic deletion leaves nothing for the row to say: the
    /// next check runs it again.
    func testAnInterruptedAutomaticDeletionIsClearedWithoutIncomplete() throws {
        _ = try interruptedDeletion(kind: .automatic)

        XCTAssertEqual(reconcile(), [])

        let record = try XCTUnwrap(store.record(for: jobID))
        XCTAssertNil(record.pending)
        XCTAssertNil(record.incomplete)
        XCTAssertNil(record.audioDeletion)
        XCTAssertEqual(record.files.map(\.state), [.gone, .present, .present])
    }

    /// Everything had gone, so it is finished, and the row can say when.
    func testAnInterruptedAutomaticDeletionWithNothingLeftIsFinished() throws {
        let files = try interruptedDeletion(kind: .automatic, secondWent: true)
        try FileManager.default.removeItem(atPath: files[2].path)

        XCTAssertEqual(reconcile(), [])

        let record = try XCTUnwrap(store.record(for: jobID))
        XCTAssertNil(record.pending)
        XCTAssertNil(record.incomplete)
        XCTAssertEqual(record.audioDeletion, .init(kind: .automatic, at: Date(timeIntervalSinceReferenceDate: 800_000_000)))
    }

    func testAPendingDeletionOfALiveProcessIsLeftAlone() throws {
        _ = try interruptedDeletion(kind: .audioToTrash, process: .current)
        let before = store.record(for: jobID)
        var asked: [DeletionProcess] = []

        let finished = reconcile { process in
            asked.append(process)
            return true
        }

        XCTAssertEqual(asked, [.current])
        XCTAssertEqual(finished, [])
        XCTAssertEqual(store.record(for: jobID), before)
    }

    /// The other build started a deletion of its own while this one was looking at
    /// the disk, which happens outside the lock. What it saved stands.
    func testAPendingDeletionThatChangedDuringTheCheckIsLeftAlone() throws {
        _ = try interruptedDeletion(kind: .audioToTrash)
        let otherBuild = MeetingFileStore(path: dir.appendingPathComponent("logs/meeting_files.json"))
        let replacement = MeetingFileRecord.PendingDeletion(kind: .meetingToTrash, paths: [], process: .current)

        let finished = reconcile { [jobID] _ in
            otherBuild.update(jobID: jobID) { $0.pending = replacement }
            return false
        }

        XCTAssertEqual(finished, [])
        XCTAssertEqual(store.record(for: jobID)?.pending, replacement)
        XCTAssertNil(store.record(for: jobID)?.incomplete)
    }

    func testAnInterruptedAudioDeletionWithNothingLeftCompletes() throws {
        let files = try interruptedDeletion(kind: .audioToTrash, secondWent: true)
        try FileManager.default.removeItem(atPath: files[2].path)

        XCTAssertEqual(reconcile(), [])

        let record = try XCTUnwrap(store.record(for: jobID))
        XCTAssertNil(record.pending)
        XCTAssertNil(record.incomplete)
        XCTAssertEqual(record.audioDeletion, .init(kind: .manual, at: Date(timeIntervalSinceReferenceDate: 800_000_000)))
        XCTAssertEqual(record.files.map(\.state), [.gone, .gone, .gone])
    }

    /// The record goes last, by the caller, so a crash before that is reconciled
    /// the same way at the next launch.
    func testAnInterruptedMeetingDeletionWithNothingLeftIsHandedToTheCaller() throws {
        let files = try interruptedDeletion(kind: .meetingToTrash, secondWent: true)
        try FileManager.default.removeItem(atPath: files[2].path)

        XCTAssertEqual(reconcile(), [jobID])

        XCTAssertEqual(store.record(for: jobID)?.pending?.kind, .meetingToTrash)
    }
}
