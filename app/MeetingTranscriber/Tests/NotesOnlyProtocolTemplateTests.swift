@testable import MeetingTranscriber
import XCTest

/// The meeting-notes template of the jobs that make notes only: notes for a
/// transcript the user picks, and a retry of notes that failed. They follow
/// the rule of every other job: the template is fixed when the job enters the
/// queue and read when the notes are made, so a default changed later never
/// reaches them, not even after a relaunch.
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

    // MARK: - Fixtures

    private func makeQueue(generator: MockProtocolGen) -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello everyone")]
        return PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: dir, logDir: dir, stagingDir: dir.appendingPathComponent("staging"),
            defaultProtocolTemplateProvider: { self.currentDefault },
            protocolTemplateStore: store,
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
