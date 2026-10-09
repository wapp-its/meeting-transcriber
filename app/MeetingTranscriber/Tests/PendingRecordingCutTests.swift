import Darwin
@testable import MeetingTranscriber
import XCTest

/// `PendingRecordingCut` against real files in a real folder: a record comes
/// back exactly as written, a read refuses every file that must never be
/// applied, and each write and removal syncs in an order that leaves a whole
/// record or none wherever the process dies.
final class PendingRecordingCutTests: XCTestCase {
    private let stem = "2026-10-09_10-00-00_Teams"
    private let failure = POSIXError(.EIO)

    // MARK: - Helpers

    /// A record whose times have fractions far below a millisecond, so an
    /// encoding that rounds them is caught.
    private func record(
        stem: String? = nil,
        cutOffset: TimeInterval = 1800.000_123,
        captureEndedAt: Date? = nil,
        keptSeconds: TimeInterval? = nil,
    ) -> PendingRecordingCut {
        let startedAt = Date(timeIntervalSinceReferenceDate: 781_692_800.123_456_7)
        return PendingRecordingCut(
            stem: stem ?? self.stem,
            cutAt: startedAt.addingTimeInterval(cutOffset),
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(1920.000_456),
            captureEndedAt: captureEndedAt,
            keptSeconds: keptSeconds,
        )
    }

    private func store(_ record: PendingRecordingCut, in dir: URL) {
        let outcome = PendingRecordingCut.write(record, in: dir)
        if case .written = outcome { return }
        XCTFail("expected the write to succeed, got \(outcome)")
    }

    private func storeRaw(_ data: Data, in dir: URL) throws {
        try data.write(to: PendingRecordingCut.url(stem: stem, in: dir))
    }

