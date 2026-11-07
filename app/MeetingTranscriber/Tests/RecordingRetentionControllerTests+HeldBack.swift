@testable import MeetingTranscriber
import XCTest

// MARK: - What the audio is held back by at the last moment

extension RecordingRetentionControllerTests {
    // MARK: - Notes that are no file

    /// What can stand at a notes path without being notes. `lstat` answers for each of
    /// them, so "something is there" is not enough to call the notes saved.
    private func notNotes() -> [(String, (String, URL) throws -> Void)] {
        let manager = FileManager.default
        return [
            ("an empty folder", { path, _ in
                try manager.removeItem(atPath: path)
                try manager.createDirectory(atPath: path, withIntermediateDirectories: false)
            }),
            ("a dangling link", { path, scratch in
                try manager.removeItem(atPath: path)
                try manager.createSymbolicLink(atPath: path, withDestinationPath: scratch.appendingPathComponent("nothing").path)
            }),
            ("a link to a folder", { path, scratch in
                try manager.removeItem(atPath: path)
                try manager.createSymbolicLink(atPath: path, withDestinationPath: scratch.path)
            }),
            ("a file that cannot be read", { path, _ in
                try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            }),
        ]
    }

    func testNotesThatAreNoReadableFileKeepTheAudio() async throws {
        let notesOff = MeetingFileRecord.Outcome.finished(protocolExpected: false)
        let flavours: [(MeetingFile.Role, MeetingFileRecord.Outcome)] = [
            (.protocol, .finished(protocolExpected: true)), (.transcript, notesOff),
        ]
        for (role, outcome) in flavours {
            for (name, replace) in notNotes() {
                let bed = try makeRetentionCheckBed()
                let record = try bed.meeting(outcome: outcome) { record in
                    if role == .transcript { record.files.removeAll { $0.role == .protocol } }
                }
                let notes = try XCTUnwrap(record.files.first { $0.role == role }?.path)
                try replace(notes, makeTempDirectory(prefix: "retention_notes"))

                await bed.check()

                XCTAssertEqual(bed.removed, [], "\(role): \(name)")
                XCTAssertEqual(try bed.current(record), record, "\(role): \(name)")
                for path in bed.audioPaths(record) {
                    XCTAssertTrue(bed.isOnDisk(path), "\(role): \(name): the audio is the last copy")
                }
            }
        }
    }

