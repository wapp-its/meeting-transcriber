@testable import MeetingTranscriber
import XCTest

/// "Save as: An additional report": the new notes land beside the meeting's
/// files as `<basename> (<template>).md`, and the main protocol and every other
/// report stay as they are, whichever step fails. Real files in a temp folder;
/// the generator and the Trash are fakes.
@MainActor
final class ProtocolRegeneratorReportTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var folder: URL!
    private var templates: URL!
    private var trashBin: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    private let basename = "20261013_0900_standup_ab12cd34"
    private let oldProtocol = "# Old protocol"
    private let stamp = Date(timeIntervalSince1970: 1_760_000_000)
    private let jobID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        folder = try makeTempDirectory(prefix: "regenerator_report_test")
        templates = try makeTempDirectory(prefix: "regenerator_report_templates")
        trashBin = try makeTempDirectory(prefix: "regenerator_report_trash")
        try Data("Short summary in {LANGUAGE}".utf8).write(to: templates.appendingPathComponent("Short.md"))
    }

    private func url(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    private var md: URL {
        url("\(basename).md")
    }

    private var shortReport: URL {
        url("\(basename) (Short).md")
    }

    private static let short = MeetingProtocolOptions(template: .file(name: "Short"), rawBackground: "")

    private func writeMeeting(withProtocol: Bool = true) throws {
        try Data("[Anna] We ship on Friday.".utf8).write(to: url("\(basename).txt"))
        if withProtocol { try Data(oldProtocol.utf8).write(to: md) }
    }

    private func folderContents() throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try Dictionary(uniqueKeysWithValues: names.map { try ($0, Data(contentsOf: url($0))) })
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func target() throws -> ProtocolRegenerationTarget {
        let resolved = try ProtocolRegenerationTarget.resolve(file: md, records: []) { try? Data(contentsOf: $0) }
        return ProtocolRegenerationTarget(
            folder: resolved.folder, basename: resolved.basename, title: "Standup",
            meetingStartTime: nil, jobID: jobID.uuidString, files: resolved.files,
        )
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

    /// What the run told the job and the record.
    private final class Hooks {
        var regenerated: [ProtocolTemplateID] = []
        var protocolReplaced: [(current: URL?, kept: URL?)] = []
        var reportKept: [URL] = []
    }

    private func makeRegenerator(
        generator: MockProtocolGen = MockProtocolGen(), ops: ProtocolRegenerationFileOperations? = nil, hooks: Hooks = Hooks(),
    ) -> ProtocolRegenerator {
        let folder: URL = folder
        let stamp = stamp
        return ProtocolRegenerator(environment: .init(
            generatorFactory: { generator },
            templateStore: ProtocolTemplateStore(directory: templates),
            includeFullTranscript: { false },
            recordOnly: { false },
            queuedJobs: { [] },
            records: { [] },
            outputDir: { folder },
            notifier: RecordingNotifier(),
            fileOperations: ops ?? fileOperations(),
            now: { stamp },
            regenerated: { _, template in hooks.regenerated.append(template) },
            protocolReplaced: { _, current, kept in hooks.protocolReplaced.append((current, kept)) },
            reportKept: { _, kept in hooks.reportKept.append(kept) },
        ))
    }

    private var previousStamp: String {
        DateFormatter.filenameStamp("yyyyMMdd_HHmmss").string(from: stamp)
    }

    // MARK: - Writing a report

    func testAReportLandsOwnerOnlyBesideTheMeetingAndLeavesEveryOtherFile() async throws {
        try writeMeeting()
        try Data("# Minutes".utf8).write(to: url("\(basename) (Minutes).md"))
        let before = try folderContents()
        let hooks = Hooks()
        let sut = makeRegenerator(hooks: hooks)

        try await sut.regenerate(target(), options: Self.short, saveAs: .additionalReport)

        XCTAssertEqual(sut.phase, .succeeded(shortReport, warnings: []))
        XCTAssertTrue(try text(shortReport).hasPrefix("# Meeting Protocol - Standup"))
        let mode = try FileManager.default.attributesOfItem(atPath: shortReport.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, FileManager.ownerOnlyPermissions)
        var after = try folderContents()
        after[shortReport.lastPathComponent] = nil
        XCTAssertEqual(after, before, "the main protocol, the transcript and the other report stay byte for byte")
        XCTAssertTrue(hooks.regenerated.isEmpty, "the job keeps the template its main protocol was made with")
        XCTAssertTrue(hooks.protocolReplaced.isEmpty, "the record's notes stay the main protocol")
    }

    func testTheBuiltInTemplatesReportIsTheStandardOne() async throws {
        try writeMeeting()
        let sut = makeRegenerator()

        try await sut.regenerate(target(), options: MeetingProtocolOptions(template: .builtIn, rawBackground: ""), saveAs: .additionalReport)

        XCTAssertEqual(sut.phase, .succeeded(url("\(basename) (Standard).md"), warnings: []))
    }

    func testReplaceStillRecordsItsTemplateAndItsNotes() async throws {
        try writeMeeting()
        let hooks = Hooks()
        let sut = makeRegenerator(hooks: hooks)

        try await sut.regenerate(target(), options: Self.short, saveAs: .mainProtocol)

        XCTAssertEqual(sut.phase, .succeeded(md, warnings: []))
        XCTAssertEqual(hooks.regenerated, [.file(name: "Short")])
        XCTAssertEqual(hooks.protocolReplaced.map(\.current), [md])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shortReport.path))
    }

    func testAMeetingWithoutNotesGetsItsMainProtocolWhateverWasChosen() async throws {
        try writeMeeting(withProtocol: false)
        let hooks = Hooks()
        let sut = makeRegenerator(hooks: hooks)

        try await sut.regenerate(target(), options: Self.short, saveAs: .additionalReport)

        XCTAssertEqual(sut.phase, .succeeded(md, warnings: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shortReport.path))
        XCTAssertEqual(hooks.regenerated, [.file(name: "Short")])
    }

    func testTheSameTemplateReplacesItsReportAndTrashesTheOldOne() async throws {
        try writeMeeting()
        try Data("# Old short".utf8).write(to: shortReport)
        let sut = makeRegenerator()

        try await sut.regenerate(target(), options: Self.short, saveAs: .additionalReport)

        XCTAssertEqual(sut.phase, .succeeded(shortReport, warnings: []))
        XCTAssertTrue(try text(shortReport).hasPrefix("# Meeting Protocol"))
        XCTAssertEqual(try text(trashBin.appendingPathComponent("\(basename) (Short).previous-\(previousStamp).md")), "# Old short")
        XCTAssertEqual(try text(md), oldProtocol, "the main protocol is never touched")
    }

    func testARefusedTrashKeepsTheNewReportAndTheOldCopyBesideItWithAWarning() async throws {
        try writeMeeting()
        try Data("# Old short".utf8).write(to: shortReport)
        let hooks = Hooks()
        let sut = makeRegenerator(ops: fileOperations(trashRefuses: true), hooks: hooks)

        try await sut.regenerate(target(), options: Self.short, saveAs: .additionalReport)

        let kept = url("\(basename) (Short).previous-\(previousStamp).md")
        XCTAssertEqual(sut.phase, .succeeded(shortReport, warnings: [
            "The previous report could not be moved to the Trash and was kept as \(kept.lastPathComponent).",
        ]))
        XCTAssertEqual(try text(kept), "# Old short")
        XCTAssertTrue(try text(shortReport).hasPrefix("# Meeting Protocol"))
        XCTAssertEqual(hooks.reportKept, [kept], "the record lists the copy, so deleting the meeting finds it")
        XCTAssertTrue(hooks.protocolReplaced.isEmpty)
        let reports = try XCTUnwrap(MeetingReportFolder.read(
            folder: folder, basename: basename, list: { try? FileManager.default.contentsOfDirectory(atPath: $0.path) },
            read: { try? Data(contentsOf: $0) },
        )).reports
        XCTAssertEqual(reports.map(\.name), ["Short"], "the kept copy is no report")
    }

    // MARK: - Nothing changes when a step fails

    private func assertRunLeavesEveryFile(
        failingWith error: ProtocolRegenerationError, generator: MockProtocolGen = MockProtocolGen(),
        ops: ProtocolRegenerationFileOperations? = nil, file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        let sut = makeRegenerator(generator: generator, ops: ops)
        let target = try target()

        await sut.regenerate(target, options: Self.short, saveAs: .additionalReport)

        XCTAssertEqual(sut.phase, .failed(error.localizedDescription), file: file, line: line)
    }

    func testAReportThatAppearsChangesOrVanishesDuringTheRunStopsIt() async throws {
        try writeMeeting()
        let changes: [(String, () throws -> Void)] = [
            ("appears", { try Data("# Someone else's".utf8).write(to: self.shortReport) }),
            ("changes", { try Data("# Changed".utf8).write(to: self.shortReport) }),
            ("vanishes", { try FileManager.default.removeItem(at: self.shortReport) }),
        ]
        for (what, change) in changes {
            if what != "appears" { try Data("# Old short".utf8).write(to: shortReport) }
            let generator = MockProtocolGen()
            var during: [String: Data] = [:]
            generator.onGenerate = {
                try? change()
                during = (try? self.folderContents()) ?? [:]
            }

            try await assertRunLeavesEveryFile(failingWith: .filesChanged, generator: generator)

            XCTAssertEqual(try folderContents(), during, "a report that \(what) leaves every file as it was")
            try? FileManager.default.removeItem(at: shortReport)
        }
    }

    func testAMeetingThatTakesTheReportsNameDuringTheRunStopsIt() async throws {
        try writeMeeting()
        let generator = MockProtocolGen()
        generator.onGenerate = { try? Data("[Ben] Another meeting.".utf8).write(to: self.url("\(self.basename) (Short).txt")) }

        try await assertRunLeavesEveryFile(failingWith: .filesChanged, generator: generator)

        XCTAssertFalse(FileManager.default.fileExists(atPath: shortReport.path))
        XCTAssertEqual(try text(md), oldProtocol)
    }

    /// A folder that can no longer be listed right before the write stops the run:
    /// it cannot tell whether another meeting took the report's name.
    func testAFolderThatCannotBeListedBeforeTheWriteStopsTheRun() async throws {
        try writeMeeting()
        final class Listable { var yes = true }
        let listable = Listable()
        var ops = fileOperations()
        let list = ops.list
        ops.list = { listable.yes ? list($0) : nil }
        let generator = MockProtocolGen()
        generator.onGenerate = { listable.yes = false }

        try await assertRunLeavesEveryFile(
            failingWith: .writeFailed("the folder of the meeting notes could not be read"), generator: generator, ops: ops,
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: shortReport.path))
        XCTAssertEqual(try text(md), oldProtocol)
    }

    func testAFailedWriteOrGenerationLeavesEveryFile() async throws {
        try writeMeeting()
        try Data("# Old short".utf8).write(to: shortReport)
        let before = try folderContents()
        var ops = fileOperations()
        ops.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let failing = MockProtocolGen()
        failing.shouldThrow = true

        try await assertRunLeavesEveryFile(
            failingWith: .writeFailed(CocoaError(.fileWriteOutOfSpace).localizedDescription), ops: ops,
        )
        XCTAssertEqual(try folderContents(), before)
        try await assertRunLeavesEveryFile(failingWith: .generationFailed, generator: failing)
        XCTAssertEqual(try folderContents(), before)
    }
}
