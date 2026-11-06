@testable import MeetingTranscriber
import XCTest

/// The record file: what survives a restart, and what stays intact when a second
/// running build of the app writes to the same file.
@MainActor
final class MeetingFileStoreTests: XCTestCase {
    private func makePath() throws -> URL {
        try makeTempDirectory(prefix: "meeting-file-store").appendingPathComponent("meeting_files.json")
    }

    private func makeRecord(id: UUID = UUID(), origin: MeetingFileRecord.Origin = .recorded) -> MeetingFileRecord {
        MeetingFileRecord(
            jobID: id, origin: origin, recordingDate: Date(timeIntervalSinceReferenceDate: 780_000_000),
            files: [MeetingFile(
                role: .mix, path: "/output/recordings/meeting_mix.wav",
                identity: FileIdentity(device: 7, inode: 42), owned: origin == .recorded, state: .present,
            )],
        )
    }

    private func lockPath(of path: URL) -> String {
        path.path + ".lock"
    }

    /// A descriptor on the lock file, the way another process's store holds it.
    private func holdLock(of path: URL) -> Int32 {
        let descriptor = open(lockPath(of: path), O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0, "test premise: this handle holds the lock")
        return descriptor
    }

    private func isLockFree(at path: URL) -> Bool {
        let descriptor = open(lockPath(of: path), O_RDWR | O_CREAT, 0o600)
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    // MARK: - Round trip

    func testARecordSurvivesInANewStoreWithEveryField() throws {
        let path = try makePath()
        var record = makeRecord()
        record.keep = true
        record.outcome = .finished(protocolExpected: false)
        record.audioDeletion = .init(kind: .automatic, at: Date(timeIntervalSinceReferenceDate: 790_000_000))
        record.incomplete = .init(reason: "this volume has no Trash", paths: ["/a"], kind: .audioToTrash)
        record.pending = .init(kind: .meetingToTrash, paths: ["/a", "/b"])
        record.excludedFromAutomaticDeletion = true
        record.savedToNotion = true

        let store = MeetingFileStore(path: path)
        XCTAssertTrue(store.create(record))

        XCTAssertEqual(store.record(for: record.jobID), record)
        XCTAssertEqual(MeetingFileStore(path: path).records, [record])
    }

    func testARecordCanBeChangedAndRemoved() throws {
        let path = try makePath()
        let store = MeetingFileStore(path: path)
        let record = makeRecord()
        store.create(record)

        XCTAssertTrue(store.update(jobID: record.jobID) { $0.keep = true })
        XCTAssertEqual(MeetingFileStore(path: path).record(for: record.jobID)?.keep, true)

        XCTAssertTrue(store.remove(jobID: record.jobID))
        XCTAssertNil(store.record(for: record.jobID))
        XCTAssertEqual(MeetingFileStore(path: path).records, [])
    }

    /// The first record stands: its recording date is written once, and nothing
    /// that enters the same job twice may reset a Keep or a deletion state.
    func testCreatingARecordTheStoreHasKeepsTheFirst() throws {
        let store = try MeetingFileStore(path: makePath())
        let record = makeRecord()
        store.create(record)
        store.update(jobID: record.jobID) { $0.keep = true }

        XCTAssertTrue(store.create(record))

        XCTAssertEqual(store.record(for: record.jobID)?.keep, true)
        XCTAssertEqual(store.records.count, 1)
    }

    func testChangingARecordThatDoesNotExistIsNotSaved() throws {
        let store = try MeetingFileStore(path: makePath())

        XCTAssertFalse(store.update(jobID: UUID()) { $0.keep = true })
    }

    func testReloadPicksUpWhatAnotherStoreWrote() throws {
        let path = try makePath()
        let first = MeetingFileStore(path: path)
        let record = makeRecord()
        MeetingFileStore(path: path).create(record)
        XCTAssertEqual(first.records, [], "test premise: a store reads the file only when asked")

        first.reload()

        XCTAssertEqual(first.records, [record])
    }

    /// The same sensitivity as `terminal_jobs.json`: output paths and slugs.
    func testTheFileIsOwnerOnly() throws {
        let path = try makePath()
        MeetingFileStore(path: path).create(makeRecord())

        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// Only the fields a record cannot exist without are required.
    func testARecordWithOnlyItsRequiredFieldsReadsWithTheDefaults() throws {
        let id = UUID()
        let json = #"{"jobID":"\#(id.uuidString)","origin":"recorded","files":[],"aFieldFromALaterVersion":1}"#

        let record = try JSONDecoder().decode(MeetingFileRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record, MeetingFileRecord(jobID: id, origin: .recorded, recordingDate: nil, files: []))
        XCTAssertEqual(record.outcome, .inProgress)
        XCTAssertFalse(record.keep)
        XCTAssertFalse(record.excludedFromAutomaticDeletion)
        XCTAssertFalse(record.savedToNotion)
    }

    func testAudioRolesAreTheThreeTracksAndTheirCopies() {
        let audio: [MeetingFile.Role] = [.mix, .appTrack, .micTrack, .mix16k, .app16k, .mic16k]
        let others: [MeetingFile.Role] = [.segments, .naming, .transcript, .protocol, .previousProtocol]

        XCTAssertTrue(audio.allSatisfy(\.isAudio))
        XCTAssertFalse(others.contains(where: \.isAudio))
    }

    // MARK: - Since

    /// Written when the file is first created, before any record: a recording
    /// made after this version's first launch and recovered after a crash must
    /// not read as one from before the feature.
    func testSinceIsWrittenWhenTheStoreFirstCreatesTheFile() throws {
        let path = try makePath()
        let before = Date()

        let store = MeetingFileStore(path: path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "no record yet, but the file records since")
        XCTAssertGreaterThanOrEqual(store.since, before)
        XCTAssertLessThanOrEqual(store.since, Date())
        XCTAssertEqual(MeetingFileStore(path: path).since, store.since)
    }

    func testSinceIsKeptAcrossWritesAndNewStores() throws {
        let path = try makePath()
        let since = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try Data(#"{"since":700000000,"records":[]}"#.utf8).write(to: path)

        let store = MeetingFileStore(path: path)
        XCTAssertEqual(store.since, since)
        let record = makeRecord()
        store.create(record)
        store.update(jobID: record.jobID) { $0.keep = true }
        store.remove(jobID: record.jobID)

        XCTAssertEqual(MeetingFileStore(path: path).since, since)
    }

    // MARK: - Two running builds on one file

    func testTwoStoresEachWritingTheirOwnRecordKeepBoth() throws {
        let path = try makePath()
        let (one, other) = (MeetingFileStore(path: path), MeetingFileStore(path: path))
        let (first, second) = (makeRecord(), makeRecord())

        XCTAssertTrue(one.create(first))
        XCTAssertTrue(other.create(second))

        XCTAssertEqual(MeetingFileStore(path: path).records, [first, second])
        XCTAssertEqual(other.records, [first, second], "a write adopts what it read from the file")
    }

    /// The change applies to the file's copy of the record, not to the copy this
    /// store happened to read earlier.
    func testAKeepSetByAnotherStoreSurvivesAnOutcomeChange() throws {
        let path = try makePath()
        let (one, other) = (MeetingFileStore(path: path), MeetingFileStore(path: path))
        let record = makeRecord()
        one.create(record)
        other.reload()

        other.update(jobID: record.jobID) { $0.keep = true }
        XCTAssertEqual(one.record(for: record.jobID)?.keep, false, "test premise: this store has not seen the Keep")
        one.update(jobID: record.jobID) { $0.outcome = .failed }

        let onDisk = try XCTUnwrap(MeetingFileStore(path: path).record(for: record.jobID))
        XCTAssertTrue(onDisk.keep)
        XCTAssertEqual(onDisk.outcome, .failed)
    }

    /// Re-reading alone would not be enough: two processes could both read
    /// before either writes. So the change itself runs under the lock.
    func testTheLockIsHeldAcrossAChangeAndReleasedAfterIt() throws {
        let path = try makePath()
        let store = MeetingFileStore(path: path)
        let record = makeRecord()
        store.create(record)
        var freeDuringTheChange = true

        store.update(jobID: record.jobID) { _ in freeDuringTheChange = self.isLockFree(at: path) }

        XCTAssertFalse(freeDuringTheChange)
        XCTAssertTrue(isLockFree(at: path))
    }

    func testAWriteWaitsForTheLockAndLandsAfterItIsReleased() throws {
        let path = try makePath()
        let store = MeetingFileStore(path: path)
        let record = makeRecord()
        let holder = holdLock(of: path)
        let released = DispatchTime.now() + 0.3
        DispatchQueue.global().asyncAfter(deadline: released) {
            close(holder)
        }

        let start = ContinuousClock.now
        XCTAssertTrue(store.create(record))
        let waited = ContinuousClock.now - start

        XCTAssertGreaterThanOrEqual(waited, .milliseconds(250), "the write went ahead while the lock was held")
        XCTAssertEqual(MeetingFileStore(path: path).records, [record])
    }

    /// The main actor runs these writes, so a stuck holder must cost at most the
    /// bound. The file is untouched and the next write succeeds.
    func testAWriteFailsWhenTheLockStaysHeldPastTheBound() throws {
        let path = try makePath()
        let store = MeetingFileStore(path: path)
        let holder = holdLock(of: path)
        let record = makeRecord()

        let start = ContinuousClock.now
        XCTAssertFalse(store.create(record))
        let waited = ContinuousClock.now - start

        XCTAssertGreaterThanOrEqual(waited, .seconds(1), "gave up without waiting")
        XCTAssertLessThan(waited, .seconds(5), "must not hang the main actor")
        XCTAssertNil(store.record(for: record.jobID))

        close(holder)
        XCTAssertTrue(store.create(record))
    }

    // MARK: - Damage

    /// Not overwritten by an empty list: what it held may still be recoverable.
    func testACorruptFileIsMovedAsideWhenTheStoreOpensIt() throws {
        let path = try makePath()
        let garbage = Data("not json".utf8)
        try garbage.write(to: path)

        let store = MeetingFileStore(path: path)

        XCTAssertEqual(store.records, [])
        XCTAssertEqual(try Data(contentsOf: corruptPath(of: path)), garbage)
        XCTAssertTrue(store.create(makeRecord()))
        XCTAssertEqual(try Data(contentsOf: corruptPath(of: path)), garbage)
        XCTAssertEqual(MeetingFileStore(path: path).records.count, 1)
    }

    func testAFileCorruptedWhileTheStoreRunsIsMovedAsideOnTheNextWrite() throws {
        let path = try makePath()
        let store = MeetingFileStore(path: path)
        let garbage = Data("not json".utf8)
        try garbage.write(to: path)

        XCTAssertTrue(store.create(makeRecord()))

        XCTAssertEqual(try Data(contentsOf: corruptPath(of: path)), garbage)
        XCTAssertEqual(MeetingFileStore(path: path).records.count, 1)
    }

    /// A read that failed says nothing about the file's content, so it stays
    /// where it is and the write that needed it fails.
    func testAFileThatCannotBeReadIsNeitherMovedAsideNorOverwritten() throws {
        let path = try makePath()
        let store = MeetingFileStore(path: path)
        let record = makeRecord()
        store.create(record)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        let filePath = path.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
        }

        XCTAssertFalse(store.create(makeRecord()))

        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptPath(of: path).path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        XCTAssertEqual(MeetingFileStore(path: path).records, [record])
    }

    func testAWriteIntoAnUnwritableFolderReturnsFalse() throws {
        let path = try makePath()
        let folder = path.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let folderPath = folder.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderPath)
        }

        let store = MeetingFileStore(path: path)
        let record = makeRecord()

        XCTAssertFalse(store.create(record))
        XCTAssertNil(store.record(for: record.jobID), "memory follows the file, and the file has nothing")
    }

    private func corruptPath(of path: URL) -> URL {
        path.deletingLastPathComponent().appendingPathComponent("meeting_files.json.corrupt")
    }
}
