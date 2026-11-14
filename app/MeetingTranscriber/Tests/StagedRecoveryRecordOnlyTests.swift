@testable import MeetingTranscriber
import XCTest

/// In record-only mode a recording the app died during is filed like one that
/// ended normally: after the next recovery pass its tracks and a sidecar are in
/// `<output folder>/recordings/`, and no job processes it. The pass runs on a
/// temporary staging folder and writes into a temporary output folder, never
/// the real ones.
@MainActor
final class StagedRecoveryRecordOnlyTests: XCTestCase {
    private let stem = "20260311_140000"

    /// A crashed dual-source recording: the raw app temp, an unfinalized mic
    /// track and the in-progress marker, all older than the age guard.
    private func stageCrashedRecording(in staging: URL) throws {
        let fixture = StagedRecordingFixture(dir: staging, stem: stem)
        try fixture.rawAppTemp(seconds: 2)
        try writeUnfinalizedWav(at: fixture.url(RecordingFileSuffix.mic), seconds: 1)
        try fixture.marker()
    }

    /// A controller on temporary folders whose rebuild runs the production
    /// recovery pass, with record-only on and the output fallback pointed
    /// into the test's own folder.
    private func makeController(in tmp: URL) throws -> PipelineController {
        let suiteName = "StagedRecoveryRecordOnlyTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suiteName)),
            apiKeyAccount: "\(suiteName)-openAI", claudeAPIKeyAccount: "\(suiteName)-claude",
            defaultOutputDir: tmp.appendingPathComponent("output", isDirectory: true),
        )
        settings.recordOnly = true
        // Nothing heavy if a job were processed after all.
        settings.diarize = false
        settings.vadEnabled = false
        settings.protocolProvider = .none
        let logDir = tmp.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        var environment = IsolatedQueueEnvironment.make(logDir: logDir)
        environment.recoverStagedRecordings = PipelineController.QueueEnvironment.production.recoverStagedRecordings
        try FileManager.default.createDirectory(at: environment.stagingDir, withIntermediateDirectories: true)
        let pc = PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: environment,
            terminalJobStore: TerminalJobStore(path: logDir.appendingPathComponent("terminal_jobs.json")),
        )
        pc.activate { MockEngine() }
        return pc
    }

    func testACrashedRecordingInRecordOnlyModeIsWrittenWithItsSidecarAndNotQueued() async throws {
        let tmp = try makeTempDirectory(prefix: "StagedRecoveryRecordOnly")
        let pc = try makeController(in: tmp)
        let staging = pc.queueEnvironment.stagingDir
        try stageCrashedRecording(in: staging)

        pc.rebuild()
        await PipelineController.stagedRecoveryPass?.value
        await pc.awaitSnapshotFlushes()

        let recordings = tmp.appendingPathComponent("output/recordings")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path).sorted()) ?? []
        XCTAssertEqual(
            written,
            [stem + RecordingFileSuffix.app, stem + RecordingSidecar.filenameSuffix, stem + RecordingFileSuffix.mic, stem + RecordingFileSuffix.mix],
            "the recording was not filed with its sidecar",
        )
        let left = try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0.hasPrefix(stem) }
        XCTAssertEqual(left, [], "files of the recording stayed in staging")
        XCTAssertEqual(pc.queue.jobs.map(\.meetingTitle), [], "the recording was queued for processing")
        XCTAssertEqual((try? PipelineSnapshot.load(from: pc.queueEnvironment.logDir))?.count ?? 0, 0, "a snapshot entry")
        XCTAssertEqual(pc.meetingFileStore.records.count, 0, "a meeting-file record")
    }
}
