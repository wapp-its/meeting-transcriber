@testable import MeetingTranscriber
import XCTest

/// A job's protocol template and background, from the moment the queue admits
/// it to the instructions the protocol generator receives. Every queue reads
/// templates from a temp folder, never the real Application Support.
@MainActor
final class PipelineQueueProtocolTemplateTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var store: ProtocolTemplateStore!
    /// What the settings name as the default template right now.
    private var currentDefault: ProtocolTemplateID = .builtIn
    /// The settings' template rules right now.
    private var currentRules: [ProtocolTemplateRule] = []

    private let boardText = "Board template in {LANGUAGE}."
    private let dailyText = "Daily template in {LANGUAGE}."
    private let background = "Alice chairs, Bob reports on the budget"

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline-protocol-template")
        store = ProtocolTemplateStore(directory: tmpDir.appendingPathComponent("templates", isDirectory: true))
        try store.create(name: "Board")
        try boardText.write(to: store.fileURL(named: "Board"), atomically: true, encoding: .utf8)
        try dailyText.write(to: store.fileURL(named: "Daily"), atomically: true, encoding: .utf8)
    }

    private func makeEngine() -> MockEngine {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello everyone")]
        return engine
    }

    private func makeQueue(engine: MockEngine, protocolGen: MockProtocolGen) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            defaultProtocolTemplateProvider: { self.currentDefault },
            protocolTemplateRulesProvider: { self.currentRules },
            protocolTemplateStore: store,
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    private func makeJob(
        template: ProtocolTemplateID?, background: String?, title: String = "Board meeting",
    ) throws -> PipelineJob {
        try PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
            protocolTemplate: template, protocolBackground: background,
        )
    }

    private var builtIn: String {
        ProtocolGenerator.protocolPrompt
    }

    // MARK: - From enqueue to the generator

    func testAJobsTemplateAndBackgroundReachTheGenerator() async throws {
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)

        try queue.enqueue(makeJob(template: .file(name: "Board"), background: background))
        await queue.awaitProcessing()

        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText, background: background))
        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertEqual(queue.jobs.first?.warnings, [])
    }

    func testTheDefaultIsFixedWhenTheJobIsQueued() async throws {
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)
        currentDefault = .file(name: "Board")

        try queue.enqueue(makeJob(template: nil, background: nil))
        currentDefault = .builtIn
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.protocolTemplate, .file(name: "Board"))
        XCTAssertEqual(protocolGen.capturedInstructions?.template, boardText)
    }

    // MARK: - Template rules

    func testAJobWithoutATemplateGetsTheTemplateTheRulesPickForItsTitle() async throws {
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)
        currentRules = [ProtocolTemplateRule(pattern: "daily|stand-?up", template: .file(name: "Daily"))]

        try queue.enqueue(makeJob(template: nil, background: nil, title: "Team Daily"))
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.protocolTemplate, .file(name: "Daily"))
        XCTAssertEqual(protocolGen.capturedInstructions?.template, dailyText)
    }

    func testAJobWithItsOwnTemplateKeepsItWhateverTheRulesSay() async throws {
        let queue = makeQueue(engine: makeEngine(), protocolGen: MockProtocolGen())
        currentRules = [ProtocolTemplateRule(pattern: "daily", template: .file(name: "Daily"))]

        try queue.enqueue(makeJob(template: .file(name: "Board"), background: nil, title: "Team Daily"))

        XCTAssertEqual(queue.jobs.first?.protocolTemplate, .file(name: "Board"))
        await queue.awaitProcessing()
    }

    func testATitleNoRuleMatchesAndARuleWhoseTemplateIsMissingGetTheDefault() async throws {
        let queue = makeQueue(engine: makeEngine(), protocolGen: MockProtocolGen())
        currentDefault = .file(name: "Board")
        currentRules = [
            ProtocolTemplateRule(pattern: "retro", template: .file(name: "Gone")),
            ProtocolTemplateRule(pattern: "daily", template: .file(name: "Daily")),
        ]

        try queue.enqueue(makeJob(template: nil, background: nil, title: "Microsoft Teams Call"))
        try queue.enqueue(makeJob(template: nil, background: nil, title: "Sprint Retro"))

        XCTAssertEqual(queue.jobs.map(\.protocolTemplate), [.file(name: "Board"), .file(name: "Board")])
        await queue.awaitProcessing()
    }

    func testWithNoRulesEveryJobGetsTheDefaultAsBefore() async throws {
        let queue = makeQueue(engine: makeEngine(), protocolGen: MockProtocolGen())
        currentDefault = .file(name: "Board")

        try queue.enqueue(makeJob(template: nil, background: nil, title: "Team Daily"))

        XCTAssertEqual(queue.jobs.first?.protocolTemplate, .file(name: "Board"))
        await queue.awaitProcessing()
    }

    /// The template is decided when the job enters the queue (spec A5): a rule
    /// changed afterwards does not move a job already admitted.
    func testTheRulesAreReadWhenTheJobIsQueued() async throws {
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)
        currentRules = [ProtocolTemplateRule(pattern: "daily", template: .file(name: "Daily"))]

        try queue.enqueue(makeJob(template: nil, background: nil, title: "Team Daily"))
        currentRules = []
        await queue.awaitProcessing()

        XCTAssertEqual(protocolGen.capturedInstructions?.template, dailyText)
    }

    func testARecoveredOrphanGetsTheTemplateTheRulesPickForItsTitle() async throws {
        let recordings = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 100).write(to: recordings.appendingPathComponent("20260311_100000_mix.wav"))
        let queue = PipelineQueue(
            logDir: tmpDir,
            inFlightRuns: InFlightRunRegistry(),
            defaultProtocolTemplateProvider: { .file(name: "Board") },
            protocolTemplateRulesProvider: { [ProtocolTemplateRule(pattern: "^recovered", template: .file(name: "Daily"))] },
            protocolTemplateStore: store,
        )

        await queue.recoverOrphanedRecordings(recordingsDir: recordings)

        XCTAssertEqual(queue.jobs.map(\.protocolTemplate), [.file(name: "Daily")])
    }

    func testARetriedJobKeepsItsTemplateAndBackground() async throws {
        let engine = makeEngine()
        engine.shouldThrow = true
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: engine, protocolGen: protocolGen)
        let job = try makeJob(template: .file(name: "Board"), background: background)
        queue.enqueue(job)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.jobs.first?.state, .error, "test premise: the first run failed")

        engine.shouldThrow = false
        XCTAssertTrue(queue.retryJob(id: job.id))
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText, background: background))
    }

    // MARK: - Falling back

    func testAMissingOrBlankTemplateFallsBackToTheBuiltInWithAWarning() async throws {
        try " \n\t\n".write(to: store.fileURL(named: "Blank"), atomically: true, encoding: .utf8)
        for name in ["Gone", "Blank"] {
            let protocolGen = MockProtocolGen()
            let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)

            try queue.enqueue(makeJob(template: .file(name: name), background: background))
            await queue.awaitProcessing()

            let job = try XCTUnwrap(queue.jobs.first)
            XCTAssertEqual(job.state, .done, name)
            XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: builtIn, background: background), name)
            XCTAssertEqual(
                job.warnings,
                ["Protocol template \"\(name)\" was not found or is empty, so the built-in template was used"],
                name,
            )
        }
    }

    /// A job restored from a snapshot written before templates carries
    /// neither key, and gets what it got then: the current default.
    func testAJobFromAnOlderSnapshotUsesTheCurrentDefault() async throws {
        let job = try makeJob(template: nil, background: nil)
        let snapshot = try JSONEncoder().encode([job])
        let json = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
        XCTAssertFalse(json.contains("protocolTemplate"), "test premise: written without the new keys")
        try snapshot.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
        let protocolGen = MockProtocolGen()
        let restored = makeQueue(engine: makeEngine(), protocolGen: protocolGen)
        currentDefault = .file(name: "Board")

        restored.loadSnapshot()
        await restored.awaitProcessing()

        XCTAssertEqual(restored.jobs.first?.state, .done)
        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText, background: nil))
    }

    func testARecoveredOrphanIsStampedWithTheDefault() async throws {
        let recordings = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 100).write(to: recordings.appendingPathComponent("20260311_100000_mix.wav"))
        let queue = PipelineQueue(
            logDir: tmpDir,
            inFlightRuns: InFlightRunRegistry(),
            defaultProtocolTemplateProvider: { .file(name: "Board") },
            protocolTemplateStore: store,
        )

        await queue.recoverOrphanedRecordings(recordingsDir: recordings)

        XCTAssertEqual(queue.jobs.map(\.protocolTemplate), [.file(name: "Board")])
    }

    // MARK: - Restore

    /// The resume after a quit during protocol generation reads the job's own
    /// template and background, not the default of the next launch.
    func testTheProtocolOnlyResumeUsesTheJobsTemplate() async throws {
        let first = makeQueue(engine: makeEngine(), protocolGen: MockProtocolGen())
        let job = try makeJob(template: .file(name: "Board"), background: background)
        first.enqueue(job)
        await first.awaitProcessing()
        await first.awaitSnapshotFlush()
        var interrupted = try XCTUnwrap(first.jobs.first)
        interrupted.state = .generatingProtocol
        interrupted.protocolPath = nil
        try JSONEncoder().encode([interrupted]).write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let engine = makeEngine()
        let protocolGen = MockProtocolGen()
        let restored = makeQueue(engine: engine, protocolGen: protocolGen)
        restored.loadSnapshot()
        await restored.awaitProcessing()

        XCTAssertEqual(engine.transcribeCallCount, 0, "test premise: the restore resumed the protocol only")
        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText, background: background))
    }
}
