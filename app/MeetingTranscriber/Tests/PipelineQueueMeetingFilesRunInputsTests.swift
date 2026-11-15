import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The run inputs a meeting's file record keeps for a re-run, written by the
/// real queue: when the job enters processing, and after its Notion export.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueMeetingFilesRunInputsTests: XCTestCase {
    private let meetingStart = Date(timeIntervalSinceReferenceDate: 780_000_000)
    /// What the export normalizes the configured database to.
    private let databaseID = "0123456789abcdef0123456789abcdef"

    private var pause: RecordingPause {
        RecordingPause(
            startedAt: meetingStart.addingTimeInterval(0.1), endedAt: meetingStart.addingTimeInterval(60), offsetSeconds: 0.1,
        )
    }

    /// In a folder of its own, which a test can make unwritable.
    private func storePath(in dir: URL) -> URL {
        dir.appendingPathComponent("records/meeting_files.json")
    }

    private func configuration(_ exporter: any NotionExporting) -> NotionExportConfiguration {
        NotionExportConfiguration(exporter: exporter, databaseID: "https://www.notion.so/team/\(databaseID)?v=1")
    }

    /// A queue that runs a job straight to `.done` and exports it, whose default
    /// template is "Board".
    private func makeQueue(in dir: URL, exporter: any NotionExporting) throws -> (PipelineQueue, MeetingFileStore) {
        let templates = ProtocolTemplateStore(directory: dir.appendingPathComponent("templates"))
        try FileManager.default.createDirectory(at: templates.directory, withIntermediateDirectories: true)
        try "Board notes".write(to: templates.fileURL(named: "Board"), atomically: true, encoding: .utf8)
        let store = MeetingFileStore(path: storePath(in: dir))
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        let notion = configuration(exporter)
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir.appendingPathComponent("output"),
            logDir: dir.appendingPathComponent("logs"),
            stagingDir: dir.appendingPathComponent("staging"),
            echoDedupEnabled: false,
            defaultProtocolTemplateProvider: { .file(name: "Board") },
            protocolTemplateStore: templates,
            notionExportConfigurationProvider: { .ready(notion) },
            meetingFileStore: store,
        )
        return (queue, store)
    }

    /// The three tracks of a call, with a mic delay, a pause, a muted stretch and a background.
    private func makeJob(in dir: URL) throws -> PipelineJob {
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let tracks = try (0 ..< 3).map { _ in try createTestAudioFile(in: staging) }
        return PipelineJob(
            meetingTitle: "Standup", appName: "Microsoft Teams",
            mixPath: tracks[0], appPath: tracks[1], micPath: tracks[2], micDelay: 0.25,
            micMuteIntervals: [MicMuteInterval(start: 0.1, end: 0.3)],
            meetingStartTime: meetingStart, pauses: [pause], protocolBackground: "Budget review",
        )
    }

    private var inputsAtEntry: MeetingFileRecord.RunInputs {
        MeetingFileRecord.RunInputs(
            micDelay: 0.25, pauses: [pause], micMuteIntervals: [MicMuteInterval(start: 0.1, end: 0.3)],
            protocolTemplate: .file(name: "Board"), protocolBackground: "Budget review",
        )
    }

    func testARecordedCallAndAnImportKeepTheirRunInputsAndTheirNotionPage() async throws {
        for origin in [MeetingFileRecord.Origin.recorded, .imported] {
            let dir = try makeTempDirectory(prefix: "run_inputs_\(origin.rawValue)")
            let (queue, store) = try makeQueue(in: dir, exporter: RetentionNotionExporter(fail: false))
            let job = try makeJob(in: dir)

            queue.enqueue(job, origin: origin)

            XCTAssertEqual(store.record(for: job.id)?.runInputs, inputsAtEntry, "\(origin): the template admission picked")

            await queue.awaitProcessing()

            var exported = inputsAtEntry
            exported.notionDatabaseID = databaseID
            exported.notionPageID = "page-1"
            XCTAssertEqual(queue.job(withID: job.id)?.notionExportStatus, .completed, "\(origin): test premise")
            XCTAssertEqual(store.record(for: job.id)?.runInputs, exported, "\(origin)")
            let reread = MeetingFileStore(path: storePath(in: dir)).record(for: job.id)
            XCTAssertEqual(reread?.runInputs, exported, "\(origin): a restart reads the same")
        }
    }

    /// The record is an extra: a write that fails after the export started is
    /// logged by the store, and the job ends as it would have.
    func testARecordWriteThatFailsAfterTheExportStartedLeavesTheJobAsItEnds() async throws {
        let dir = try makeTempDirectory(prefix: "run_inputs_unwritable")
        let exporter = GatedNotionExporter(pageCreation: .afterRelease)
        let (queue, _) = try makeQueue(in: dir, exporter: exporter)
        let job = try makeJob(in: dir)
        queue.enqueue(job, origin: .recorded)
        await waitFor { await exporter.startedExports == 1 }
        let started = await exporter.startedExports
        XCTAssertEqual(started, 1, "test premise: the export waits at its gate")
        let records = storePath(in: dir).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: records.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: records.path) }

        await exporter.release()
        await queue.awaitProcessing()

        let finished = try XCTUnwrap(queue.job(withID: job.id))
        XCTAssertEqual(finished.state, .done)
        XCTAssertNotNil(finished.protocolPath)
        XCTAssertEqual(finished.notionExportStatus, .completed)
        XCTAssertEqual(finished.notionPageID, "page-1")
        let onDisk = MeetingFileStore(path: storePath(in: dir)).record(for: job.id)
        XCTAssertEqual(onDisk?.runInputs, inputsAtEntry, "the file keeps what the last write that landed left")
    }

    /// A finished job whose export failed, which the queue holds for Retry Notion Export.
    private func runHeldForANotionRetry(in dir: URL) async throws -> (PipelineQueue, MeetingFileStore, PipelineJob) {
        let (queue, store) = try makeQueue(in: dir, exporter: RetentionNotionExporter(fail: true))
        let job = try makeJob(in: dir)
        queue.enqueue(job, origin: .recorded)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: job.id)?.notionExportStatus, .failed, "test premise")
        return (queue, store, job)
    }

    /// Regenerate Notes on a held job changes its template, and its export state
    /// is saved again; a re-run still takes the one the meeting entered processing with.
    func testARegeneratedTemplateLeavesTheKeptOne() async throws {
        let (queue, store, job) = try await runHeldForANotionRetry(in: makeTempDirectory(prefix: "run_inputs_regenerated"))

        queue.recordRegeneratedTemplate(jobID: job.id, template: .file(name: "Daily"))

        XCTAssertEqual(queue.job(withID: job.id)?.protocolTemplate, .file(name: "Daily"), "test premise")
        XCTAssertEqual(store.record(for: job.id)?.runInputs, inputsAtEntry)
    }

    /// An older build drops the field when it rewrites the record file.
    func testAnExportGivesARecordAnOlderBuildRewroteItsRunInputsBack() async throws {
        let (queue, store, job) = try await runHeldForANotionRetry(in: makeTempDirectory(prefix: "run_inputs_rewritten"))
        store.update(jobID: job.id) { $0.runInputs = nil }

        let exported = await queue.exportToNotion(
            jobID: job.id, protocolMD: "# Notes", transcript: nil, speakerNames: [],
            configuration: configuration(RetentionNotionExporter(fail: false)),
        )

        XCTAssertTrue(exported, "test premise")
        var expected = inputsAtEntry
        expected.notionDatabaseID = databaseID
        expected.notionPageID = "page-1"
        XCTAssertEqual(store.record(for: job.id)?.runInputs, expected)
    }
}
