@testable import MeetingTranscriber
import XCTest

/// The Notion page title against protocol templates, under the rule the file
/// names follow (`PipelineQueue.meetingTitle`): the page takes the title the
/// model wrote when the notes came from the built-in template or from a
/// custom one whose switch "First heading contains the meeting title" is on.
/// Any other custom template's first heading is a section as often as a
/// title, so its page takes the job's title, the one the export uses for
/// notes with no heading.
@MainActor
final class PipelineQueueNotionTitleTemplateTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var store: ProtocolTemplateStore!

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

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline-notion-title-template")
        store = ProtocolTemplateStore(directory: tmpDir.appendingPathComponent("templates", isDirectory: true))
        try store.create(name: "Board")
        try "# Action items\n\n## Decisions\n".write(to: store.fileURL(named: "Board"), atomically: true, encoding: .utf8)
    }

    /// `titleHeading` names the templates whose switch is on, and
    /// `defaultTemplate` is the settings' default.
    private func makeQueue(
        exporter: TitleCapturingNotionExporter, heading: String, titleHeading: Set<String> = [],
        defaultTemplate: ProtocolTemplateID = .builtIn,
    ) -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello everyone")]
        let protocolGen = MockProtocolGen()
        protocolGen.headingTitle = heading
        let configuration = NotionExportConfiguration(exporter: exporter, databaseID: "database-1")
        let configurationProvider: () -> NotionExportResolution = { .ready(configuration) }
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            defaultProtocolTemplateProvider: { defaultTemplate },
            protocolTemplateStore: store,
            templateHasTitleHeading: { titleHeading.contains($0) },
            notionExportConfigurationProvider: configurationProvider,
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    /// Runs one job whose model writes `heading` as the title, waits for its
    /// export, and returns the page titles the exporter was handed.
    private func exportedTitles(
        template: ProtocolTemplateID, heading: String, titleHeading: Set<String> = [],
    ) async throws -> [String] {
        let exporter = TitleCapturingNotionExporter()
        let queue = makeQueue(exporter: exporter, heading: heading, titleHeading: titleHeading)
        try queue.enqueue(PipelineJob(
            meetingTitle: "Board meeting", appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
            protocolTemplate: template,
        ))
        await queue.awaitProcessing()
        await queue.awaitNotionExports()
        XCTAssertEqual(queue.jobs.first?.notionExportStatus, .completed, "test premise: the export ran")
        return await exporter.titles
    }

    func testTheBuiltInTemplateTitlesThePageAfterTheModelsTitle() async throws {
        let titles = try await exportedTitles(template: .builtIn, heading: "Sprint Planning")

        XCTAssertEqual(titles, ["Sprint Planning"])
    }

    func testACustomTemplateTitlesThePageAfterTheJob() async throws {
        let titles = try await exportedTitles(template: .file(name: "Board"), heading: "Action items")

        XCTAssertEqual(titles, ["Board meeting"])
    }

    func testACustomTemplateSwitchedOnTitlesThePageAfterItsFirstHeading() async throws {
        let titles = try await exportedTitles(template: .file(name: "Board"), heading: "Budget Review", titleHeading: ["Board"])

        XCTAssertEqual(titles, ["Budget Review"])
    }

    /// What decides is the prompt the job ran: a template that fell back to
    /// the built-in one asked for the built-in heading.
    func testACustomTemplateThatFellBackToTheBuiltInTitlesThePageAfterTheModelsTitle() async throws {
        let titles = try await exportedTitles(template: .file(name: "Gone"), heading: "Sprint Planning")

        XCTAssertEqual(titles, ["Sprint Planning"])
    }

    /// A retry reads the notes from the local backup, which does not say what
    /// template made them; the template the job recorded when it made them
    /// decides.
    func testARetryOfACustomTemplatesExportTitlesThePageAfterTheJob() async throws {
        let titles = try await retriedTitles(backup: "# Action items\n\n## Decisions\n", asked: .file(name: "Board"), used: .file(name: "Board"))

        XCTAssertEqual(titles, ["Board meeting"])
    }

    /// The template that ran decides, not the one asked for: after a fallback
    /// the notes carry the built-in heading.
    func testARetryAfterAFallbackTitlesThePageAfterTheModelsTitle() async throws {
        let titles = try await retriedTitles(
            backup: "# Meeting Protocol - Sprint Planning\n\n## Decisions\n", asked: .file(name: "Gone"), used: .builtIn,
        )

        XCTAssertEqual(titles, ["Sprint Planning"])
    }

    /// A job saved before the template that ran was recorded made its notes
    /// as every job did before templates: from the built-in one, whatever
    /// the default is now.
    func testARetryOfAJobThatRecordedNoTemplateTakesTheBuiltInsRule() async throws {
        let titles = try await retriedTitles(
            backup: "# Meeting Protocol - Sprint Planning\n", asked: nil, used: nil, defaultTemplate: .file(name: "Board"),
        )

        XCTAssertEqual(titles, ["Sprint Planning"])
    }

    /// Retries the failed export of a done job whose backup holds `backup`,
    /// with `asked` as its template and `used` as the one its notes came
    /// from, and returns the page titles the exporter was handed.
    private func retriedTitles(
        backup text: String, asked: ProtocolTemplateID?, used: ProtocolTemplateID?,
        defaultTemplate: ProtocolTemplateID = .builtIn,
    ) async throws -> [String] {
        let backup = tmpDir.appendingPathComponent("board.md")
        try text.write(to: backup, atomically: true, encoding: .utf8)
        let exporter = TitleCapturingNotionExporter()
        let queue = makeQueue(exporter: exporter, heading: "unused", defaultTemplate: defaultTemplate)
        var job = PipelineJob(
            meetingTitle: "Board meeting", appName: "Teams", mixPath: nil,
            appPath: nil, micPath: nil, micDelay: 0, protocolTemplate: asked,
        )
        job.usedProtocolTemplate = used
        job.state = .done
        job.protocolPath = backup
        job.beginNotionExport(speakerNames: [])
        job.finishNotionExport(succeeded: false)
        queue.insertJobForTesting(job)

        let retried = await queue.retryNotionExport(id: job.id)

        XCTAssertTrue(retried, "test premise: the retry ran")
        return await exporter.titles
    }
}
