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

    /// A controller on temporary folders whose rebuild runs `recover`, by
    /// default the production recovery pass, with record-only on and the
    /// output fallback pointed into the test's own folder.
    private func makeController(
        in tmp: URL,
        recover: (@MainActor (PipelineQueue, Bool, RecordOnlyRecovery) -> Void)? = PipelineController.QueueEnvironment.production
            .recoverStagedRecordings,
    ) throws -> PipelineController {
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
        environment.recoverStagedRecordings = recover
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

    /// A queue on `staging` with no engine, so nothing processes what it queues.
    private func makeQueue(staging: URL) throws -> PipelineQueue {
        try PipelineQueue(logDir: makeTempDirectory(prefix: "StagedRecoveryRecordOnlyLog"), stagingDir: staging)
    }

    /// One staged recovery pass on `staging`, the steps the production pass runs.
    private func runPass(on staging: URL, into queue: PipelineQueue, recordOnly: RecordOnlyRecovery) async {
        let unsettled = PipelineController.recoverStagingFolder(staging, levelBalance: false, diagnostics: RecordingDiagnostics())
        await PipelineController.recoverOrphans(
            into: queue, holdingBack: unsettled.map { staging.appendingPathComponent($0 + RecordingFileSuffix.mix) },
            recordingsDir: staging, recordOnly: recordOnly,
        )
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: - Filed or queued

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

    func testWithRecordOnlyOffTheCrashedRecordingIsQueuedAndGetsNoSidecar() async throws {
        let staging = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyOff")
        let output = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyOutput")
        try stageCrashedRecording(in: staging)
        let queue = try makeQueue(staging: staging)

        await runPass(on: staging, into: queue, recordOnly: .writing(into: output, on: false))

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Recovered Recording (\(stem))"])
        XCTAssertEqual(names(in: output), [], "record-only output for a recording queued for processing")
        XCTAssertTrue(names(in: staging).contains(stem + RecordingFileSuffix.mix), "the queued recording left staging")
    }

    /// The setting at the hand-on decides, not the one the queue was built
    /// with: the controller hands each pass a reader of the live setting.
    func testThePassReadsTheSettingWhenItHandsItsRecordingsOn() throws {
        var handed: [RecordOnlyRecovery] = []
        let pc = try makeController(in: makeTempDirectory(prefix: "StagedRecoveryRecordOnlyRead")) { _, _, recordOnly in
            handed.append(recordOnly)
        }
        pc.settings.recordOnly = false
        pc.rebuild()
        let recovery = try XCTUnwrap(handed.first)
        XCTAssertFalse(recovery.isOn())

        pc.settings.recordOnly = true

        XCTAssertTrue(recovery.isOn(), "read when the queue was built, not when the pass hands its recordings on")
    }

    // MARK: - The sidecar

    func testTheRecoveredSidecarHasTheRecoveryValuesAndReadsBack() async throws {
        let staging = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlySidecar")
        let output = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyOutput")
        try stageCrashedRecording(in: staging)

        try await runPass(on: staging, into: makeQueue(staging: staging), recordOnly: .writing(into: output))

        let recordings = output.appendingPathComponent("recordings")
        let data = try Data(contentsOf: recordings.appendingPathComponent(stem + RecordingSidecar.filenameSuffix))
        let keys = try Set(XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(
            keys, ["version", "title", "appName", "startedAt", "stoppedAt", "participants", "micDelaySeconds", "files"],
            "trigger and pauses are left out",
        )
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: recordings, basename: stem))
        // The stem is the recorder's local start time.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 14)))
        let mixLength = try XCTUnwrap(RecordingCut.duration(of: recordings.appendingPathComponent(stem + RecordingFileSuffix.mix)))
        XCTAssertEqual(sidecar.version, RecordingSidecar.currentVersion)
        XCTAssertEqual(sidecar.title, "Recovered Recording (\(stem))")
        XCTAssertEqual(sidecar.appName, "Unknown")
        XCTAssertEqual(sidecar.startedAt, startedAt)
        // The sidecar keeps whole seconds.
        XCTAssertEqual(sidecar.stoppedAt.timeIntervalSince(startedAt), mixLength, accuracy: 1)
        XCTAssertEqual(sidecar.participants, [])
        XCTAssertEqual(sidecar.micDelaySeconds, 0)
        XCTAssertNil(sidecar.trigger)
        XCTAssertNil(sidecar.pauses)
        XCTAssertEqual(
            [sidecar.files.mix, sidecar.files.app, sidecar.files.mic],
            [stem + RecordingFileSuffix.mix, stem + RecordingFileSuffix.app, stem + RecordingFileSuffix.mic],
        )
    }

    func testARecordingWhoseStemIsNoTimeAndWhoseMixCannotBeReadIsStillFiled() async throws {
        let staging = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyOdd")
        let output = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyOutput")
        // The fixture's default stem is title-derived, not a time.
        let fixture = StagedRecordingFixture(dir: staging)
        let mix = fixture.url(RecordingFileSuffix.mix)
        try Data(repeating: 0xFF, count: 100).write(to: mix)
        let created = try XCTUnwrap(mix.resourceValues(forKeys: [.creationDateKey]).creationDate)

        try await runPass(on: staging, into: makeQueue(staging: staging), recordOnly: .writing(into: output))

        let recordings = output.appendingPathComponent("recordings")
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: recordings, basename: fixture.stem), "not filed")
        XCTAssertEqual(sidecar.startedAt.timeIntervalSince(created), 0, accuracy: 1)
        XCTAssertEqual(sidecar.stoppedAt, sidecar.startedAt)
        XCTAssertEqual(sidecar.files.mix, fixture.stem + RecordingFileSuffix.mix)
    }

    // MARK: - A write that fails

    /// The output folder cannot be written, so every write of the pass fails:
    /// the recordings stay in staging, nothing is left in the output folder,
    /// nothing is queued, and one notice gives the count. The next pass, with
    /// the folder writable again, files them without a further notice.
    func testAWriteThatFailsKeepsTheRecordingInStagingAndALaterPassFilesIt() async throws {
        let cases = [
            (1, "A recovered recording could not be written to the output folder. It stays in the app's staging folder and is tried again later."),
            (2, "2 recovered recordings could not be written to the output folder. They stay in the app's staging folder and are tried again later."),
        ]
        for (count, body) in cases {
            let staging = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyFail")
            let output = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyLocked")
            for index in 0 ..< count {
                try StagedRecordingFixture(dir: staging, stem: "20260311_15000\(index)").stoppedRecording(seconds: 1)
            }
            let before = names(in: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: output.path)
            addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path) }
            let notifier = RecordingNotifier()
            let queue = try makeQueue(staging: staging)

            await runPass(on: staging, into: queue, recordOnly: .writing(into: output, notifier: notifier))

            XCTAssertEqual(names(in: staging), before, "\(count): a file left staging")
            XCTAssertEqual(names(in: output), [], "\(count)")
            XCTAssertEqual(queue.jobs.count, 0, "\(count): processed instead")
            XCTAssertEqual(notifier.calls.map(\.title), ["Record-only output failed"], "\(count)")
            XCTAssertEqual(notifier.calls.map(\.body), [body])
            XCTAssertEqual(notifier.calls.map(\.urgency), [.standard], "\(count)")

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
            await runPass(on: staging, into: queue, recordOnly: .writing(into: output, notifier: notifier))

            let sidecars = names(in: output.appendingPathComponent("recordings")).filter { $0.hasSuffix(RecordingSidecar.filenameSuffix) }
            XCTAssertEqual(sidecars.count, count, "the later pass did not file them")
            XCTAssertEqual(notifier.calls.count, 1, "\(count): a notice for writes that succeeded")
        }
    }

    /// A committed write whose staging files cannot be removed is reported
    /// as on a live stop: the recording is filed and the user is told its
    /// files stayed.
    func testAFiledRecordingWhoseStagingFilesStayTellsTheUser() async throws {
        let staging = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyKept")
        let output = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyOutput")
        try StagedRecordingFixture(dir: staging, stem: stem).stoppedRecording(seconds: 1)
        // Read-only, so the committed write cannot remove its sources.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staging.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path) }
        let notifier = RecordingNotifier()

        try await runPass(on: staging, into: makeQueue(staging: staging), recordOnly: .writing(into: output, notifier: notifier))

        XCTAssertNotNil(RecordingSidecar.read(fromDirectory: output.appendingPathComponent("recordings"), basename: stem), "not filed")
        XCTAssertEqual(notifier.calls.map(\.title), ["Record-only: files left in staging"])
    }

    // MARK: - A quit

    /// Holds a quit's record-only transfer until the test lets it go.
    private final class HeldTransfer: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let release = DispatchSemaphore(value: 0)

        var hasEntered: Bool {
            lock.withLock { entered }
        }

        func transfer(_ source: URL, _ target: URL) throws {
            lock.withLock { entered = true }
            release.wait()
            release.signal()
            try RecordOnlyWrite.linkOrCopy(source, target)
        }

        func letGo() {
            release.signal()
        }
    }

    /// A quit writes the recording it stopped off the main actor, and a pass
    /// that runs meanwhile finds that recording's mix still in staging. The
    /// pass writes nothing once the quit has begun, so the recording is filed
    /// once, by the quit, under the meeting's title.
    func testAPassDuringAQuitLeavesTheQuitsRecordingToTheQuit() async throws {
        let tmp = try makeTempDirectory(prefix: "StagedRecoveryRecordOnlyQuit")
        let notifier = RecordingNotifier()
        let watching = makeWatchingController(logDir: tmp, notifier: notifier, permissionHealth: .allHealthy)
        watching.settings.recordOnly = true
        let staging = watching.pipeline.queueEnvironment.stagingDir
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let mix = staging.appendingPathComponent(stem + RecordingFileSuffix.mix)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000, url: mix)
        let recorder = MockRecorder()
        recorder.mixPath = mix
        let held = HeldTransfer()
        defer { held.letGo() }
        // The folder the controller's recovery writes into.
        let output = tmp.appendingPathComponent("output", isDirectory: true)
        let loop = WatchLoop(
            detector: FixedMeetingDetector(),
            recorderFactory: { recorder },
            recordOnly: { true },
            recordOnlyDestination: { .production(parent: output) },
            recordOnlyFileTransfer: { try held.transfer($0, $1) },
            notifier: notifier,
        )
        loop.permissionChecker = { .allHealthy }
        try await loop.startManualRecording(pid: getpid(), appName: "Teams", title: "Standup")
        watching.watchLoop = loop

        let quit = Task { await watching.finishForQuit() }
        await waitFor(held.hasEntered, timeout: .seconds(3))
        XCTAssertTrue(held.hasEntered, "test premise: the quit's write is held in its transfer")
        await PipelineController.recoverOrphans(
            into: watching.pipeline.queue, holdingBack: [], recordingsDir: staging, recordOnly: watching.pipeline.recordOnlyRecovery,
        )
        held.letGo()
        await quit.value

        let recordings = output.appendingPathComponent("recordings")
        let sidecars = names(in: recordings).filter { $0.hasSuffix(RecordingSidecar.filenameSuffix) }
        XCTAssertEqual(sidecars, [stem + RecordingSidecar.filenameSuffix], "not filed exactly once")
        XCTAssertEqual(RecordingSidecar.read(fromDirectory: recordings, basename: stem)?.title, "Standup")
        XCTAssertFalse(notifier.calls.map(\.title).contains("Record-only output failed"), "\(notifier.calls.map(\.title))")
    }
}