    /// The notes can be read through the link, so they are saved, and the file they
    /// are in stays: the gate above must not hold back more than what is no file.
    func testALinkToARealNotesFileCountsAsSaved() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let notes = try XCTUnwrap(record.files.first { $0.role == .protocol }?.path)
        let real = try makeTempDirectory(prefix: "retention_notes").appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: URL(filePath: notes), to: real)
        try FileManager.default.createSymbolicLink(atPath: notes, withDestinationPath: real.path)

        await bed.check()

        try bed.assertAudioWent(record)
        XCTAssertTrue(bed.isOnDisk(real.path))
    }

    // MARK: - A change after the deletion began

    /// Another build's Keep arrives once this deletion's mark is saved. It is refused
    /// under the lock the mark was written under, so Keep never reads as saved beside
    /// audio that went: either it landed first, which the mark's own look refuses, or
    /// the row goes on saying that the audio went.
    func testKeepFromAnotherBuildIsRefusedOnceTheDeletionBegan() async throws {
        let bed = try makeRetentionCheckBed()
        let otherBuild = MeetingFileStore(path: bed.harness.recordPath)
        let record = try bed.meeting()
        var answers: [Bool] = []
        bed.beforeRemoval = { _ in
            answers.append(otherBuild.setKeep(true, jobID: record.jobID))
        }

        await bed.check()

        XCTAssertEqual(Set(answers), [false])
        XCTAssertFalse(try bed.current(record).keep)
        try bed.assertAudioWent(record)
    }

    /// With no deletion under way Keep goes in, both ways, and false says it did not:
    /// no record, or a deletion of the meeting pending.
    func testKeepIsDecidedUnderTheLock() throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()

        XCTAssertTrue(bed.store.setKeep(true, jobID: record.jobID))
        XCTAssertTrue(try bed.current(record).keep)
        XCTAssertTrue(bed.store.setKeep(false, jobID: record.jobID))
        XCTAssertFalse(try bed.current(record).keep)
        XCTAssertFalse(bed.store.setKeep(true, jobID: UUID()))

        XCTAssertTrue(bed.store.beginDeletion(jobID: record.jobID, kind: .audioToTrash, paths: []))
        XCTAssertFalse(bed.store.setKeep(true, jobID: record.jobID))
        XCTAssertFalse(try bed.current(record).keep)
    }

    /// A write that takes no notice of the mark, as a build from before this one's
    /// Keep or the pipeline's outcome does, lands while the files go. Each file asks
    /// the record under the lock, so what has not gone yet stays, and nothing dates it.
    func testAChangeWhileTheFilesGoStopsTheOnesStillToGo() async throws {
        let cases: [(String, (inout MeetingFileRecord) -> Void)] = [
            ("Keep", { $0.keep = true }),
            ("Retry", { $0.outcome = .inProgress }),
            ("failed", { $0.outcome = .failed }),
            ("left unfinished", { $0.outcome = .leftUnfinished }),
            ("excluded", { $0.excludedFromAutomaticDeletion = true }),
            ("a failed deletion", { $0.incomplete = .init(reason: "r", paths: [], kind: .audioToTrash) }),
            ("notes gone", { record in
                for index in record.files.indices where record.files[index].role == .protocol {
                    record.files[index].state = .gone
                }
            }),
        ]
        for (name, change) in cases {
            let bed = try makeRetentionCheckBed()
            let otherBuild = MeetingFileStore(path: bed.harness.recordPath)
            let record = try bed.meeting()
            bed.beforeRemoval = { _ in
                otherBuild.update(jobID: record.jobID, change)
            }

            await bed.check()

            XCTAssertEqual(bed.removed.count, 1, "\(name): the file already started goes, the rest stay")
            let now = try bed.current(record)
            XCTAssertNil(now.audioDeletion, name)
            XCTAssertNil(now.pending, name)
            let left = bed.audioPaths(record).dropFirst()
            for path in left {
                XCTAssertTrue(bed.isOnDisk(path), name)
                XCTAssertEqual(now.files.first { $0.path == path }?.state, .present, name)
            }

            await bed.check()
            XCTAssertEqual(bed.removed.count, 1, "\(name): the next check holds as well")
        }
    }

    /// The hold is the automatic check's: a kept meeting's audio can still go by hand.
    func testAManualDeletionIsNotHeldBackByWhatStopsAnAutomaticOne() throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting { $0.keep = true }
        let path = bed.audioPaths(record)[0]

        XCTAssertTrue(bed.store.beginDeletion(jobID: record.jobID, kind: .audioToTrash, paths: [path]))

        XCTAssertEqual(bed.store.startRemoving(path: path, jobID: record.jobID), .marked)
    }

    func testAnAutomaticDeletionAsksTheRecordBeforeEachFile() throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let paths = bed.audioPaths(record)
        XCTAssertTrue(bed.store.beginDeletion(jobID: record.jobID, kind: .automatic, paths: paths))

        XCTAssertEqual(bed.store.startRemoving(path: paths[0], jobID: record.jobID), .marked)
        bed.store.update(jobID: record.jobID) { $0.keep = true }

        XCTAssertEqual(bed.store.startRemoving(path: paths[1], jobID: record.jobID), .meetingChanged)
        XCTAssertEqual(try bed.current(record).files.first { $0.path == paths[1] }?.state, .present)
    }

    // MARK: - Nothing the app could delete

    /// The launch dates an automatic deletion whose mark it finds with every file gone,
    /// so a crash right after a mark would say the app deleted what someone else
    /// removed. The record file is looked at after each write, as a crash would find it.
    func testAudioAllGoneGetsNoMarkACrashCouldDate() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        for path in bed.audioPaths(record) {
            try bed.removeBehindTheApp(path)
        }
        var marks = 0
        bed.onEveryRecordWrite {
            if bed.recordFileHoldsADeletionMark { marks += 1 }
        }

        await bed.check()

        XCTAssertEqual(marks, 0)
        let now = try bed.current(record)
        XCTAssertEqual(now.files.filter(\.role.isAudio).map(\.state), bed.audioPaths(record).map { _ in .gone })
        XCTAssertNil(now.audioDeletion)

        try bed.meeting()
        await bed.check()
        XCTAssertGreaterThan(marks, 0, "test premise: a real deletion's mark is seen")
    }

    /// Nothing there to delete either: what is gone is marked, no deletion begins, and
    /// once the drive is back the last file goes and dates it.
    func testAudioPartlyGoneAndPartlyOutOfReachGetsNoMark() async throws {
        let bed = try makeRetentionCheckBed()
        let drive = bed.harness.root.appendingPathComponent("drive", isDirectory: true)
        let onDrive = try bed.file(.mic16k, "on_drive.wav", in: drive)
        let record = try bed.meeting { record in
            record.files.removeAll { $0.role == .mic16k }
            record.files.append(onDrive)
        }
        for path in bed.audioPaths(record) where path != onDrive.path {
            try bed.removeBehindTheApp(path)
        }
        var marks = 0
        bed.onEveryRecordWrite {
            if bed.recordFileHoldsADeletionMark { marks += 1 }
        }
        let away = drive.deletingLastPathComponent().appendingPathComponent("drive-unplugged")
        try FileManager.default.moveItem(at: drive, to: away)

        await bed.check()

        XCTAssertEqual(marks, 0)
        let now = try bed.current(record)
        XCTAssertEqual(now.files.first { $0.path == onDrive.path }?.state, .present)
        XCTAssertEqual(now.files.filter { $0.role.isAudio && $0.path != onDrive.path }.map(\.state), Array(repeating: .gone, count: 5))
        XCTAssertNil(now.audioDeletion)

        try FileManager.default.moveItem(at: away, to: drive)
        await bed.check()

        XCTAssertEqual(bed.removed, [URL(filePath: onDrive.path).lastPathComponent])
        XCTAssertNotNil(try bed.current(record).audioDeletion)
    }
}
