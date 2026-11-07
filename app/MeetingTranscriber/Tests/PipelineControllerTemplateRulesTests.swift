@testable import MeetingTranscriber
import XCTest

/// The template rules from the settings to an imported file's job: the queue
/// the controller builds reads the settings' rules, and an import's job gets
/// the template the rules pick for the title the import gave it.
@MainActor
final class PipelineControllerTemplateRulesTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var settings: AppSettings!
    private var store: ProtocolTemplateStore!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerTemplateRulesTests")
        let suite = "PipelineControllerTemplateRulesTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        store = ProtocolTemplateStore(directory: tmpDir.appendingPathComponent("templates", isDirectory: true))
        try store.create(name: "Daily")
        settings.protocolTemplateRules = [ProtocolTemplateRule(pattern: "daily", template: .file(name: "Daily"))]
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// A controller over a queue that reads this test's settings and templates
    /// folder, so nothing reads the real Application Support.
    private func makeController() -> PipelineController {
        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
            protocolTemplateRulesProvider: { [settings] in settings?.protocolTemplateRules ?? [] },
            protocolTemplateStore: store,
        )
        return PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: queue),
        )
    }

    private func touch(_ names: [String]) -> [URL] {
        names.map { name in
            let url = tmpDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("RIFF".utf8))
            return url
        }
    }

    func testTheQueueTheControllerBuildsReadsTheSettingsRulesAtTheCall() throws {
        let pc = PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir),
        )
        pc.activate { MockEngine() }
        let queue = try XCTUnwrap(pc.makeQueue())

        XCTAssertEqual(queue.protocolTemplateRulesProvider(), settings.protocolTemplateRules)
        settings.protocolTemplateRules = []
        XCTAssertEqual(queue.protocolTemplateRulesProvider(), [])
    }

    func testASingleImportGetsTheTemplateTheRulesPickForItsFileName() {
        let pc = makeController()

        pc.enqueueFiles(touch(["Team Daily.wav", "Board Review.wav"]))

        XCTAssertEqual(pc.queue.jobs.map(\.meetingTitle), ["Team Daily", "Board Review"])
        XCTAssertEqual(pc.queue.jobs.map(\.protocolTemplate), [.file(name: "Daily"), .builtIn])
    }

    /// The sidecar's title is the job's title, so the rule follows it and not
    /// the file names.
    func testAPairedImportGetsTheTemplateTheRulesPickForItsSidecarTitle() throws {
        let pc = makeController()
        let files = touch(["standup_app.wav", "standup_mic.wav"])
        let start = Date(timeIntervalSince1970: 1_772_615_700)
        try RecordingSidecar(
            title: "Team Daily", appName: "Teams", startedAt: start, stoppedAt: start + 900,
            participants: [], micDelaySeconds: 0, trigger: .auto,
            mixFilename: "standup_mix.wav", appFilename: "standup_app.wav", micFilename: "standup_mic.wav",
        ).write(toDirectory: tmpDir, basename: "standup")

        pc.enqueueFiles(files)

        let job = try XCTUnwrap(pc.queue.jobs.first)
        XCTAssertEqual(job.meetingTitle, "Team Daily")
        XCTAssertEqual(job.protocolTemplate, .file(name: "Daily"))
    }
}
