@testable import MeetingTranscriber
import XCTest

// MARK: - What the disk answers, the folder's scope and record pruning

extension RecordingRetentionControllerTests {
    private struct Refused: Error {}

    /// Runs `body` with `folder` out of reach, then brings it back.
    private func withFolderUnreachable(
        _ folder: URL, how: UnreachableHow, _ body: () async throws -> Void,
    ) async throws {
        let manager = FileManager.default
        switch how {
        case .movedAway:
            let away = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-unplugged")
            try manager.moveItem(at: folder, to: away)
            try await body()
            try manager.moveItem(at: away, to: folder)

        case .noPermission:
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            try await body()
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
    }

    enum UnreachableHow: CaseIterable {
        case movedAway
        case noPermission
    }

    // MARK: - Unreachable

    /// Audio and notes on a drive that is not there: nothing changes, and the check
    /// after it comes back deletes.
    func testAnUnreachableFolderDeletesNothingAndIsRetried() async throws {
        for how in UnreachableHow.allCases {
            let bed = try makeRetentionCheckBed()
            let record = try bed.meeting()

            try await withFolderUnreachable(bed.harness.recordings, how: how) {
                await bed.check()
                XCTAssertEqual(bed.removed, [], "\(how)")
                XCTAssertEqual(try bed.current(record), record, "\(how)")
            }

            await bed.check()
            try bed.assertAudioWent(record, "\(how)")
        }
    }

    /// The notes are there and only the audio is out of reach: no mark is written
    /// for a deletion that cannot touch anything, so the record's file is not rewritten.
    func testAudioOutOfReachWithTheNotesInPlaceChangesNothing() async throws {
        for how in UnreachableHow.allCases {
            let bed = try makeRetentionCheckBed()
            let drive = bed.harness.root.appendingPathComponent("drive", isDirectory: true)
            let record = try bed.meeting(audioFolder: drive)
            let written = FileIdentity.of(bed.harness.recordPath.path)
            XCTAssertNotNil(written, "test premise")

            try await withFolderUnreachable(drive, how: how) {
                await bed.check()
                XCTAssertEqual(bed.removed, [], "\(how)")
                XCTAssertEqual(try bed.current(record), record, "\(how)")
                XCTAssertEqual(FileIdentity.of(bed.harness.recordPath.path), written, "\(how)")
            }

            await bed.check()
            try bed.assertAudioWent(record, "\(how)")
        }
    }

    /// The notes are out of reach: they may be gone, so the audio stays.
    func testNotesOutOfReachKeepTheAudioAndTheirMark() async throws {
        let bed = try makeRetentionCheckBed()
        let drive = bed.harness.root.appendingPathComponent("drive", isDirectory: true)
        let record = try bed.meeting { record in
            record.files.removeAll { $0.role == .protocol }
            try record.files.append(bed.file(.protocol, "on_drive.md", in: drive))
        }

        try await withFolderUnreachable(drive, how: .movedAway) {
            await bed.check()
            XCTAssertEqual(bed.removed, [])
            XCTAssertEqual(try bed.current(record), record)
        }

        await bed.check()
        XCTAssertEqual(bed.removed.count, 6)
    }

    /// Part of the audio out of reach: the rest goes, the mark is cleared, no date
    /// is set, and the next check finishes and dates it. The mark names the file out
    /// of reach too, or a crash now would make the launch date a deletion with a file
    /// still on the other drive.
    func testPartlyReachableAudioGoesFileByFileAndIsDatedWhenTheLastOneGoes() async throws {
        let bed = try makeRetentionCheckBed()
        let drive = bed.harness.root.appendingPathComponent("drive", isDirectory: true)
        let onDrive = try bed.file(.mic16k, "on_drive.wav", in: drive)
        let record = try bed.meeting { record in
            record.files.removeAll { $0.role == .mic16k }
            record.files.append(onDrive)
        }
        var pendingPaths: [String] = []
        bed.beforeRemoval = { _ in
            pendingPaths = bed.store.record(for: record.jobID)?.pending?.paths ?? []
        }

        try await withFolderUnreachable(drive, how: .movedAway) {
            await bed.check()
        }

        XCTAssertTrue(pendingPaths.contains(onDrive.path))
        let partly = try bed.current(record)
        XCTAssertNil(partly.audioDeletion)
        XCTAssertNil(partly.pending)
        XCTAssertNil(partly.incomplete)
        XCTAssertEqual(partly.files.first { $0.path == onDrive.path }?.state, .present)
        XCTAssertTrue(bed.isOnDisk(onDrive.path))
        XCTAssertEqual(bed.removed.count, 5)

        bed.clock = bed.clock.addingTimeInterval(86400)
        await bed.check()

        try bed.assertAudioWent(record)
        XCTAssertEqual(bed.removed.count, 6)
    }

    // MARK: - Refused and replaced

    func testAFileThatCannotBeDeletedStaysListedAndIsRetried() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let stuck = bed.audioPaths(record)[2]
        bed.refusal = { $0.path == stuck ? Refused() : nil }

        await bed.check()

        let partly = try bed.current(record)
        XCTAssertTrue(bed.isOnDisk(stuck))
        XCTAssertEqual(partly.files.first { $0.path == stuck }?.state, .present)
        XCTAssertNil(partly.audioDeletion)
        XCTAssertNil(partly.pending, "the mark is cleared when the meeting is done")
        XCTAssertNil(partly.incomplete, "incomplete is for manual deletions")

        bed.refusal = { _ in nil }
        await bed.check()

        try bed.assertAudioWent(record)
    }

