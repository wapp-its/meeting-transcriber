@testable import MeetingTranscriber
import XCTest

/// Regenerating a finished meeting's protocol: what reaches the provider, and
/// that the old protocol is never lost, whichever step fails. Real files in a
/// temp directory; the generator, the Trash and single file steps are fakes.
@MainActor
final class ProtocolRegeneratorTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var folder: URL!
    private var templates: URL!
    private var trashBin: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    private let basename = "20261013_0900_standup_ab12cd34"
    private let oldProtocol = "# Old protocol"
    private let transcriptText = "[Anna] We ship on Friday."
    private let stamp = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUp() async throws {
        try await super.setUp()
        folder = try makeTempDirectory(prefix: "regenerator_test")
        templates = try makeTempDirectory(prefix: "regenerator_templates")
        trashBin = try makeTempDirectory(prefix: "regenerator_trash")
    }

    private var txt: URL {
        folder.appendingPathComponent("\(basename).txt")
    }

    private var md: URL {
        folder.appendingPathComponent("\(basename).md")
    }

    /// `<basename>.previous-<stamp>.md`, the stamp in local time like the code.
    private var previousName: String {
        "\(basename).previous-\(DateFormatter.filenameStamp("yyyyMMdd_HHmmss").string(from: stamp)).md"
    }

    // MARK: - Fixtures

    private func writeMeeting(transcript: Bool = true, protocolText: String? = nil) throws {
        if transcript { try Data(transcriptText.utf8).write(to: txt) }
        try Data((protocolText ?? oldProtocol).utf8).write(to: md)
    }

    private func target() throws -> ProtocolRegenerationTarget {
        try ProtocolRegenerationTarget.resolve(file: md, records: []) { try? Data(contentsOf: $0) }
    }

    /// Every file in the meeting's folder with its bytes.
    private func folderContents() throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            try (name, Data(contentsOf: folder.appendingPathComponent(name)))
        })
    }

    private func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The real file operations, except the Trash, which moves into a temp folder.
    private func fileOperations() -> ProtocolRegenerationFileOperations {
        var ops = ProtocolRegenerationFileOperations.live
        let trashBin: URL = trashBin
        ops.trash = { url in try FileManager.default.moveItem(at: url, to: trashBin.appendingPathComponent(url.lastPathComponent)) }
        return ops
    }

    private func makeRegenerator(
        generator: (any ProtocolGenerating)? = MockProtocolGen(),
        fileOperations: ProtocolRegenerationFileOperations? = nil,
        includeFullTranscript: Bool = false,
        recordOnly: Bool = false,
        notifier: RecordingNotifier = RecordingNotifier(),
        jobs: @escaping @MainActor () -> [PipelineJob] = { [] },
    ) -> ProtocolRegenerator {
        let folder: URL = folder
        let stamp = stamp
        let now: () -> Date = { stamp }
        return ProtocolRegenerator(environment: .init(
            generatorFactory: { generator },
            templateStore: ProtocolTemplateStore(directory: templates),
            includeFullTranscript: { includeFullTranscript },
            recordOnly: { recordOnly },
            queuedJobs: jobs,
            records: { [] },
            outputDir: { folder },
            notifier: notifier,
            fileOperations: fileOperations ?? self.fileOperations(),
            now: now,
        ))
    }

    private func job(slug: String, state: JobState) -> PipelineJob {
        var job = PipelineJob(meetingTitle: "Standup", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.namingSlug = slug
        job.state = state
        return job
    }

    private static let options = MeetingProtocolOptions(template: .builtIn, rawBackground: "")

    // MARK: - Success

    func testSuccessPutsTheNewProtocolOwnerOnlyAtTheOldPathAndTrashesTheOldOne() async throws {
        try writeMeeting()
        let notifier = RecordingNotifier()
        let sut = makeRegenerator(notifier: notifier)

        try await sut.regenerate(target(), options: Self.options)

        XCTAssertEqual(sut.phase, .succeeded(md, warnings: []))
        XCTAssertTrue(try text(at: md).hasPrefix("# Meeting Protocol - standup_ab12cd34"))
        let mode = try FileManager.default.attributesOfItem(atPath: md.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, FileManager.ownerOnlyPermissions)
        XCTAssertEqual(try text(at: trashBin.appendingPathComponent(previousName)), oldProtocol)
        XCTAssertEqual(try Set(folderContents().keys), ["\(basename).txt", "\(basename).md"], "staging or previous file left behind")
        XCTAssertEqual(try text(at: txt), transcriptText, "the transcript is never touched")
        XCTAssertEqual(notifier.calls.map(\.title), [ProtocolRegenerator.succeededTitle])
    }

    func testARefusingTrashLeavesThePreviousProtocolBesideTheNewOne() async throws {
        try writeMeeting()
        var ops = fileOperations()
        ops.trash = { _ in throw CocoaError(.featureUnsupported) }
        let sut = makeRegenerator(fileOperations: ops)

        try await sut.regenerate(target(), options: Self.options)

        guard case let .succeeded(url, warnings) = sut.phase else {
            XCTFail("expected success, got \(sut.phase)")
            return
        }
        XCTAssertEqual(url, md)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(try text(at: folder.appendingPathComponent(previousName)), oldProtocol)
        XCTAssertTrue(try text(at: md).hasPrefix("# Meeting Protocol"))
    }

    // MARK: - Failures while writing

    func testAFailingWriteStepLeavesTheOriginalAndNoStagingFile() async throws {
        let failure = CocoaError(.fileWriteNoPermission)
        let stagingName = "\(basename).md.regenerating"
        var failingWrite = fileOperations()
        failingWrite.write = { _, _ in throw failure }
        var failingRestrict = fileOperations()
        failingRestrict.restrictToOwner = { _ in throw failure }
        var failingFinalRename = fileOperations()
        let liveMove = failingFinalRename.move
        failingFinalRename.move = { from, to in
            if from.lastPathComponent == stagingName { throw failure }
            try liveMove(from, to)
        }
        let cases = [("staging write", failingWrite), ("permission change", failingRestrict), ("final rename", failingFinalRename)]

        for (step, ops) in cases {
            try writeMeeting()
            let before = try folderContents()
            let sut = makeRegenerator(fileOperations: ops)

            try await sut.regenerate(target(), options: Self.options)

            XCTAssertEqual(try folderContents(), before, "\(step): the folder changed")
            guard case .failed = sut.phase else {
                XCTFail("\(step): expected a failure, got \(sut.phase)")
                continue
            }
        }
    }

    func testAThrowingGeneratorChangesNoFile() async throws {
        try writeMeeting()
        let before = try folderContents()
        let generator = MockProtocolGen()
        generator.shouldThrow = true
        let notifier = RecordingNotifier()
        let sut = makeRegenerator(generator: generator, notifier: notifier)

        try await sut.regenerate(target(), options: Self.options)

        XCTAssertEqual(try folderContents(), before)
        XCTAssertEqual(sut.phase, .failed(ProtocolRegenerationError.generationFailed("Mock protocol error").localizedDescription))
        XCTAssertEqual(notifier.calls.map(\.title), [ProtocolRegenerator.failedTitle])
    }

    // MARK: - Transcript from the protocol

    func testAProtocolSourcedTranscriptKeepsTheFullTranscriptSection() async throws {
        let onlyCopy = "[Ben] The only copy of what was said."
        try writeMeeting(transcript: false, protocolText: oldProtocol + ProtocolGenerator.fullTranscriptSeparator + onlyCopy)
        let generator = MockProtocolGen()
        let sut = makeRegenerator(generator: generator, includeFullTranscript: false)

        try await sut.regenerate(target(), options: Self.options)

        XCTAssertEqual(generator.capturedTranscript, onlyCopy)
        XCTAssertEqual(try ProtocolGenerator.fullTranscript(in: text(at: md)), onlyCopy)
    }

    // MARK: - Refused before generating

    func testProviderOffRecordOnlyAndABusyMeetingAreRefusedBeforeGenerating() async throws {
        try writeMeeting()
        struct Refusal {
            let name: String
            let generator: MockProtocolGen?
            let recordOnly: Bool
            let jobs: [PipelineJob]
            let expected: ProtocolRegenerationError
        }
        let busy = job(slug: basename, state: .transcribing)
        let cases = [
            Refusal(name: "provider None", generator: nil, recordOnly: false, jobs: [], expected: .providerOff),
            Refusal(name: "record-only", generator: MockProtocolGen(), recordOnly: true, jobs: [], expected: .recordOnly),
            Refusal(name: "busy", generator: MockProtocolGen(), recordOnly: false, jobs: [busy], expected: .meetingBusy),
        ]
        let before = try folderContents()

        for refusal in cases {
            let jobs = refusal.jobs
            let sut = makeRegenerator(generator: refusal.generator, recordOnly: refusal.recordOnly) { jobs }

            try await sut.regenerate(target(), options: Self.options)

            XCTAssertEqual(sut.phase, .failed(refusal.expected.localizedDescription), refusal.name)
            XCTAssertFalse(refusal.generator?.generateCalled ?? false, "\(refusal.name): generated anyway")
            XCTAssertEqual(try folderContents(), before, refusal.name)
        }
    }

    // MARK: - A Retry while generating

    func testARetryStillRunningWhenTheProviderReturnsMakesTheCommitAbort() async throws {
        try writeMeeting()
        let before = try folderContents()
        let generator = SuspendedGenerator()
        let queue = QueuedJobs()
        let sut = makeRegenerator(generator: generator) { queue.jobs }
        let target = try target()

        let run = Task { await sut.regenerate(target, options: Self.options) }
        await generator.started()
        queue.jobs = [job(slug: basename, state: .transcribing)]
        generator.finish()
        await run.value

        XCTAssertEqual(sut.phase, .failed(ProtocolRegenerationError.meetingBusy.localizedDescription))
        XCTAssertEqual(try folderContents(), before)
    }

    func testARetryThatFinishedWhileGeneratingKeepsTheFilesItWrote() async throws {
        try writeMeeting()
        let generator = SuspendedGenerator()
        let sut = makeRegenerator(generator: generator) { [self] in [job(slug: basename, state: .done)] }
        let target = try target()

        let run = Task { await sut.regenerate(target, options: Self.options) }
        await generator.started()
        try Data("[Anna] The retry's transcript".utf8).write(to: txt)
        try Data("# The retry's protocol".utf8).write(to: md)
        let retried = try folderContents()
        generator.finish()
        await run.value

        XCTAssertEqual(sut.phase, .failed(ProtocolRegenerationError.filesChanged.localizedDescription))
        XCTAssertEqual(try folderContents(), retried)
    }

    // MARK: - Template and background

    func testTheChosenTemplateAndBackgroundReachTheGenerator() async throws {
        try writeMeeting()
        try Data("Board minutes in {LANGUAGE}".utf8).write(to: templates.appendingPathComponent("Board.md"))
        let generator = MockProtocolGen()
        let sut = makeRegenerator(generator: generator)

        try await sut.regenerate(target(), options: MeetingProtocolOptions(template: .file(name: "Board"), rawBackground: " Agenda: budget "))

        XCTAssertEqual(generator.capturedInstructions, ProtocolInstructions(template: "Board minutes in {LANGUAGE}", background: "Agenda: budget"))
        XCTAssertEqual(sut.phase, .succeeded(md, warnings: []))
    }

    func testAMissingTemplateFallsBackWithItsWarning() async throws {
        try writeMeeting()
        let generator = MockProtocolGen()
        let sut = makeRegenerator(generator: generator)

        try await sut.regenerate(target(), options: MeetingProtocolOptions(template: .file(name: "Gone"), rawBackground: ""))

        XCTAssertEqual(generator.capturedInstructions?.template, ProtocolGenerator.protocolPrompt)
        let warning = ProtocolTemplateStore(directory: templates).resolve(.file(name: "Gone")).warning
        XCTAssertNotNil(warning)
        XCTAssertEqual(sut.phase, .succeeded(md, warnings: [warning].compactMap(\.self)))
    }
}

/// The queue's jobs as a test changes them mid-run.
@MainActor
private final class QueuedJobs {
    var jobs: [PipelineJob] = []
}

/// A provider that waits until the test lets it answer, so the test can change
/// the queue and the files while a protocol is being made.
private final class SuspendedGenerator: ProtocolGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()

    func generate(
        transcript _: String, title _: String, diarized _: Bool, meetingStartTime _: Date?, instructions _: ProtocolInstructions,
    ) async -> String {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            startedContinuation.yield()
        }
    }

    func started() async {
        var iterator = startedStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func finish() {
        lock.withLock { continuation }?.resume(returning: "# New protocol")
    }
}
