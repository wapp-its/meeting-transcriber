@testable import MeetingTranscriber
import XCTest

/// Pauses carried through a paired re-import. Its own class because
/// `PipelineControllerTests` sits at the type body length limit.
@MainActor
final class PipelineControllerReimportPausesTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    /// Settings over a per-test `UserDefaults` suite, never `.standard`.
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerReimportPausesTests")
        let suite = "PipelineControllerReimportPausesTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// A controller whose queue is already wired to a mock engine and keeps its
    /// logs and snapshot in `tmpDir`, so no production-path I/O is touched.
    private func makeWiredController() -> PipelineController {
        PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: PipelineQueue(
                engine: MockEngine(),
                diarizationFactory: { MockDiarization() },
                protocolGeneratorFactory: { MockProtocolGen() },
                outputDir: tmpDir,
                logDir: tmpDir,
            )),
            terminalJobStore: nil,
        )
    }

    /// A paused record-only recording imported later carries its pauses into
    /// the job, which renders them as markers in the transcript. A sidecar
    /// without pauses reads as a recording without any.
    func testPairedReimportCarriesTheSidecarsPauses() throws {
        let start = try localDate(2026, 3, 4, 9, 15)
        let paused = [
            RecordingPause(startedAt: start + 600, endedAt: start + 900, offsetSeconds: 600),
            RecordingPause(startedAt: start + 1200, endedAt: start + 1260, offsetSeconds: 899.5),
        ]
        let rows: [(stem: String, pauses: [RecordingPause])] = [("paused", paused), ("unpaused", [])]
        let pc = makeWiredController()
        for (stem, pauses) in rows {
            let files = ["app", "mic"].map { tmpDir.appendingPathComponent("\(stem)_\($0).wav") }
            for url in files {
                FileManager.default.createFile(atPath: url.path, contents: Data("RIFF".utf8))
            }
            try RecordingSidecar(
                title: "Weekly Sync", appName: "Teams", startedAt: start, stoppedAt: start + 1800,
                participants: [], micDelaySeconds: 0, trigger: .auto,
                mixFilename: "\(stem)_mix.wav", appFilename: "\(stem)_app.wav", micFilename: "\(stem)_mic.wav",
                pauses: pauses,
            ).write(toDirectory: tmpDir, basename: stem)

            let id = try XCTUnwrap(pc.enqueueFiles(files).first)

            XCTAssertEqual(try XCTUnwrap(pc.queue.jobs.first { $0.id == id }).pauses, pauses.isEmpty ? nil : pauses, stem)
        }
    }
}