    /// What sits at the path is not what the record listed. It stays, whatever it is.
    /// Each case answers with what must still be there afterwards.
    func testAFileWhoseIdentityChangedStays() async throws {
        let manager = FileManager.default
        let mine = Data("mine".utf8)
        let cases: [(String, (String, URL) throws -> URL)] = [
            ("replaced by another file", { path, scratch in
                let new = scratch.appendingPathComponent("new.wav")
                try mine.write(to: new)
                _ = try manager.replaceItemAt(URL(filePath: path), withItemAt: new)
                return URL(filePath: path)
            }),
            ("a folder at the path", { path, _ in
                try manager.removeItem(atPath: path)
                try manager.createDirectory(atPath: path, withIntermediateDirectories: false)
                let inside = URL(filePath: path).appendingPathComponent("inside.txt")
                try mine.write(to: inside)
                return inside
            }),
            ("a symbolic link at the path", { path, scratch in
                let target = scratch.appendingPathComponent("target.wav")
                try mine.write(to: target)
                try manager.removeItem(atPath: path)
                try manager.createSymbolicLink(atPath: path, withDestinationPath: target.path)
                return target
            }),
        ]
        for (name, replace) in cases {
            let bed = try makeRetentionCheckBed()
            let record = try bed.meeting()
            let path = bed.audioPaths(record)[0]
            let survivor = try replace(path, makeTempDirectory(prefix: "retention_identity"))

            await bed.check()

            XCTAssertEqual(try Data(contentsOf: survivor), mine, "\(name): what sits at the path went")
            XCTAssertFalse(bed.removed.contains(URL(filePath: path).lastPathComponent), name)
            let now = try bed.current(record)
            XCTAssertEqual(now.files.first { $0.path == path }?.state, .present, name)
            XCTAssertNil(now.audioDeletion, name)
            XCTAssertEqual(bed.removed.count, 5, "\(name): the others went")
        }
    }

    /// The folder was swapped for a link to itself: the very same file, reached
    /// another way, which is not a path the record knows.
    func testAFolderReplacedByALinkLeavesItsFilesAlone() async throws {
        let bed = try makeRetentionCheckBed()
        let drive = bed.harness.root.appendingPathComponent("drive", isDirectory: true)
        let record = try bed.meeting(audioFolder: drive)
        let moved = bed.harness.root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: drive, to: moved)
        try FileManager.default.createSymbolicLink(at: drive, withDestinationURL: moved)

        await bed.check()

