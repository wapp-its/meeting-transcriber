@testable import MeetingTranscriber
import XCTest

/// A recorded meeting's file record, followed through the real queue from the
/// hand-over to its finish. Every later delete action reads this record and no
/// other source, so what it lists has to match the disk.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueMeetingFilesTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    private let meetingStart = Date(timeIntervalSinceReferenceDate: 780_000_000)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_meeting_files_test")
    }

    private var storePath: URL {
        tmpDir.appendingPathComponent("logs/meeting_files.json")
    }

    private var outputDir: URL {
        tmpDir.appendingPathComponent("output")
    }

    private var stagingDir: URL {
        tmpDir.appendingPathComponent("staging")
    }

    private func makeEngine() -> MockEngine {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        return engine
    }

    /// A queue that diarizes, so every 16 kHz copy is produced, and unless told
    /// otherwise needs no naming: the job runs straight to `.done`.
    private func makeQueue(
        store: MeetingFileStore,
        engine: MockEngine? = nil,
        protocolGen: MockProtocolGen? = MockProtocolGen(),
        protocolGeneratorFactory: (() -> (any ProtocolGenerating)?)? = nil,
        outputDir: URL? = nil,
        stagingDir: URL? = nil,
        parksForNaming: Bool = false,
    ) -> PipelineQueue {
        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: parksForNaming ? ["SPEAKER_0": [1, 0, 0]] : nil,
        )
        return PipelineQueue(
            engine: engine ?? makeEngine(),
            diarizationFactory: { diarization },
            protocolGeneratorFactory: protocolGeneratorFactory ?? { protocolGen },
            outputDir: outputDir ?? self.outputDir,
            logDir: tmpDir.appendingPathComponent("logs"),
            stagingDir: stagingDir ?? self.stagingDir,
            diarizeEnabled: true,
            echoDedupEnabled: false,
            meetingFileStore: store,
        )
    }

    /// The three tracks a recorder leaves in `stagingDir`.
    private func makeRecording(in stagingDir: URL? = nil, start: Date? = nil, aiTitle: Bool = false) throws -> PipelineJob {
        let staging = stagingDir ?? self.stagingDir
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let tracks = try ["rec_mix.wav", "rec_app.wav", "rec_mic.wav"].map { name in
            let track = staging.appendingPathComponent(name)
            try FileManager.default.moveItem(at: createTestAudioFile(in: staging), to: track)
            return track
        }
        return PipelineJob(
            meetingTitle: "Google Chrome", appName: "Microsoft Teams",
            mixPath: tracks[0], appPath: tracks[1], micPath: tracks[2], micDelay: 0,
            meetingStartTime: start,
            useAITitleForFilenames: aiTitle ? true : nil,
        )
    }

    private func run(_ job: PipelineJob, in queue: PipelineQueue) async {
        queue.enqueue(job, origin: .recorded)
        await queue.awaitProcessing()
    }

    private func path(of role: MeetingFile.Role, in record: MeetingFileRecord) -> String? {
        record.files.first { $0.role == role }?.path
    }

    private func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Owned, present, and naming the very file on disk at its path.
    private func assertMatchesTheDisk(
        _ record: MeetingFileRecord, file: StaticString = #filePath, line: UInt = #line,
    ) {
        for listed in record.files {
            XCTAssertTrue(listed.owned, "\(listed.role) is not owned", file: file, line: line)
            XCTAssertEqual(listed.state, .present, "\(listed.role)", file: file, line: line)
            XCTAssertNotNil(listed.identity, "\(listed.role) has no identity", file: file, line: line)
            XCTAssertEqual(listed.identity, FileIdentity.of(listed.path), "\(listed.role)", file: file, line: line)
        }
    }

    // MARK: - A whole recorded run

    func testARecordedRunLeavesOneRecordOfItsFiles() async throws {
        let store = MeetingFileStore(path: storePath)
        let queue = makeQueue(store: store)
        let job = try makeRecording(start: meetingStart)

        await run(job, in: queue)

        XCTAssertEqual(store.records.count, 1)
        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(record.origin, .recorded)
        XCTAssertEqual(record.recordingDate, meetingStart)
        XCTAssertEqual(record.outcome, .finished(protocolExpected: true))
        XCTAssertEqual(
            Set(record.files.map(\.role)),
            [.mix, .appTrack, .micTrack, .mix16k, .app16k, .mic16k, .segments, .transcript, .protocol],
        )
        assertMatchesTheDisk(record)

        let finished = try XCTUnwrap(queue.jobs.first)
        let recordings = outputDir.appendingPathComponent("recordings").resolvingSymlinksInPath().path
        for (role, url) in [
            (MeetingFile.Role.mix, finished.mixPath), (.appTrack, finished.appPath), (.micTrack, finished.micPath),
            (.transcript, finished.transcriptPath), (.protocol, finished.protocolPath),
        ] {
            XCTAssertEqual(path(of: role, in: record), try MeetingFile.resolvedPath(XCTUnwrap(url)), "\(role)")
        }
        for role in [MeetingFile.Role.mix, .appTrack, .micTrack, .mix16k, .app16k, .mic16k, .segments] {
            XCTAssertEqual(
                try URL(fileURLWithPath: XCTUnwrap(path(of: role, in: record))).deletingLastPathComponent().path, recordings, "\(role)",
            )
        }

        await queue.awaitSnapshotFlush()
        XCTAssertEqual(MeetingFileStore(path: storePath).record(for: job.id), record, "a restart reads the same record")
    }

    /// Stage 3 reports the source when a move failed, and a copy that could not
    /// be moved is not there to list: the record says what happened, never what
    /// was intended.
    func testAMoveThatFailedKeepsTheSourcePathAndListsNoCopy() async throws {
        let store = MeetingFileStore(path: storePath)
        let queue = makeQueue(store: store)
        let job = try makeRecording(start: meetingStart)
        let recordings = outputDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path) }

        await run(job, in: queue)

        let record = try XCTUnwrap(store.record(for: job.id))
        try XCTAssertEqual(path(of: .mix, in: record), MeetingFile.resolvedPath(XCTUnwrap(job.mixPath)))
        XCTAssertEqual(
            Set(record.files.map(\.role)), [.mix, .appTrack, .micTrack, .transcript, .protocol],
            "no copy and no segments file reached the recordings folder",
        )
        assertMatchesTheDisk(record)
    }

    // MARK: - Outcome

    func testWithNoGeneratorTheMeetingFinishesWithoutExpectingAProtocol() async throws {
        let store = MeetingFileStore(path: storePath)
        let job = try makeRecording()

        await run(job, in: makeQueue(store: store, protocolGen: nil))

        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(record.outcome, .finished(protocolExpected: false))
        XCTAssertNil(path(of: .protocol, in: record))
        XCTAssertNotNil(path(of: .transcript, in: record))
    }

    /// A skipped naming with no generator goes straight to `.done`, without the
    /// protocol stage.
    func testASkippedNamingWithNoGeneratorFinishesWithoutExpectingAProtocol() async throws {
        try await assertNamingFinishesWithoutExpectingAProtocol(answer: .skipped)
    }

    /// A confirm hops through `.generatingProtocol` before the stage finds no
    /// generator, so having been in that state does not mean generation was on.
    func testAConfirmedNamingWithNoGeneratorFinishesWithoutExpectingAProtocol() async throws {
        try await assertNamingFinishesWithoutExpectingAProtocol(answer: .confirmed(["SPEAKER_0": "Alice"]))
    }

    private func assertNamingFinishesWithoutExpectingAProtocol(answer: PipelineQueue.SpeakerNamingResult) async throws {
        let store = MeetingFileStore(path: storePath)
        let queue = makeQueue(store: store, protocolGen: nil, parksForNaming: true)
        queue.speakerNamingHandler = { _ in answer }
        let done = expectation(description: "job reaches done")
        var parked = false
        queue.onJobStateChange = { _, _, newState in
            if newState == .speakerNamingPending { parked = true }
            if newState == .done { done.fulfill() }
        }
        let job = try makeRecording()

        await run(job, in: queue)
        await fulfillment(of: [done], timeout: 10)

        XCTAssertTrue(parked, "test premise: the job waited for naming")
        XCTAssertEqual(store.record(for: job.id)?.outcome, .finished(protocolExpected: false))
    }

    /// The job ends `.done` although there are no notes: `protocolExpected` is
    /// what keeps that meeting's audio from being deleted automatically.
    func testAGeneratorThatFailsFinishesExpectingAProtocolAndListsNone() async throws {
        let store = MeetingFileStore(path: storePath)
        let generator = MockProtocolGen()
        generator.shouldThrow = true
        let queue = makeQueue(store: store, protocolGen: generator)
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertEqual(queue.jobs.first?.state, .done, "test premise: a failed protocol still finishes the job")
        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(record.outcome, .finished(protocolExpected: true))
        XCTAssertNil(path(of: .protocol, in: record))
    }

    /// The setting can change while the call runs. An attempt that failed left
    /// no notes however the setting reads by the time the job finishes, so the
    /// meeting must not pass for one that had generation off, whose audio may go.
    func testAGeneratorSwitchedOffDuringAFailedCallStillExpectsAProtocol() async throws {
        let store = MeetingFileStore(path: storePath)
        let generator = MockProtocolGen()
        generator.shouldThrow = true
        var generationOn = true
        generator.onGenerate = { generationOn = false }
        let settings: () -> (any ProtocolGenerating)? = { generationOn ? generator : nil }
        let queue = makeQueue(store: store, protocolGeneratorFactory: settings)
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertTrue(generator.generateCalled, "test premise: generation was attempted")
        XCTAssertFalse(generationOn, "test premise: the setting changed during the call")
        XCTAssertEqual(store.record(for: job.id)?.outcome, .finished(protocolExpected: true))
    }

    func testAFailedRunEndsWithOutcomeFailed() async throws {
        let store = MeetingFileStore(path: storePath)
        let engine = makeEngine()
        engine.shouldThrow = true
        let queue = makeQueue(store: store, engine: engine)
        let job = try makeRecording(start: meetingStart)

        await run(job, in: queue)

        XCTAssertEqual(queue.jobs.first?.state, .error, "test premise")
        XCTAssertEqual(store.record(for: job.id)?.outcome, .failed)
    }

    /// Later than the true start, so its audio is kept longer, never shorter.
    func testARunWithoutARecordingStartTakesTheTimeItEnteredProcessing() async throws {
        let store = MeetingFileStore(path: storePath)
        let job = try makeRecording(start: nil)

        await run(job, in: makeQueue(store: store))

        XCTAssertEqual(store.record(for: job.id)?.recordingDate, job.enqueuedAt)
    }

    /// The record is an extra, and the meeting's result never depends on it.
    func testAFailedRecordWriteDoesNotFailTheJob() async throws {
        let folder = storePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = MeetingFileStore(path: folder.appendingPathComponent("unwritable/meeting_files.json"))
        let unwritable = folder.appendingPathComponent("unwritable")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unwritable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritable.path) }
        let queue = makeQueue(store: store)
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertNotNil(queue.jobs.first?.protocolPath)
        XCTAssertNil(store.record(for: job.id))
    }

    // MARK: - Title rename

    func testARunWithTheAITitleOptionListsTheNewNames() async throws {
        let store = MeetingFileStore(path: storePath)
        let generator = MockProtocolGen()
        generator.headingTitle = "Sprint Planning"
        let job = try makeRecording(start: meetingStart, aiTitle: true)

        await run(job, in: makeQueue(store: store, protocolGen: generator))

        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(
            Set(record.files.map { fileName($0.path) }),
            [
                "sprint_planning.md", "sprint_planning.txt", "sprint_planning_mix.wav", "sprint_planning_app.wav",
                "sprint_planning_mic.wav", "sprint_planning_16k.wav", "sprint_planning_app_16k.wav",
                "sprint_planning_mic_16k.wav", "sprint_planning_segments.json",
            ],
        )
        assertMatchesTheDisk(record)
    }

    /// The old path is gone by the time the rename reports it, and under a
    /// `/private` folder a resolved path reads differently once its file has
    /// moved away. Matching on that spelling would leave the old names listed.
    func testARenameFollowsFilesInAFolderSpelledFromItsRealPath() async throws {
        let realTmp = String(cString: realpath(tmpDir.path, nil))
        let realDir = URL(fileURLWithPath: realTmp, isDirectory: true)
        let store = MeetingFileStore(path: storePath)
        let generator = MockProtocolGen()
        generator.headingTitle = "Sprint Planning"
        let staging = realDir.appendingPathComponent("staging")
        let queue = makeQueue(
            store: store, protocolGen: generator,
            outputDir: realDir.appendingPathComponent("output"), stagingDir: staging,
        )
        let job = try makeRecording(in: staging, aiTitle: true)

        await run(job, in: queue)

        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertFalse(record.files.isEmpty)
        for listed in record.files {
            XCTAssertTrue(
                fileName(listed.path).hasPrefix("sprint_planning"), listed.path,
            )
        }
        assertMatchesTheDisk(record)
    }

    func testARenameThatWasUndoneLeavesTheOldNames() async throws {
        let store = MeetingFileStore(path: storePath)
        let generator = MockProtocolGen()
        generator.headingTitle = "Sprint Planning"
        let recordings = outputDir.appendingPathComponent("recordings")
        // The transcript moves first and succeeds; moving the audio then fails
        // because the recordings folder cannot be written to.
        generator.onGenerate = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordings.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path) }
        let queue = makeQueue(store: store, protocolGen: generator)
        let job = try makeRecording(start: meetingStart, aiTitle: true)

        await run(job, in: queue)

        let finished = try XCTUnwrap(queue.jobs.first)
        XCTAssertTrue(finished.warnings.contains { $0.contains("the original names were kept") }, "\(finished.warnings)")
        let slug = try XCTUnwrap(finished.namingSlug)
        let record = try XCTUnwrap(store.record(for: job.id))
        try XCTAssertEqual(path(of: .transcript, in: record), MeetingFile.resolvedPath(XCTUnwrap(finished.transcriptPath)))
        try XCTAssertEqual(path(of: .mix, in: record), MeetingFile.resolvedPath(XCTUnwrap(finished.mixPath)))
        for listed in record.files {
            XCTAssertTrue(fileName(listed.path).hasPrefix(slug), listed.path)
        }
        assertMatchesTheDisk(record)
    }

    /// Folder permissions can fail a forward move but not the undo after it, so
    /// this drives the rename's move step directly: the job keeps its old paths,
    /// and the file that could not move back is where the record says it is.
    func testAfterAFailedUndoTheFileThatStayedIsListedUnderItsNewName() async throws {
        let store = MeetingFileStore(path: storePath)
        let queue = makeQueue(store: store)
        let job = try makeRecording(start: meetingStart)
        await run(job, in: queue)
        let finished = try XCTUnwrap(queue.jobs.first)
        let slug = try XCTUnwrap(finished.namingSlug)
        let before = try XCTUnwrap(store.record(for: job.id))
        let protocolsDir = outputDir.appendingPathComponent("protocols")

        // The moves run transcript-side first, so these two are done when the
        // microphone track refuses; the undo then fails for the transcript only.
        let renamed = queue.renameJobArtifacts(
            jobID: job.id, from: slug, titleSlug: "sprint_planning", protocolsDir: protocolsDir,
        ) { source, destination in
            let name = destination.lastPathComponent
            if name == "sprint_planning_mic.wav" || name == "\(slug).txt" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        XCTAssertEqual(renamed, slug, "the job keeps its old stem")
        let warnings = try XCTUnwrap(queue.jobs.first).warnings
        XCTAssertTrue(warnings.contains { $0.contains("some could not be moved back") }, "\(warnings)")
        let staying = protocolsDir.appendingPathComponent("sprint_planning.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staying.path), "test premise: the transcript stayed")

        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(path(of: .transcript, in: record), MeetingFile.resolvedPath(staying))
        XCTAssertEqual(
            record.files.first { $0.role == .transcript }?.identity,
            before.files.first { $0.role == .transcript }?.identity,
            "a move keeps the file",
        )
        for listed in record.files where listed.role != .transcript {
            XCTAssertEqual(path(of: listed.role, in: before), listed.path, "\(listed.role) moved back")
        }
        assertMatchesTheDisk(record)
    }

    // MARK: - Entering processing

    /// The safe side: a caller that forgets the origin makes a meeting the app
    /// never deletes.
    func testAnEnqueueThatNamesNoOriginIsAnImport() throws {
        let store = MeetingFileStore(path: storePath)
        let queue = PipelineQueue(
            logDir: tmpDir.appendingPathComponent("logs"), stagingDir: stagingDir, meetingFileStore: store,
        )
        let source = try createTestAudioFile(in: tmpDir)
        let job = PipelineJob(
            meetingTitle: "Voice Memo", appName: "File",
            mixPath: source, appPath: nil, micPath: nil, micDelay: 0,
            meetingStartTime: meetingStart,
        )

        queue.enqueue(job)

        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(record.origin, .imported)
        XCTAssertNil(record.recordingDate)
        XCTAssertEqual(record.files.map(\.role), [.mix])
        XCTAssertEqual(record.files.first?.owned, false)
    }

    /// Every way a recording stops reaches this one method.
    func testAWatchLoopRecordingEntersAsRecorded() throws {
        let store = MeetingFileStore(path: storePath)
        let queue = PipelineQueue(
            logDir: tmpDir.appendingPathComponent("logs"), stagingDir: stagingDir, meetingFileStore: store,
        )
        let (loop, _) = makeTestWatchLoop(pipelineQueue: queue)
        let job = try makeRecording()

        try loop.enqueueRecording(
            title: "Standup", appName: "Microsoft Teams",
            recording: RecordingResult(
                mixPath: XCTUnwrap(job.mixPath), appPath: job.appPath, micPath: job.micPath,
                micDelay: 0, recordingStartDate: meetingStart,
            ),
            trigger: .manual, pauses: [],
        )

        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.origin, .recorded)
        XCTAssertEqual(record.recordingDate, meetingStart)
        XCTAssertEqual(record.files.map(\.role), [.mix, .appTrack, .micTrack])
        XCTAssertTrue(record.files.allSatisfy(\.owned))
    }

    /// The store outlives queue rebuilds, like the finished-job history beside it.
    func testAControllerKeepsItsStoreBesideTheHistoryAndHandsItToItsQueues() throws {
        let logs = tmpDir.appendingPathComponent("logs")
        let suite = "PipelineQueueMeetingFilesTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: outputDir,
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let controller = PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: logs),
        )
        controller.activate { MockEngine() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.appendingPathComponent("meeting_files.json").path))
        XCTAssertIdentical(controller.makeQueue()?.meetingFileStore, controller.meetingFileStore)
    }
}
