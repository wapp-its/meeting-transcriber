@testable import MeetingTranscriber
import XCTest

/// Crash recovery at launch balances a rebuilt mix with the switch's value at
/// that launch. The recovery runs from the staging-recovery callback of each
/// queue the controller builds, so the controller has to hand the setting over
/// when it builds one. What the production callback does with it is pinned in
/// `StagedRecoveryFolderTests` and `DualSourceRecorderCrashRecoveryTests`.
@MainActor
final class PipelineControllerLevelBalanceTests: XCTestCase {
    /// The flags the staging recovery was handed, one per queue built.
    @MainActor
    private final class Handed {
        var flags: [Bool] = []
    }

    func testEachBuiltQueueHandsTheCurrentSettingToTheStagedRecovery() throws {
        let tmpDir = try makeTempDirectory(prefix: "PipelineControllerLevelBalance")
        let suiteName = "PipelineControllerLevelBalanceTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        let settings = try AppSettings(
            defaults: XCTUnwrap(UserDefaults(suiteName: suiteName)),
            apiKeyAccount: "\(suiteName)-openAI", claudeAPIKeyAccount: "\(suiteName)-claude",
            defaultOutputDir: tmpDir.appendingPathComponent("default-output", isDirectory: true),
        )
        let logDir = tmpDir.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let handed = Handed()
        var environment = PipelineController.QueueEnvironment(
            logDir: logDir,
            stagingDir: tmpDir.appendingPathComponent("staging", isDirectory: true),
        )
        environment.recoverStagedRecordings = { _, levelBalance in handed.flags.append(levelBalance) }
        let pc = PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            terminalJobStore: TerminalJobStore(path: logDir.appendingPathComponent("terminal_jobs.json")),
            queueEnvironment: environment,
        )
        pc.activate { MockEngine() }

        for enabled in [true, false] {
            settings.levelBalanceEnabled = enabled
            _ = pc.makeQueue()
        }

        XCTAssertEqual(handed.flags, [true, false], "read when the queue is built, not when the controller was")
    }
}