        XCTAssertEqual(bed.removed, [])
        XCTAssertNil(try bed.current(record).audioDeletion)
    }

    /// Another meeting still needs the file, also an import of it. Once that other
    /// entry is gone it holds nothing back.
    func testAPathAnotherMeetingListsStays() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let shared = try XCTUnwrap(record.files.first { $0.role == .mix })
        let other = try bed.meeting(origin: .imported, recorded: nil) { other in
            other.files.append(MeetingFile(role: .mix16k, path: shared.path, identity: shared.identity, owned: false, state: .present))
        }

        await bed.check()

        XCTAssertTrue(bed.isOnDisk(shared.path))
        XCTAssertEqual(try bed.current(record).files.first { $0.path == shared.path }?.state, .present)
        XCTAssertNil(try bed.current(record).audioDeletion)
        XCTAssertEqual(try bed.current(other).files.first { $0.path == shared.path }?.state, .present)

        bed.store.update(jobID: other.jobID) { now in
            for index in now.files.indices where now.files[index].path == shared.path {
                now.files[index].state = .gone
            }
        }
        await bed.check()

        try bed.assertAudioWent(record)
    }

    // MARK: - Already gone, and a mark that cannot be saved

    /// Nothing was deleted, so nothing says it was: the row reads "Audio not found".
    func testAudioRemovedBehindTheAppIsMarkedGoneWithoutADate() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        for path in bed.audioPaths(record) {
            try bed.removeBehindTheApp(path)
        }

        await bed.check()

        let now = try bed.current(record)
        XCTAssertEqual(now.files.filter(\.role.isAudio).map(\.state), bed.audioPaths(record).map { _ in .gone })
        XCTAssertNil(now.audioDeletion)
        XCTAssertNil(now.pending)
        XCTAssertEqual(bed.removed, [])
    }

    func testPartOfTheAudioRemovedBehindTheAppStillEndsInADate() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        try bed.removeBehindTheApp(bed.audioPaths(record)[0])

        await bed.check()

        try bed.assertAudioWent(record)
        XCTAssertEqual(bed.removed.count, 5)
    }

    /// Without its mark a crash could not be told from a deletion that never began,
    /// so nothing is touched, and a later check tries again.
    func testAMarkThatCannotBeSavedDeletesNothing() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let logs = bed.harness.logDir
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logs.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path) }

        await bed.check()

        XCTAssertEqual(bed.removed, [])
        for path in bed.audioPaths(record) {
            XCTAssertTrue(bed.isOnDisk(path))
        }

        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path)
        await bed.check()
        try bed.assertAudioWent(record)
    }

    /// Only the mark's write fails here, and every write after it would work, so
    /// nothing but the refused mark itself holds the deletion back. A folder at the
    /// staging path fails one write: a failed save removes it.
    func testAMarkThatFailsOnceStopsTheMeetingUntilTheNextCheck() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let staging = bed.harness.logDir.appendingPathComponent("meeting_files.json.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        await bed.check()

        XCTAssertEqual(bed.removed, [])
        try bed.assertUntouched(record)

        await bed.check()
        try bed.assertAudioWent(record)
    }

    // MARK: - The output folder's scope

    func testADeletionRunsInsideTheScopeOfTheChosenFolderAndClosesIt() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.setCustomOutputDir(bed.harness.outputDir)
        let root = try XCTUnwrap(bed.settings.customOutputDir, "test premise")
        try bed.meeting()
        try bed.meeting()
        var openWhileRemoving: Set<Int> = []
        bed.beforeRemoval = { [scopes = bed.harness.scopes] _ in
            openWhileRemoving.insert(scopes.opened.count - scopes.closed.count)
        }

        await bed.check()

        XCTAssertEqual(bed.removed.count, 12)
        XCTAssertEqual(bed.harness.scopes.opened.map(\.path), [root.path], "one scope for the whole pass")
        XCTAssertEqual(bed.harness.scopes.closed.map(\.path), [root.path], "left open")
        XCTAssertEqual(openWhileRemoving, [1])
    }

    /// `.fallback` stands in for a folder the user chose and is not reachable right
    /// now. Only paths from the record count, so a same-named file there is no one's.
    func testNoScopeIsOpenedForTheDefaultOrTheFallbackAndOnlyListedPathsGo() async throws {
        for usesFallback in [false, true] {
            let bed = try makeRetentionCheckBed()
            if usesFallback { bed.settings.customOutputDirBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF]) }
            let record = try bed.meeting(audioFolder: bed.harness.root.appendingPathComponent("elsewhere", isDirectory: true))
            let fallback = bed.settings.effectiveOutputDir.appendingPathComponent("recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            let sameName = fallback.appendingPathComponent(URL(filePath: bed.audioPaths(record)[0]).lastPathComponent)
            try Data("someone else's".utf8).write(to: sameName)

            await bed.check()

            try bed.assertAudioWent(record, "fallback: \(usesFallback)")
            XCTAssertTrue(bed.isOnDisk(sameName.path), "fallback: \(usesFallback)")
            XCTAssertEqual(bed.harness.scopes.opened, [], "fallback: \(usesFallback)")
        }
    }

    func testACheckWithNothingToDoOpensNoScope() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.setCustomOutputDir(bed.harness.outputDir)
        bed.settings.recordingRetention = .never
        let record = try bed.meeting()
        bed.listed = [record.jobID]

        await bed.check()

        XCTAssertEqual(bed.harness.scopes.opened, [])
    }

    // MARK: - Record pruning

    /// A meeting with nothing left and no row.
    private func emptyMeeting(_ bed: RetentionCheckBed, _ change: (inout MeetingFileRecord) -> Void = { _ in }) throws -> MeetingFileRecord {
        let record = try bed.meeting { record in
            record.outcome = .leftUnfinished
            change(&record)
        }
        for entry in record.files {
            try bed.removeBehindTheApp(entry.path)
        }
        return record
    }

    func testARecordWithNothingLeftGoesOnceItsRowIsGone() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try emptyMeeting(bed)
        bed.listed = [record.jobID]

        await bed.check()
        XCTAssertNotNil(bed.store.record(for: record.jobID), "its row is still listed")

        bed.listed = []
        await bed.check()
        XCTAssertNil(bed.store.record(for: record.jobID))
    }

    /// Pruning deletes no file, so Never does not stop it (R12 is about deleting).
    func testARecordIsPrunedAlsoUnderNever() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        let record = try emptyMeeting(bed)

        await bed.check()

        XCTAssertNil(bed.store.record(for: record.jobID))
    }

    /// A12: the audio was the last local file, and the row keeps its line and its
    /// Move Meeting to Trash… until it goes itself.
    func testAMeetingKeptOnlyInNotionKeepsItsRecordAndDateWhileItsRowIsListed() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting { record in
            record.savedToNotion = true
            record.files = record.files.filter(\.role.isAudio)
        }
        bed.listed = [record.jobID]

        await bed.check()

        try bed.assertAudioWent(record)
        await bed.check()
        try bed.assertAudioWent(record)

        bed.listed = []
        await bed.check()

        XCTAssertNil(bed.store.record(for: record.jobID))
    }

    func testARecordStaysWhileAnythingOfItMayStillExist() async throws {
        let bed = try makeRetentionCheckBed()
        let drive = bed.harness.root.appendingPathComponent("drive", isDirectory: true)
        // A file marked gone that came back from the Trash.
        let restored = try bed.meeting(outcome: .leftUnfinished) { $0.setFiles(.protocol, to: .gone) }
        for entry in restored.files where entry.role != .protocol {
            try bed.removeBehindTheApp(entry.path)
        }
        let onDrive = try bed.file(.mix, "unplugged.wav", in: drive)
        let unreachable = try bed.meeting(outcome: .leftUnfinished) { $0.files = [onDrive] }
        let pending = try emptyMeeting(bed) { $0.pending = .init(kind: .automatic, paths: []) }
        // Another build may be between moving a file and listing its new path.
        let inProgress = try emptyMeeting(bed) { $0.outcome = .inProgress }

        try await withFolderUnreachable(drive, how: .movedAway) {
            await bed.check()
            XCTAssertNotNil(bed.store.record(for: unreachable.jobID), "out of reach")
        }

        XCTAssertNotNil(bed.store.record(for: restored.jobID), "a file is back")
        XCTAssertNotNil(bed.store.record(for: pending.jobID), "a deletion is under way")
        XCTAssertNotNil(bed.store.record(for: inProgress.jobID), "in progress")
    }

    /// The probe suspends, so the answers are asked again after it.
    func testARowThatAppearsWhileTheDiskIsAskedKeepsTheRecord() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try emptyMeeting(bed)
        // Whether to scope the pass, whether to look at it, and after the disk answered.
        bed.onRowLookup = { id, count in
            if id == record.jobID, count == 3 { bed.listed = [id] }
        }

        await bed.check()

        XCTAssertNotNil(bed.store.record(for: record.jobID))
    }

    /// Under the lock, so another build's change after the check's read survives.
    func testRemovingARecordIsRefusedWhenItChangedSinceItWasRead() throws {
        let bed = try makeRetentionCheckBed()
        let read = try bed.meeting()
        let otherBuild = MeetingFileStore(path: bed.harness.recordPath)
        otherBuild.update(jobID: read.jobID) { $0.keep = true }

        XCTAssertFalse(bed.store.remove(unchanged: read))
        XCTAssertNotNil(bed.store.record(for: read.jobID))

        XCTAssertTrue(try bed.store.remove(unchanged: bed.current(read)))
        XCTAssertNil(bed.store.record(for: read.jobID))
    }
}