    private func files(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func storedKeys(in dir: URL) throws -> Set<String> {
        let data = try Data(contentsOf: PendingRecordingCut.url(stem: stem, in: dir))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - Write and read

    /// Written over a resolved record, a bare one comes back bare: the second
    /// write replaces the first whole instead of merging into it.
    func testARecordRoundTripsExactlyAndASecondWriteReplacesTheFirstWhole() throws {
        let dir = try makeTempDirectory(prefix: "pending-cut-roundtrip")
        let resolved = record(captureEndedAt: Date(timeIntervalSinceReferenceDate: 781_694_730.987_654_3), keptSeconds: 1799.876_543_21)
        let bare = record()
        let required: Set = ["version", "stem", "cutAt", "startedAt", "deadline"]

        for (stored, keys) in [(resolved, required.union(["captureEndedAt", "keptSeconds"])), (bare, required)] {
            store(stored, in: dir)

            XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .valid(stored))
            XCTAssertEqual(try storedKeys(in: dir), keys, "these fields are the contract, nothing else is stored")
            let attributes = try FileManager.default.attributesOfItem(atPath: PendingRecordingCut.url(stem: stem, in: dir).path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            XCTAssertEqual(try files(in: dir), [stem + RecordingFileSuffix.pendingCut], "no temporary file is left behind")
        }
    }

    func testAReadRefusesEveryFileThatMustNeverBeApplied() throws {
        XCTAssertEqual(try PendingRecordingCut.read(stem: stem, in: makeTempDirectory(prefix: "pending-cut-absent")), .absent)

        let encoder = JSONEncoder()
        let cases: [(name: String, data: Data, reason: PendingRecordingCut.InvalidReason)] = try [
            ("an empty file", Data(), .empty),
            ("undecodable bytes", Data("not a record".utf8), .unreadable),
            ("an unknown version", Data(#"{"version":2,"stem":"elsewhere"}"#.utf8), .unknownVersion),
            ("another recording's stem", encoder.encode(record(stem: "2026-10-09_09-00-00_Zoom")), .otherRecording),
            ("a cut before the start", encoder.encode(record(cutOffset: -0.001)), .timesOutOfOrder),
            ("a cut after the deadline", encoder.encode(record(cutOffset: 1920.001)), .timesOutOfOrder),
            ("nothing kept", encoder.encode(record(keptSeconds: 0)), .nonPositiveKeptSeconds),
            ("a negative kept length", encoder.encode(record(keptSeconds: -1)), .nonPositiveKeptSeconds),
        ]
        for testCase in cases {
            let dir = try makeTempDirectory(prefix: "pending-cut-invalid")
            try storeRaw(testCase.data, in: dir)

            XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .invalid(testCase.reason), testCase.name)
        }
    }

    /// Recovery stores the capture end alone before it repairs anything, the
    /// cut later; a value already present is never moved.
    func testRecordResolutionSetsOnlyWhatIsAbsentAndNeverChangesAPresentValue() throws {
        let dir = try makeTempDirectory(prefix: "pending-cut-resolution")
        store(record(), in: dir)
        let firstEnd = Date(timeIntervalSinceReferenceDate: 781_694_730.5)

        let steps: [(keptSeconds: TimeInterval?, captureEndedAt: Date?, expected: PendingRecordingCut)] = [
            (nil, firstEnd, record(captureEndedAt: firstEnd)),
            (1799.5, firstEnd.addingTimeInterval(60), record(captureEndedAt: firstEnd, keptSeconds: 1799.5)),
            (900, firstEnd.addingTimeInterval(120), record(captureEndedAt: firstEnd, keptSeconds: 1799.5)),
        ]
        for step in steps {
            let outcome = PendingRecordingCut.recordResolution(
                stem: stem, in: dir, keptSeconds: step.keptSeconds, captureEndedAt: step.captureEndedAt,
            )

            guard case .written = outcome else {
                XCTFail("expected written, got \(outcome)")
                return
            }
            XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .valid(step.expected))
        }

        let missing = PendingRecordingCut.recordResolution(stem: "absent", in: dir, keptSeconds: 10, captureEndedAt: firstEnd)
        guard case let .notPublished(error) = missing else {
            XCTFail("expected notPublished, got \(missing)")
            return
        }
        XCTAssertEqual(error as? PendingRecordingCut.ResolutionError, .noRecord)
        XCTAssertEqual(PendingRecordingCut.read(stem: "absent", in: dir), .absent, "nothing is created for a record that was never stored")
    }

    // MARK: - Durability

    /// The temporary file is synced while the target still holds what it held
    /// before (or nothing), the folder once the rename has published the new
    /// record: a power loss at either point leaves a whole record.
    func testTheFileIsSyncedBeforeTheRenameAndTheFolderAfterIt() throws {
        let previous = record(keptSeconds: 600)
        let next = record(captureEndedAt: Date(timeIntervalSinceReferenceDate: 781_694_730.25))

        for before in [nil, previous] {
            let dir = try makeTempDirectory(prefix: "pending-cut-order")
            if let before { store(before, in: dir) }
            var syncs: [(isFolder: Bool, stored: PendingRecordingCut.ReadResult)] = []

            let outcome = PendingRecordingCut.write(next, in: dir) { descriptor in
                syncs.append((isFolder(descriptor), PendingRecordingCut.read(stem: stem, in: dir)))
            }

            guard case .written = outcome else {
                XCTFail("expected written, got \(outcome)")
                return
            }
            XCTAssertEqual(syncs.map(\.isFolder), [false, true])
            XCTAssertEqual(syncs.first?.stored, before.map { PendingRecordingCut.ReadResult.valid($0) } ?? .absent)
            XCTAssertEqual(syncs.last?.stored, .valid(next))
        }
    }

    func testASyncFailingOnTheFilePublishesNothingAndLeavesNoTemporaryFile() throws {
        let dir = try makeTempDirectory(prefix: "pending-cut-file-sync")
        let previous = record(keptSeconds: 600)
        store(previous, in: dir)

        let outcome = PendingRecordingCut.write(record(), in: dir) { descriptor in
            if !isFolder(descriptor) { throw failure }
        }

        guard case let .notPublished(error) = outcome else {
            XCTFail("expected notPublished, got \(outcome)")
            return
        }
        XCTAssertEqual(error as? POSIXError, failure)
        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .valid(previous))
        XCTAssertEqual(try files(in: dir), [stem + RecordingFileSuffix.pendingCut])
    }

    func testASyncFailingOnlyOnTheFolderStillPublishesTheNewRecord() throws {
        let dir = try makeTempDirectory(prefix: "pending-cut-folder-sync")
        store(record(keptSeconds: 600), in: dir)
        let next = record()

        let outcome = PendingRecordingCut.write(next, in: dir) { descriptor in
            if isFolder(descriptor) { throw failure }
        }

        guard case let .publishedNotSynced(error) = outcome else {
            XCTFail("expected publishedNotSynced, got \(outcome)")
            return
        }
        XCTAssertEqual(error as? POSIXError, failure)
        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .valid(next))
        XCTAssertEqual(try files(in: dir), [stem + RecordingFileSuffix.pendingCut])
    }

