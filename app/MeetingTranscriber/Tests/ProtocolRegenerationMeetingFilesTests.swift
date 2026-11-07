@testable import MeetingTranscriber
import XCTest

/// What "Regenerate Notes" tells a meeting's file record. It replaces the
/// protocol outside the pipeline, on a job that may have left the queue long
/// ago, so nothing else keeps the record in step. Real files in a temp folder;
/// the generator and the Trash are fakes.
@MainActor
final class ProtocolRegenerationMeetingFilesTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var folder: URL!
    private var trashBin: URL!
    private var store: MeetingFileStore!
    // swiftlint:enable implicitly_unwrapped_optional

    private let basename = "20261013_0900_standup_ab12cd34"
    private let job = PipelineJob(meetingTitle: "Standup", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)

    override func setUp() async throws {
        try await super.setUp()
        folder = try makeTempDirectory(prefix: "regeneration_files_test")
        trashBin = try makeTempDirectory(prefix: "regeneration_files_trash")
        store = MeetingFileStore(path: folder.appendingPathComponent("logs/meeting_files.json"))
        store.create(MeetingFileRecord(job: job, origin: .recorded, createdBy: store.bundleID))
    }

    private var txt: URL {
        folder.appendingPathComponent("\(basename).txt")
    }

    private var md: URL {
        folder.appendingPathComponent("\(basename).md")
    }

    /// The meeting's files on disk, and listed in its record.
    private func writeMeeting(withProtocol: Bool = true) throws {
        try Data("[Anna] We ship on Friday.".utf8).write(to: txt)
        var written = [(role: MeetingFile.Role.transcript, url: txt)]
        if withProtocol {
            try Data("# Old notes".utf8).write(to: md)
            written.append((.protocol, md))
        }
        store.update(jobID: job.id) { record in
            for file in written {
                record.list(MeetingFile(role: file.role, url: file.url, owned: true))
            }
        }
    }

    private func fileOperations(trashRefuses: Bool = false) -> ProtocolRegenerationFileOperations {
        var ops = ProtocolRegenerationFileOperations.live
        let trashBin: URL = trashBin
        ops.trash = { url in
            if trashRefuses { throw CocoaError(.featureUnsupported) }
            try FileManager.default.moveItem(at: url, to: trashBin.appendingPathComponent(url.lastPathComponent))
        }
        return ops
    }

    private func makeRegenerator(_ ops: ProtocolRegenerationFileOperations, now: @escaping () -> Date = Date.init) -> ProtocolRegenerator {
        let folder: URL = folder
        let store: MeetingFileStore = store
        return ProtocolRegenerator(environment: .init(
            generatorFactory: { MockProtocolGen() },
            templateStore: ProtocolTemplateStore(directory: folder.appendingPathComponent("templates")),
            includeFullTranscript: { false },
            recordOnly: { false },
            queuedJobs: { [] },
            records: { [] },
            outputDir: { folder },
            notifier: RecordingNotifier(),
            fileOperations: ops,
            now: now,
            protocolReplaced: store.noteProtocolReplaced,
        ))
    }

    /// The meeting with its job, as a row of All Recordings resolves it.
    private func targetWithJob() throws -> ProtocolRegenerationTarget {
        let hasProtocol = FileManager.default.fileExists(atPath: md.path)
        return try ProtocolRegenerationTarget(
            folder: folder, basename: basename, title: "Standup",
            meetingStartTime: nil, jobID: job.id.uuidString,
            files: ProtocolRegenerationFiles(
                transcriptFile: Data(contentsOf: txt), protocolFile: hasProtocol ? Data(contentsOf: md) : nil,
            ),
        )
    }

    private static let options = MeetingProtocolOptions(template: .builtIn, rawBackground: "")

    private func files(_ role: MeetingFile.Role) throws -> [MeetingFile] {
        try XCTUnwrap(store.record(for: job.id)).files.filter { $0.role == role }
    }

    private func assertSucceeded(_ regenerator: ProtocolRegenerator, file: StaticString = #filePath, line: UInt = #line) {
        guard case .succeeded = regenerator.phase else {
            XCTFail("test premise: \(regenerator.phase)", file: file, line: line)
            return
        }
    }

    // MARK: - A meeting with a job

    func testRegeneratingForAJobUpdatesTheProtocolsIdentity() async throws {
        try writeMeeting()
        let before = try XCTUnwrap(files(.protocol).first)
        let regenerator = makeRegenerator(fileOperations())

        try await regenerator.regenerate(targetWithJob(), options: Self.options)

        assertSucceeded(regenerator)
        let after = try XCTUnwrap(files(.protocol).first)
        XCTAssertEqual(try files(.protocol).count, 1)
        XCTAssertEqual(after.path, MeetingFile.resolvedPath(md))
        XCTAssertEqual(after.identity, FileIdentity.of(md.path))
        XCTAssertNotEqual(after.identity, before.identity, "test premise: the file was replaced")
        XCTAssertEqual(try files(.previousProtocol), [], "a previous copy the Trash took is not the meeting's any more")
    }

    /// A protocol that failed the first time, or that the run never made.
    func testRegeneratingAMeetingWithoutAProtocolListsTheNewOne() async throws {
        try writeMeeting(withProtocol: false)
        XCTAssertEqual(try files(.protocol), [], "test premise")
        let regenerator = makeRegenerator(fileOperations())

        try await regenerator.regenerate(targetWithJob(), options: Self.options)

        assertSucceeded(regenerator)
        let listed = try XCTUnwrap(files(.protocol).first)
        XCTAssertEqual(listed.identity, FileIdentity.of(md.path))
        XCTAssertNotNil(listed.identity)
        XCTAssertTrue(listed.owned)
        XCTAssertEqual(listed.state, .present)
    }

    /// A volume without a Trash refuses every time, so each run leaves a copy,
    /// and Move Meeting to Trash has to find them all.
    func testEachPreviousProtocolTheTrashRefusedIsListedAsOwned() async throws {
        try writeMeeting()
        var clock = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let regenerator = makeRegenerator(fileOperations(trashRefuses: true)) {
            clock += 60
            return clock
        }

        try await regenerator.regenerate(targetWithJob(), options: Self.options)
        assertSucceeded(regenerator)
        try await regenerator.regenerate(targetWithJob(), options: Self.options)
        assertSucceeded(regenerator)

        let kept = try files(.previousProtocol)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(Set(kept.map(\.path)).count, 2)
        for copy in kept {
            XCTAssertTrue(copy.owned)
            XCTAssertEqual(copy.state, .present)
            XCTAssertEqual(copy.identity, FileIdentity.of(copy.path))
            XCTAssertNotNil(copy.identity, "\(copy.path) is not on disk")
        }
        XCTAssertEqual(try files(.protocol).first?.identity, FileIdentity.of(md.path))
    }

    /// The new file could not go in place and the old one could not go back.
    /// The record says where the notes are now, so a deletion still finds them.
    func testAProtocolThatCouldNotBePutBackIsListedWhereItIsKept() async throws {
        try writeMeeting()
        let md: URL = md
        var ops = fileOperations()
        ops.move = { from, to in
            if to == md { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let regenerator = makeRegenerator(ops)

        try await regenerator.regenerate(targetWithJob(), options: Self.options)

        guard case let .failed(reason) = regenerator.phase, reason.contains("kept as") else {
            XCTFail("test premise: \(regenerator.phase)")
            return
        }
        let kept = try XCTUnwrap(files(.previousProtocol).first)
        XCTAssertEqual(kept.identity, FileIdentity.of(kept.path))
        XCTAssertNotNil(kept.identity, "\(kept.path) is not on disk")
        XCTAssertEqual(try files(.protocol).first?.state, .gone)
    }

    /// No export ran, and the page is still there.
    func testRegeneratingLeavesTheNotionMarkSet() async throws {
        try writeMeeting(withProtocol: false)
        store.update(jobID: job.id) { $0.savedToNotion = true }
        let regenerator = makeRegenerator(fileOperations())

        try await regenerator.regenerate(targetWithJob(), options: Self.options)

        assertSucceeded(regenerator)
        XCTAssertEqual(try files(.protocol).count, 1)
        XCTAssertEqual(store.record(for: job.id)?.savedToNotion, true)
    }

    // MARK: - No record to follow

    func testAHandPickedFileChangesNoRecord() async throws {
        try writeMeeting()
        let before = store.records
        let regenerator = makeRegenerator(fileOperations())
        let target = try ProtocolRegenerationTarget.resolve(file: md, records: []) { try? Data(contentsOf: $0) }
        XCTAssertNil(target.jobID, "test premise")

        await regenerator.regenerate(target, options: Self.options)

        assertSucceeded(regenerator)
        XCTAssertNotEqual(FileIdentity.of(md.path), try files(.protocol).first?.identity, "test premise: the file was replaced")
        XCTAssertEqual(store.records, before)
    }

    /// A meeting from before this version gets no record, also not from here.
    func testAJobWithoutARecordGetsNone() async throws {
        store.remove(jobID: job.id)
        try Data("[Anna] We ship on Friday.".utf8).write(to: txt)
        let regenerator = makeRegenerator(fileOperations())

        try await regenerator.regenerate(targetWithJob(), options: Self.options)

        assertSucceeded(regenerator)
        XCTAssertEqual(store.records, [])
    }

    // MARK: - Wiring

    /// The closure defaults to doing nothing, which only this notices.
    func testAppStateHandsTheRegeneratorItsRecordStore() throws {
        let suite = "ProtocolRegenerationMeetingFilesTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: folder.appendingPathComponent("output"),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let state = AppState(
            pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: folder.appendingPathComponent("app_logs")),
            settings: settings,
        )
        let records = state.pipeline.meetingFileStore
        records.create(MeetingFileRecord(job: job, origin: .recorded, createdBy: records.bundleID))
        try Data("# New notes".utf8).write(to: md)

        state.protocolRegenerator.environment.protocolReplaced(job.id, md, nil)

        let listed = state.pipeline.meetingFileStore.record(for: job.id)?.files.first { $0.role == .protocol }
        XCTAssertEqual(listed?.identity, FileIdentity.of(md.path))
        XCTAssertNotNil(listed?.identity)
    }
}
