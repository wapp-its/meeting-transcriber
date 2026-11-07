@testable import MeetingTranscriber
import XCTest

/// Stands in for the Trash: moves into a folder of its own or throws, so no test
/// ever touches the real one.
final class FakeTrash {
    let folder: URL
    /// The file names it took, in order.
    private(set) var moved: [String] = []
    /// What it answers for a file; nil takes the file.
    var refusal: (URL) -> (any Error)? = { _ in nil }
    /// Runs before each move, to look at the state the record is in at that moment.
    var beforeMove: (URL) -> Void = { _ in }

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func take(_ url: URL) throws {
        beforeMove(url)
        if let error = refusal(url) { throw error }
        let name = url.lastPathComponent
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(moved.count)-\(name)"))
        moved.append(name)
    }
}

/// The mover and the record it keeps, against a temporary folder: a file leaves
/// only while it is still the file the record names, a refused Trash never turns
/// into a permanent delete, and a deletion a crash interrupted can be told from
/// one still running.
@MainActor
final class MeetingFileRemoverTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // The fixture and the helpers down to `onDisk` are shared with
    // MeetingFileRemoverTests+Reconcile.swift, which a private one would not reach.
    // swiftlint:disable test_case_accessibility
    // swiftlint:disable implicitly_unwrapped_optional
    var dir: URL!
    var recordings: URL!
    var store: MeetingFileStore!
    var fakeTrash: FakeTrash!
    // swiftlint:enable implicitly_unwrapped_optional
    /// What the injected permanent delete was asked to remove.
    var deletedForGood: [String] = []

    let jobID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "meeting-file-remover")
        recordings = dir.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        store = MeetingFileStore(path: dir.appendingPathComponent("logs/meeting_files.json"))
        fakeTrash = try FakeTrash(folder: dir.appendingPathComponent("fake-trash", isDirectory: true))
        deletedForGood = []
    }

    var remover: MeetingFileRemover {
        MeetingFileRemover(
            trash: { [fakeTrash] in try fakeTrash?.take($0) },
            removeForGood: { [weak self] url in
                self?.deletedForGood.append(url.lastPathComponent)
                try FileManager.default.removeItem(at: url)
            },
        )
    }

    func makeFile(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? recordings).appendingPathComponent(name)
        try Data("audio of \(name)".utf8).write(to: url)
        return url
    }

    /// A finished recorded meeting with these files on disk, its record stored.
    @discardableResult
    func storeMeeting(_ names: [String], id: UUID? = nil, role: MeetingFile.Role = .mix) throws -> [MeetingFile] {
        let files = try names.map { try MeetingFile(role: role, url: makeFile($0), owned: true) }
        store.create(MeetingFileRecord(
            jobID: id ?? jobID, origin: .recorded, recordingDate: Date(), files: files,
            outcome: .finished(protocolExpected: true),
        ))
        return files
    }

    func state(of file: MeetingFile, job: UUID? = nil) -> MeetingFile.State? {
        store.record(for: job ?? jobID)?.files.first { $0.path == file.path }?.state
    }

    func onDisk(_ file: MeetingFile) -> Bool {
        MeetingFilePresence.of(file.path) == .present
    }

    // swiftlint:enable test_case_accessibility

    // MARK: - Moving and deleting

    func testAFileMovesToTheTrashMarkedDeletingOnTheWayAndGoneAfter() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)
        var stateDuringTheMove: MeetingFile.State?
        fakeTrash.beforeMove = { [self] _ in stateDuringTheMove = state(of: file) }

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .removed)])
        XCTAssertEqual(stateDuringTheMove, .deleting, "the record must say so before the file goes")
        XCTAssertEqual(state(of: file), .gone)
        XCTAssertEqual(fakeTrash.moved, ["m_mix.wav"])
        XCTAssertFalse(onDisk(file))
        XCTAssertEqual(deletedForGood, [])
    }

    func testDeletingForGoodNeverGoesThroughTheTrash() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)

        let outcomes = remover.remove([file], mode: .forGood, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .removed)])
        XCTAssertEqual(deletedForGood, ["m_mix.wav"])
        XCTAssertEqual(fakeTrash.moved, [])
        XCTAssertEqual(state(of: file), .gone)
    }

    /// D6: a manual mistake stays recoverable, so a volume without a Trash is
    /// reported and never turned into a permanent delete.
    func testARefusingTrashLeavesTheFileGivesTheReasonAndNeverDeletesForGood() throws {
        let otherError = CocoaError(.fileWriteNoPermission)
        let cases: [(error: any Error, reason: String)] = [
            (CocoaError(.featureUnsupported), "this volume has no Trash"),
            (POSIXError(.ENOTSUP), "this volume has no Trash"),
            (otherError, otherError.localizedDescription),
        ]
        for (index, testCase) in cases.enumerated() {
            let id = UUID()
            let file = try XCTUnwrap(storeMeeting(["refused\(index).wav"], id: id).first)
            fakeTrash.refusal = { _ in testCase.error }

            let outcomes = remover.remove([file], mode: .trash, in: store, jobID: id)

            XCTAssertEqual(outcomes, [.init(path: file.path, result: .failed(.refused(testCase.reason)))])
            XCTAssertEqual(MeetingFileRemover.failureReason(of: outcomes), testCase.reason)
            XCTAssertTrue(onDisk(file), "the refused file went")
            XCTAssertEqual(state(of: file, job: id), .present, "a refused file is restored in the record")
        }
        XCTAssertEqual(deletedForGood, [], "a refused Trash fell back to a permanent delete")
    }

    /// Later files still get their turn after one fails, so the retry has only
    /// the failed one left.
    func testEachFileHasItsOwnResult() throws {
        let files = try storeMeeting(["a.wav", "b.wav", "c.wav"])
        let refusal = CocoaError(.fileWriteNoPermission)
        fakeTrash.refusal = { $0.lastPathComponent == "b.wav" ? refusal : nil }

        let outcomes = remover.remove(files, mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes.map(\.path), files.map(\.path))
        XCTAssertEqual(outcomes.map(\.result), [.removed, .failed(.refused(refusal.localizedDescription)), .removed])
        XCTAssertEqual(fakeTrash.moved, ["a.wav", "c.wav"])
    }

    // MARK: - Reachable versus gone

    func testAMissingParentFolderIsUnreachableNotGone() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)
        try FileManager.default.moveItem(at: recordings, to: dir.appendingPathComponent("unplugged"))

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .failed(.unreachable))])
        XCTAssertEqual(state(of: file), .present, "an unreachable file stays listed as present")
        XCTAssertEqual(fakeTrash.moved, [])
    }

    func testAFileTheUserRemovedCountsAsGoneWithoutAFailure() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)
        try FileManager.default.removeItem(atPath: file.path)

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .alreadyGone)])
        XCTAssertEqual(state(of: file), .gone)
        XCTAssertNil(MeetingFileRemover.failureReason(of: outcomes))
        XCTAssertEqual(fakeTrash.moved, [])
    }

    // MARK: - Same file, right before removal

    /// Whatever now sits at the path was never the app's to remove, whichever way
    /// it got there, and in either mode.
    func testAnythingButTheRecordedFileStaysAndFails() throws {
        let fileManager = FileManager.default
        let cases: [(name: String, replace: (URL) throws -> Void, survivor: String?)] = [
            ("another file", { url in
                try fileManager.removeItem(at: url)
                try Data("someone else's".utf8).write(to: url)
            }, nil),
            ("a folder with a file inside", { url in
                try fileManager.removeItem(at: url)
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                try Data("keep me".utf8).write(to: url.appendingPathComponent("inside.txt"))
            }, "inside.txt"),
            ("a symbolic link", { [self] url in
                try fileManager.removeItem(at: url)
                try fileManager.createSymbolicLink(at: url, withDestinationURL: makeFile("target.wav", in: dir))
            }, nil),
        ]
        for (index, testCase) in cases.enumerated() {
            for mode in [MeetingFileRemover.Mode.trash, .forGood] {
                let id = UUID()
                let file = try XCTUnwrap(storeMeeting(["\(index)-\(mode).wav"], id: id).first)
                let url = URL(filePath: file.path)
                try testCase.replace(url)

                let outcomes = remover.remove([file], mode: mode, in: store, jobID: id)

                XCTAssertEqual(outcomes, [.init(path: file.path, result: .failed(.replaced))], testCase.name)
                XCTAssertEqual(state(of: file, job: id), .present, testCase.name)
                XCTAssertTrue(onDisk(file), testCase.name)
                if let survivor = testCase.survivor {
                    XCTAssertTrue(fileManager.fileExists(atPath: url.appendingPathComponent(survivor).path))
                }
            }
        }
        XCTAssertEqual(fakeTrash.moved, [])
        XCTAssertEqual(deletedForGood, [])
    }

    /// The file itself is the recorded one (a move keeps its identity), but the
    /// folder it was recorded in now leads somewhere else.
    func testAParentFolderReplacedByASymbolicLinkFails() throws {
        let file = try XCTUnwrap(storeMeeting(["m_mix.wav"]).first)
        let moved = dir.appendingPathComponent("moved-away", isDirectory: true)
        try FileManager.default.moveItem(at: recordings, to: moved)
        try FileManager.default.createSymbolicLink(at: recordings, withDestinationURL: moved)
        XCTAssertEqual(FileIdentity.of(file.path), file.identity, "test premise: the very same file is reached")

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .failed(.replaced))])
        XCTAssertEqual(fakeTrash.moved, [])
    }

    /// Nothing was at the path when it was listed, so nothing says that what is
    /// there now is the meeting's.
    func testAFileListedWithoutAnIdentityFails() throws {
        let url = try makeFile("m_mix.wav")
        var file = MeetingFile(role: .mix, url: url, owned: true)
        file.identity = nil
        store.create(MeetingFileRecord(jobID: jobID, origin: .recorded, recordingDate: nil, files: [file]))

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .failed(.replaced))])
    }

    /// The identity alone would let this one through: the record names this very
    /// folder, and a folder is still nothing the app may take away.
    func testAFolderTheRecordListsIsNotRemoved() throws {
        let folder = recordings.appendingPathComponent("a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let inside = try makeFile("inside.wav", in: folder)
        let entry = MeetingFile(role: .mix, url: folder, owned: true)
        store.create(MeetingFileRecord(jobID: jobID, origin: .recorded, recordingDate: nil, files: [entry]))

        for mode in [MeetingFileRemover.Mode.trash, .forGood] {
            let outcomes = remover.remove([entry], mode: mode, in: store, jobID: jobID)
            XCTAssertEqual(outcomes, [.init(path: entry.path, result: .failed(.replaced))])
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
        XCTAssertEqual(fakeTrash.moved, [])
        XCTAssertEqual(deletedForGood, [])
    }

    /// The mover's own safety, past the check above: `unlink` on a folder fails,
    /// where `FileManager.removeItem` would empty it.
    func testTheRealPermanentDeleteRemovesOneFileAndNeverAFolder() throws {
        let realDelete = MeetingFileRemover().removeForGood
        let folder = recordings.appendingPathComponent("a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let inside = try makeFile("inside.wav", in: folder)
        let file = try makeFile("m_mix.wav")

        XCTAssertThrowsError(try realDelete(folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path), "a folder's contents went")

        try realDelete(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Shared paths

    func testAPathAnotherRecordListsStaysUntilThatRecordIsGone() throws {
        let file = try XCTUnwrap(storeMeeting(["shared_mix.wav"]).first)
        let other = UUID()
        store.create(MeetingFileRecord(
            jobID: other, origin: .imported, recordingDate: nil,
            files: [MeetingFile(role: .mix, url: URL(filePath: file.path), owned: false)],
        ))

        let blocked = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(blocked, [.init(path: file.path, result: .failed(.listedByAnotherMeeting))])
        XCTAssertEqual(MeetingFileRemover.failureReason(of: blocked), "1 file is also listed by another meeting")
        XCTAssertTrue(onDisk(file))
        XCTAssertEqual(state(of: file), .present)

        store.remove(jobID: other)

        XCTAssertEqual(remover.remove([file], mode: .trash, in: store, jobID: jobID), [.init(path: file.path, result: .removed)])
        XCTAssertEqual(fakeTrash.moved, ["shared_mix.wav"])
    }

    /// An entry the other record knows is gone holds no file back: it would
    /// otherwise block this path for as long as that meeting is kept.
    func testAnotherRecordsGoneEntryDoesNotBlock() throws {
        let file = try XCTUnwrap(storeMeeting(["shared_mix.wav"]).first)
        var goneEntry = file
        goneEntry.state = .gone
        store.create(MeetingFileRecord(jobID: UUID(), origin: .recorded, recordingDate: nil, files: [goneEntry]))

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .removed)])
    }

    /// A second running build can list the path a moment before the mark, so the
    /// check has to read the file under the lock, not this store's last copy.
    func testAPathAnotherStoreListedAfterTheLastReadIsBlocked() throws {
        let file = try XCTUnwrap(storeMeeting(["shared_mix.wav"]).first)
        let otherBuild = MeetingFileStore(path: dir.appendingPathComponent("logs/meeting_files.json"))
        otherBuild.create(MeetingFileRecord(
            jobID: UUID(), origin: .imported, recordingDate: nil,
            files: [MeetingFile(role: .mix, url: URL(filePath: file.path), owned: false)],
        ))
        XCTAssertEqual(store.records.count, 1, "test premise: this store has not read that write")

        let outcomes = remover.remove([file], mode: .trash, in: store, jobID: jobID)

        XCTAssertEqual(outcomes, [.init(path: file.path, result: .failed(.listedByAnotherMeeting))])
    }

    // MARK: - The reason a row shows

    func testTheReasonCountsItsFilesAndKeepsTheRefusalsText() {
        let path = "/a"
        let result: (MeetingFileRemover.Failure) -> MeetingFileRemover.FileOutcome = { failure in
            .init(path: path, result: .failed(failure))
        }
        let cases: [(outcomes: [MeetingFileRemover.FileOutcome], reason: String?)] = [
            ([.init(path: path, result: .removed), .init(path: path, result: .alreadyGone)], nil),
            ([result(.unreachable)], "1 file is on a drive or in a folder that is not available"),
            ([result(.unreachable), result(.unreachable)], "2 files are on a drive or in a folder that is not available"),
            ([result(.replaced)], "1 file was replaced"),
            ([result(.replaced), result(.replaced)], "2 files were replaced"),
            ([result(.listedByAnotherMeeting), result(.listedByAnotherMeeting)], "2 files are also listed by another meeting"),
            ([result(.refused("this volume has no Trash")), result(.refused("this volume has no Trash"))], "this volume has no Trash"),
            ([result(.recordNotSaved)], "the meeting's record could not be saved"),
            ([result(.meetingChanged)], "the meeting changed while it was being deleted"),
            (
                [result(.refused("no Trash")), result(.replaced), result(.unreachable)],
                "1 file is on a drive or in a folder that is not available; 1 file was replaced; no Trash",
            ),
        ]
        for testCase in cases {
            XCTAssertEqual(MeetingFileRemover.failureReason(of: testCase.outcomes), testCase.reason)
        }
    }

    // MARK: - What a deletion covers

    func testADeletionCoversWhatTheAppOwnsAndHasNotSeenGo() {
        func entry(_ role: MeetingFile.Role, _ path: String, owned: Bool = true, state: MeetingFile.State = .present) -> MeetingFile {
            MeetingFile(role: role, path: path, identity: nil, owned: owned, state: state)
        }
        let files = [
            entry(.mix, "/mix"),
            entry(.mix, "/earlier-mix"),
            entry(.appTrack, "/app", state: .gone),
            entry(.micTrack, "/mic", state: .deleting),
            entry(.transcript, "/transcript"),
            entry(.protocol, "/notes", state: .gone),
            entry(.previousProtocol, "/previous"),
        ]
        let record = MeetingFileRecord(jobID: jobID, origin: .recorded, recordingDate: nil, files: files)

        XCTAssertEqual(record.filesCovered(by: .audioToTrash).map(\.path), ["/mix", "/earlier-mix", "/mic"])
        XCTAssertEqual(record.filesCovered(by: .automatic).map(\.path), ["/mix", "/earlier-mix", "/mic"])
        XCTAssertEqual(record.filesCovered(by: .meetingToTrash).map(\.path), ["/mix", "/earlier-mix", "/mic", "/transcript", "/previous"])
    }

    /// One path under two roles: an imported source, and a 16 kHz copy reported
    /// at the same name. It is the user's under either.
    func testAPathAlsoListedAsNotOwnedIsNeverCovered() {
        let record = MeetingFileRecord(jobID: jobID, origin: .imported, recordingDate: nil, files: [
            MeetingFile(role: .mix, path: "/source", identity: nil, owned: false, state: .present),
            MeetingFile(role: .mix16k, path: "/source", identity: nil, owned: true, state: .present),
            MeetingFile(role: .transcript, path: "/transcript", identity: nil, owned: true, state: .present),
            MeetingFile(role: .segments, path: "/transcript", identity: nil, owned: true, state: .present),
        ])

        XCTAssertEqual(record.filesCovered(by: .meetingToTrash).map(\.path), ["/transcript"], "each path once")
    }
}