    // MARK: - Removal

    func testRemovalUnlinksAndThenSyncsTheFolder() throws {
        let dir = try makeTempDirectory(prefix: "pending-cut-remove")
        store(record(), in: dir)
        var syncedFolders: [Bool] = []

        let outcome = PendingRecordingCut.remove(stem: stem, in: dir) { descriptor in
            syncedFolders.append(isFolder(descriptor))
            XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .absent, "the folder is synced after the unlink")
        }

        guard case .removed = outcome else {
            XCTFail("expected removed, got \(outcome)")
            return
        }
        XCTAssertEqual(syncedFolders, [true])

        store(record(), in: dir)
        let unsynced = PendingRecordingCut.remove(stem: stem, in: dir) { _ in throw failure }

        guard case let .removedNotSynced(error) = unsynced else {
            XCTFail("expected removedNotSynced, got \(unsynced)")
            return
        }
        XCTAssertEqual(error as? POSIXError, failure)
        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .absent)
    }

    /// A folder that refuses the unlink: the file is emptied and synced
    /// instead, and an empty file never reads as a record. When emptying fails
    /// as well, both errors are reported.
    func testARemovalThatCannotUnlinkEmptiesTheFileInstead() throws {
        let dir = try makeTempDirectory(prefix: "pending-cut-readonly")
        let otherStem = "2026-10-09_11-00-00_Teams"
        store(record(), in: dir)
        store(record(stem: otherStem), in: dir)
        XCTAssertEqual(chmod(dir.path, 0o500), 0)
        addTeardownBlock { _ = chmod(dir.path, 0o755) }
        var syncedFolders: [Bool] = []

        let outcome = PendingRecordingCut.remove(stem: stem, in: dir) { descriptor in
            syncedFolders.append(isFolder(descriptor))
        }

        guard case let .emptied(unlinkError) = outcome else {
            XCTFail("expected emptied, got \(outcome)")
            return
        }
        XCTAssertEqual((unlinkError as? POSIXError)?.code, .EACCES)
        XCTAssertEqual(syncedFolders, [false], "the emptied file itself is synced")
        let attributes = try FileManager.default.attributesOfItem(atPath: PendingRecordingCut.url(stem: stem, in: dir).path)
        XCTAssertEqual(attributes[.size] as? Int, 0)
        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .invalid(.empty))

        let both = PendingRecordingCut.remove(stem: otherStem, in: dir) { _ in throw failure }

        guard case let .failed(bothUnlinkError, emptyError) = both else {
            XCTFail("expected failed, got \(both)")
            return
        }
        XCTAssertEqual((bothUnlinkError as? POSIXError)?.code, .EACCES)
        XCTAssertEqual(emptyError as? POSIXError, failure)
    }

    // MARK: - Hold

    func testHoldReleaseAndIsHeldBehaveAsASet() {
        addTeardownBlock { PendingRecordingCut.releaseAllForTesting() }
        XCTAssertFalse(PendingRecordingCut.isHeld(stem))

        PendingRecordingCut.hold(stem)
        PendingRecordingCut.hold(stem)
        XCTAssertTrue(PendingRecordingCut.isHeld(stem))
        XCTAssertFalse(PendingRecordingCut.isHeld("2026-10-09_11-00-00_Teams"))

        PendingRecordingCut.release(stem)
        XCTAssertFalse(PendingRecordingCut.isHeld(stem), "a set: one release undoes any number of holds")
        PendingRecordingCut.release(stem)
        XCTAssertFalse(PendingRecordingCut.isHeld(stem))
    }

    func testHoldsAreSafeFromSeveralThreads() {
        addTeardownBlock { PendingRecordingCut.releaseAllForTesting() }
        let stems = (0 ..< 4000).map { "concurrent-\($0)" }

        DispatchQueue.concurrentPerform(iterations: stems.count) { index in
            PendingRecordingCut.hold(stems[index])
            XCTAssertTrue(PendingRecordingCut.isHeld(stems[index]))
            if index.isMultiple(of: 2) { PendingRecordingCut.release(stems[index]) }
        }

        let held = stems.filter(PendingRecordingCut.isHeld)
        XCTAssertEqual(held, stems.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element))
    }
}

/// Whether an open descriptor is a folder, to tell the folder sync from the
/// file sync.
private func isFolder(_ descriptor: Int32) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
}
