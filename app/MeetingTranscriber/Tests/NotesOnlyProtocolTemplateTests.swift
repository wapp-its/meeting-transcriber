@testable import MeetingTranscriber
import XCTest

/// The meeting-notes template of the jobs that make notes only: notes for a
/// transcript the user picks, and a retry of notes that failed. They follow
/// the rule of every other job: the template is fixed when the job enters the
/// queue and read when the notes are made, so a default changed later never
/// reaches them, not even after a relaunch. And as for every job, only notes
/// from the built-in template, or from a template whose switch "First heading
/// contains the meeting title" is on, lend their first heading as the
/// meeting title.
@MainActor
final class NotesOnlyProtocolTemplateTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var dir: URL!
    private var store: ProtocolTemplateStore!
    // swiftlint:enable implicitly_unwrapped_optional
    /// What the settings name as the default template right now.
    private var currentDefault: ProtocolTemplateID = .builtIn

    private let boardText = "Board template in {LANGUAGE}."
    private let teamText = "Team template in {LANGUAGE}."

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "notes_only_template")
        store = ProtocolTemplateStore(directory: dir.appendingPathComponent("templates", isDirectory: true))
        for (name, text) in [("Board", boardText), ("Team", teamText)] {
            try store.create(name: name)
            try text.write(to: store.fileURL(named: name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Notes for a picked transcript

    func testNotesForAPickedTranscriptTakeTheDefaultWhenQueued() async throws {
        let generator = MockProtocolGen()
        let queue = makeQueue(generator: generator)
        currentDefault = .file(name: "Board")

        try queue.enqueueNotes(fromTranscripts: [transcript("20261030_0900_standup")])
        currentDefault = .file(name: "Team")
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.protocolTemplate, .file(name: "Board"))
        XCTAssertEqual(generator.capturedInstructions, ProtocolInstructions(template: boardText))
    }

    // MARK: - Retry of failed notes

    func testARetryUsesTheTemplateTheJobRecorded() async throws {
        let generator = MockProtocolGen()
        let queue = makeQueue(generator: generator)
        let id = try await failNotes(in: queue, generator: generator)

        currentDefault = .file(name: "Team")
        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        XCTAssertNotNil(queue.jobs.first { $0.id == id }?.protocolPath, "test premise: the retry saved notes")
        XCTAssertEqual(generator.capturedInstructions, ProtocolInstructions(template: boardText))
    }

    /// A retry reads the recorded template again. One deleted since falls back
    /// to the built-in one with the warning, which is no notes failure: the
    /// notes are saved and the job is not held for another retry.
    func testARetryWhoseTemplateWasDeletedMeanwhileUsesTheBuiltInWithAWarning() async throws {
        let generator = MockProtocolGen()
        let queue = makeQueue(generator: generator)
        let id = try await failNotes(in: queue, generator: generator)
        try FileManager.default.removeItem(at: store.fileURL(named: "Board"))

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        let job = try XCTUnwrap(queue.jobs.first { $0.id == id })
        XCTAssertEqual(generator.capturedInstructions, ProtocolInstructions(template: ProtocolGenerator.protocolPrompt))
        XCTAssertNotNil(job.protocolPath)
        XCTAssertEqual(job.warnings, ["The meeting notes template was not found or is empty, so the built-in template was used"])
        XCTAssertFalse(queue.canRetryMeetingNotes(id: id))
    }

    /// The snapshot keeps the template of a job held for a retry, so the
    /// retry after a relaunch asks for it, not for the next launch's default.
    func testFailedNotesKeepTheirTemplateAcrossARelaunch() async throws {
        let firstGenerator = MockProtocolGen()
        let first = makeQueue(generator: firstGenerator)
        let id = try await failNotes(in: first, generator: firstGenerator)
        await first.awaitSnapshotFlush()

        currentDefault = .file(name: "Team")
        let generator = MockProtocolGen()
        let restored = makeQueue(generator: generator)
        restored.loadSnapshot()
        XCTAssertTrue(restored.retryMeetingNotes(id: id))
        await restored.awaitProcessing()

        XCTAssertEqual(generator.capturedInstructions, ProtocolInstructions(template: boardText))
    }

    /// The same for a retry still waiting at the quit. The snapshot is the
    /// file on disk: one only saved in memory would never be decoded.
    func testARetryWaitingAtAQuitKeepsItsTemplateAfterTheRelaunch() async throws {
        let firstGenerator = MockProtocolGen()
        let first = makeQueue(generator: firstGenerator)
        let id = try await failNotes(in: first, generator: firstGenerator)
        XCTAssertTrue(first.retryMeetingNotes(id: id))
        let waiting = try XCTUnwrap(first.jobs.first { $0.id == id })
        // The quit: the first queue never runs the retry.
        first.removeJob(id: id)
        await first.awaitSnapshotFlush()
        try JSONEncoder().encode([waiting]).write(to: dir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        currentDefault = .file(name: "Team")
        let generator = MockProtocolGen()
        let restored = makeQueue(generator: generator)
        restored.loadSnapshot()
        XCTAssertEqual(restored.jobs.first { $0.id == id }?.state, .waiting, "test premise: the retry was still waiting")
        restored.triggerProcessing()
        await restored.awaitProcessing()

        XCTAssertEqual(generator.capturedInstructions, ProtocolInstructions(template: boardText))
    }

    // MARK: - The AI title

    /// Notes for a picked transcript never rename it, and their Notion page
    /// follows the rule of every job: a custom template's first heading is no
    /// title, so the page takes the job's, the transcript's name.
    func testNotesForAPickedTranscriptFromACustomTemplateTitleThePageAfterTheJob() async throws {
        let exporter = TitleCapturingNotionExporter()
        let generator = MockProtocolGen()
        generator.headingTitle = "Action items"
        let queue = makeQueue(generator: generator, exporter: exporter, useAITitleForFilenames: true)
        currentDefault = .file(name: "Board")

        try queue.enqueueNotes(fromTranscripts: [transcript("20261030_0900_standup")])
        await queue.awaitProcessing()
        await queue.awaitNotionExports()

        XCTAssertEqual(queue.jobs.first?.protocolPath?.lastPathComponent, "20261030_0900_standup.md")
        let titles = await exporter.titles
        XCTAssertEqual(titles, ["20261030_0900_standup"])
    }

    /// The switch counts for a picked transcript as for any job: its page
    /// takes the heading. The transcript keeps its name all the same.
    func testNotesForAPickedTranscriptFromATemplateSwitchedOnTitleThePageAfterTheirHeading() async throws {
        let exporter = TitleCapturingNotionExporter()
        let generator = MockProtocolGen()
        generator.headingTitle = "Budget Review"
        let queue = makeQueue(generator: generator, exporter: exporter, useAITitleForFilenames: true, titleHeading: ["Board"])
        currentDefault = .file(name: "Board")

        try queue.enqueueNotes(fromTranscripts: [transcript("20261030_0900_standup")])
        await queue.awaitProcessing()
        await queue.awaitNotionExports()

        XCTAssertEqual(queue.jobs.first?.protocolPath?.lastPathComponent, "20261030_0900_standup.md")
        let titles = await exporter.titles
        XCTAssertEqual(titles, ["Budget Review"])
    }

    /// A retry runs the template the job recorded, so notes from a custom
    /// one keep the date-based name and title the page after the job.
    func testARetryOfCustomTemplateNotesTakesNoTitleFromThem() async throws {
        let exporter = TitleCapturingNotionExporter()
        let generator = MockProtocolGen()
        generator.headingTitle = "Action items"
        let queue = makeQueue(generator: generator, exporter: exporter, useAITitleForFilenames: true)
        let id = try await failNotes(in: queue, generator: generator)
        let stem = try XCTUnwrap(queue.jobs.first { $0.id == id }?.namingSlug)

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()
        await queue.awaitNotionExports()

        XCTAssertEqual(queue.jobs.first { $0.id == id }?.protocolPath?.lastPathComponent, "\(stem).md")
        let titles = await exporter.titles
        XCTAssertEqual(titles, ["Sprint"])
    }

    // MARK: - Fixtures

    /// Records the page title of each export.
    private actor TitleCapturingNotionExporter: NotionExporting {
        private(set) var titles: [String] = []

        func exportMeeting( // swiftlint:disable:this function_parameter_count
            title: String, date _: Date?, tags _: [String], markdown _: String,
            transcript _: String?, existingPageID _: String?,
            onPageCreated _: @Sendable (NotionPageResult) async -> Void,
        ) -> NotionPageResult {
            titles.append(title)
            return NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
        }
    }

    /// `exporter` switches the Notion export on, into that exporter;
    /// `titleHeading` names the templates whose title switch is on.
    private func makeQueue(
        generator: MockProtocolGen, exporter: TitleCapturingNotionExporter? = nil, useAITitleForFilenames: Bool = false,
        titleHeading: Set<String> = [],
    ) -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello everyone")]
        let notion: (() -> NotionExportResolution)? = exporter.map { exporter in
            { .ready(NotionExportConfiguration(exporter: exporter, databaseID: "database-1")) }
        }
        return PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: dir, logDir: dir, stagingDir: dir.appendingPathComponent("staging"),
            useAITitleForFilenames: useAITitleForFilenames,
            defaultProtocolTemplateProvider: { self.currentDefault },
            protocolTemplateStore: store,
            templateHasTitleHeading: { titleHeading.contains($0) },
            notionExportConfigurationProvider: notion,
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    /// A recorded meeting queued while "Board" is the default, whose notes
    /// fail: done, with its transcript, and held for a retry. `generator` is
    /// the queue's own; it fails this once.
    private func failNotes(in queue: PipelineQueue, generator: MockProtocolGen) async throws -> UUID {
        currentDefault = .file(name: "Board")
        generator.shouldThrow = true
        let job = try PipelineJob(
            meetingTitle: "Sprint", appName: "Teams",
            mixPath: createTestAudioFile(in: dir), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        await queue.awaitProcessing()
        XCTAssertTrue(queue.canRetryMeetingNotes(id: job.id), "test premise: the notes failed")
        generator.shouldThrow = false
        return job.id
    }

    private func transcript(_ stem: String) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).txt")
        try "[Me] Hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
