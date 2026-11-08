@testable import MeetingTranscriber
import XCTest

/// How the record holds a meeting's additional reports once Move Meeting to Trash
/// found them, and the old reports the regenerator kept (spec R5, gh-97 seams).
@MainActor
final class MeetingFileStoreReportTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var folder: URL!
    private let job = PipelineJob(meetingTitle: "Standup", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)

    override func setUp() async throws {
        try await super.setUp()
        folder = try makeTempDirectory(prefix: "store_reports")
    }

    private var storePath: URL {
        folder.appendingPathComponent("logs/meeting_files.json")
    }

    private func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func report(_ name: String) throws -> MeetingFile {
        try MeetingFile(role: .previousProtocol, url: file(name), owned: true)
    }

    private func makeStore() throws -> MeetingFileStore {
        let store = MeetingFileStore(path: storePath)
        var record = MeetingFileRecord(job: job, origin: .recorded, createdBy: store.bundleID)
        try record.list(MeetingFile(role: .transcript, url: file("s.txt"), owned: true))
        XCTAssertTrue(store.create(record))
        return store
    }

    func testReportsAreListedWithThePendingMarkInOneSaveBesideAKeptCopy() throws {
        let store = try makeStore()
        try store.noteKeptFile(jobID: job.id, url: file("s.previous-1.md"))
        let short = try report("s (Short).md")
        let minutes = try report("s (Minutes).md")
        let covered = try XCTUnwrap(store.record(for: job.id)).filesCovered(by: .meetingToTrash).map(\.path)

        XCTAssertTrue(store.beginDeletion(jobID: job.id, kind: .meetingToTrash, paths: covered, adding: [short, minutes]))

        let saved = try XCTUnwrap(MeetingFileStore(path: storePath).record(for: job.id))
        XCTAssertEqual(saved.files.filter { $0.role == .previousProtocol }.count, 3, "two reports beside the kept copy")
        XCTAssertEqual(Set(saved.pending?.paths ?? []), Set(covered + [short.path, minutes.path]))
        let json = try String(contentsOf: storePath, encoding: .utf8)
        XCTAssertTrue(json.contains("\"previous_protocol\""), "the raw value another build decodes")
    }

    func testARecordChangedSinceTheReadAddsNothing() throws {
        let store = try makeStore()
        let read = try XCTUnwrap(store.record(for: job.id))
        store.update(jobID: job.id) { $0.keep = true }

        XCTAssertFalse(try store.beginDeletion(jobID: job.id, kind: .meetingToTrash, paths: [], unchangedFrom: read, adding: [report("s (Short).md")]))

        let saved = try XCTUnwrap(MeetingFileStore(path: storePath).record(for: job.id))
        XCTAssertNil(saved.pending)
        XCTAssertFalse(saved.files.contains { $0.role == .previousProtocol })
    }

    /// One the record lists keeps the identity it was listed with, so a report
    /// replaced since is refused as replaced.
    func testAReportTheRecordListsKeepsItsListedIdentity() throws {
        let store = try makeStore()
        let short = try report("s (Short).md")
        XCTAssertTrue(store.beginDeletion(jobID: job.id, kind: .meetingToTrash, paths: [], adding: [short]))
        store.update(jobID: job.id) { $0.pending = nil }
        let replaced = MeetingFile(role: .previousProtocol, path: short.path, identity: FileIdentity(device: 1, inode: 2), owned: true, state: .present)

        XCTAssertTrue(store.beginDeletion(jobID: job.id, kind: .meetingToTrash, paths: [], adding: [replaced]))

        let listed = try XCTUnwrap(store.record(for: job.id)).files.filter { $0.path == short.path }
        XCTAssertEqual(listed.map(\.identity), [short.identity])
    }

    /// A report the first run moved away and the retry finds at its path again is
    /// looked at again under the identity it was listed with, never the new one.
    func testAReportSeenGoneAndFoundAgainKeepsItsListedIdentity() throws {
        let store = try makeStore()
        let short = try report("s (Short).md")
        XCTAssertTrue(store.beginDeletion(jobID: job.id, kind: .meetingToTrash, paths: [], adding: [short]))
        store.setState(.gone, ofFileAt: short.path, jobID: job.id)
        store.update(jobID: job.id) { $0.pending = nil }
        let replaced = MeetingFile(role: .previousProtocol, path: short.path, identity: FileIdentity(device: 1, inode: 2), owned: true, state: .present)

        XCTAssertTrue(store.beginDeletion(jobID: job.id, kind: .meetingToTrash, paths: [], adding: [replaced]))

        let record = try XCTUnwrap(store.record(for: job.id))
        let listed = record.files.filter { $0.path == short.path }
        XCTAssertEqual(listed.map(\.identity), [short.identity])
        XCTAssertEqual(listed.map(\.state), [.present], "the deletion looks at it again")
        XCTAssertEqual(record.pending?.paths, [short.path])
    }

    func testAKeptFileReplacesAnEntryOfTheSamePath() throws {
        let store = try makeStore()
        let kept = try file("s (Short).previous-1.md")

        store.noteKeptFile(jobID: job.id, url: kept)
        store.noteKeptFile(jobID: job.id, url: kept)

        let listed = try XCTUnwrap(store.record(for: job.id)).files.filter { $0.role == .previousProtocol }
        XCTAssertEqual(listed.map(\.path), [MeetingFile.resolvedPath(kept)])
        XCTAssertEqual(listed.first?.owned, true)
    }
}
