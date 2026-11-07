@testable import MeetingTranscriber
import XCTest

/// How a meeting's file record starts for what does not come from the recorder's
/// hand-over: an imported file, whose source stays the user's, and a recording a
/// crash left in staging. `PipelineQueueMeetingFilesTests` covers a recorded run.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueMeetingFilesEntryTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var store: MeetingFileStore!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "meeting_files_entry_test")
        store = MeetingFileStore(path: logDir.appendingPathComponent("meeting_files.json"))
    }

    private var logDir: URL {
        tmpDir.appendingPathComponent("logs")
    }

    private var outputDir: URL {
        tmpDir.appendingPathComponent("output")
    }

    private var stagingDir: URL {
        tmpDir.appendingPathComponent("staging")
    }

    private func makeQueue() -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: nil,
        )
        let protocolGen = MockProtocolGen()
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { protocolGen },
            outputDir: outputDir,
            logDir: logDir,
            stagingDir: stagingDir,
            diarizeEnabled: true,
            echoDedupEnabled: false,
            meetingFileStore: store,
        )
    }

    /// The three tracks a recorder leaves in `folder`.
    @discardableResult
    private func stageRecording(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tracks = try ["rec_mix.wav", "rec_app.wav", "rec_mic.wav"].map { name in
            let track = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: createTestAudioFile(in: folder), to: track)
            return track
        }
        return tracks[0]
    }

    // MARK: - Imports

    /// Ownership comes from how the meeting started, never from where the file
    /// sits: a file the user put inside the recordings folder stays theirs.
    func testAnImportThroughTheControllerOwnsNoSourceWhereverTheFileSits() throws {
        let suite = "PipelineQueueMeetingFilesEntryTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: outputDir,
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let controller = PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: logDir),
        )
        controller.activate { MockEngine() }
        for folder in [tmpDir.appendingPathComponent("imports"), outputDir.appendingPathComponent("recordings")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = try createTestAudioFile(in: folder)

            let id = try XCTUnwrap(controller.enqueueFiles([source]).first)

            let record = try XCTUnwrap(controller.meetingFileStore.record(for: id))
            XCTAssertEqual(record.origin, .imported, folder.lastPathComponent)
            XCTAssertNil(record.recordingDate, folder.lastPathComponent)
            XCTAssertEqual(record.files.map(\.role), [.mix], folder.lastPathComponent)
            XCTAssertEqual(record.files.first?.owned, false, folder.lastPathComponent)
            // Never runs: this controller's provider is the real default one.
            controller.queue.cancelJob(id: id)
        }
    }

    /// Stage 3 reports where it left the audio, and that report must not turn
    /// the file the user put in the recordings folder into one the app owns.
    func testAnImportInsideTheRecordingsFolderStaysNotOwnedThroughARun() async throws {
        let recordings = outputDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let source = try createTestAudioFile(in: recordings)
        let queue = makeQueue()
        let job = PipelineJob(
            meetingTitle: "Voice Memo", appName: "File", mixPath: source, appPath: nil, micPath: nil, micDelay: 0,
        )

        queue.enqueue(job)
        await queue.awaitProcessing()

        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(record.outcome, .finished(protocolExpected: true), "test premise")
        let mix = try XCTUnwrap(record.files.first { $0.role == .mix })
        XCTAssertFalse(mix.owned)
        XCTAssertEqual(mix.path, MeetingFile.resolvedPath(source))
        XCTAssertEqual(record.files.filter { !$0.owned }.count, 1, "only the source is the user's")
    }

    /// The mix of a pair without one is made in the run's work folder, which goes
    /// with the run: only files that exist at their recorded path are listed.
    func testAPairedImportWithoutAMixListsOnlyFilesThatExist() async throws {
        let queue = makeQueue()
        let job = try PipelineJob(
            meetingTitle: "Pair", appName: "File",
            mixPath: nil, appPath: createTestAudioFile(in: tmpDir), micPath: createTestAudioFile(in: tmpDir), micDelay: 0,
        )

        queue.enqueue(job)
        await queue.awaitProcessing()

        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(record.outcome, .finished(protocolExpected: true), "test premise")
        XCTAssertFalse(record.files.contains { $0.role == .mix })
        XCTAssertEqual(record.files.filter { !$0.owned }.map(\.role), [.appTrack, .micTrack])
        for listed in record.files {
            XCTAssertNotNil(FileIdentity.of(listed.path), "\(listed.role) is not on disk")
        }
    }

    // MARK: - The build that created it

    /// Each way a record starts names the running build, the only one whose setting
    /// deletes the meeting's audio automatically.
    func testEveryRecordNamesTheBuildThatCreatedIt() async throws {
        let build = "com.example.meetingtranscriber.dev"
        store = MeetingFileStore(path: logDir.appendingPathComponent("meeting_files.json"), bundleID: build)
        let queue = makeQueue()
        let recorded = try PipelineJob(
            meetingTitle: "Recorded", appName: "Teams", mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
        )
        let imported = try PipelineJob(
            meetingTitle: "Imported", appName: "File", mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
        )

        queue.enqueue(recorded, origin: .recorded)
        queue.enqueue(imported)
        try stageRecording(in: stagingDir)
        await queue.recoverOrphanedRecordings(recordingsDir: stagingDir)

        XCTAssertEqual(queue.jobs.count, 3, "test premise: recorded, imported and recovered")
        for job in queue.jobs {
            XCTAssertEqual(store.record(for: job.id)?.createdBy, build, job.meetingTitle)
        }
        await queue.awaitProcessing()
    }

    // MARK: - Recovered recordings

    /// Later than the true start, so its audio is kept longer, never shorter.
    func testARecoveredOrphanIsRecordedAndCountsFromWhenItEnteredProcessing() async throws {
        let queue = makeQueue()
        try stageRecording(in: stagingDir)

        await queue.recoverOrphanedRecordings(recordingsDir: stagingDir)

        let job = try XCTUnwrap(queue.jobs.first)
        let record = try XCTUnwrap(store.record(for: job.id))
        XCTAssertEqual(record.origin, .recorded)
        XCTAssertEqual(record.recordingDate, job.enqueuedAt)
        XCTAssertEqual(record.files.map(\.role), [.mix, .appTrack, .micTrack])
        XCTAssertTrue(record.files.allSatisfy(\.owned))
        await queue.awaitProcessing()
    }

    /// An upgrade after a crash admits a recording made before this feature
    /// existed, and those are never deleted automatically (D9).
    func testOnlyAnOrphanCreatedBeforeTheStoreIsExcludedFromAutomaticDeletion() async throws {
        let rows: [(name: String, offset: TimeInterval, excluded: Bool)] = [
            ("before", -3600, true),
            ("after", 60, false),
        ]
        for row in rows {
            let staging = tmpDir.appendingPathComponent("staging_\(row.name)")
            let queue = makeQueue()
            let mix = try stageRecording(in: staging)
            try FileManager.default.setAttributes(
                [.creationDate: store.since.addingTimeInterval(row.offset)], ofItemAtPath: mix.path,
            )

            await queue.recoverOrphanedRecordings(recordingsDir: staging)

            let job = try XCTUnwrap(queue.jobs.first, row.name)
            XCTAssertEqual(store.record(for: job.id)?.excludedFromAutomaticDeletion, row.excluded, row.name)
            await queue.awaitProcessing()
        }
    }
}
