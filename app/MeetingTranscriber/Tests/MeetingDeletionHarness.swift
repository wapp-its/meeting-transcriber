@testable import MeetingTranscriber
import XCTest

/// A `PipelineController` over a temp folder for the window's deletion actions,
/// with a fake Trash and a fixed clock, and meetings to act on: their files on
/// disk, their record and their finished-job entry, as a finished run leaves them.
@MainActor
final class MeetingDeletionHarness {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Records where the output folder's scope was opened and closed.
    final class ScopeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var openedURLs: [URL] = []
        private var closedURLs: [URL] = []

        var opened: [URL] {
            lock.withLock { openedURLs }
        }

        var closed: [URL] {
            lock.withLock { closedURLs }
        }

        var access: SecurityScopeAccess {
            SecurityScopeAccess(
                start: { [self] url in
                    lock.withLock { openedURLs.append(url) }
                    return true
                },
                stop: { [self] url in lock.withLock { closedURLs.append(url) } },
            )
        }
    }

    let root: URL
    let settings: AppSettings
    let store: MeetingFileStore
    let history: TerminalJobStore
    let fakeTrash: FakeTrash
    let scopes = ScopeLog()
    /// What the injected permanent delete was asked to remove; a manual action
    /// must never get here.
    private(set) var deletedForGood: [String] = []

    var logDir: URL {
        root.appendingPathComponent("logs", isDirectory: true)
    }

    var outputDir: URL {
        root.appendingPathComponent("output", isDirectory: true)
    }

    var recordings: URL {
        outputDir.appendingPathComponent("recordings", isDirectory: true)
    }

    var stagingDir: URL {
        root.appendingPathComponent("staging", isDirectory: true)
    }

    var recordPath: URL {
        logDir.appendingPathComponent("meeting_files.json")
    }

    init(root: URL, settings: AppSettings) throws {
        self.root = root
        self.settings = settings
        store = MeetingFileStore(path: root.appendingPathComponent("logs/meeting_files.json"))
        history = TerminalJobStore(path: root.appendingPathComponent("logs/terminal_jobs.json"))
        fakeTrash = try FakeTrash(folder: root.appendingPathComponent("fake-trash", isDirectory: true))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("output/recordings", isDirectory: true), withIntermediateDirectories: true,
        )
    }

    // MARK: - Controller and queue

    /// A controller wired to `queue`, or, without one, in the state a launch
    /// leaves it in: a bare queue that has not read the snapshot.
    func controller(queue: PipelineQueue? = nil) -> PipelineController {
        var environment = IsolatedQueueEnvironment.make(logDir: logDir, initialQueue: queue)
        environment.securityScope = scopes.access
        return PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: environment,
            terminalJobStore: history,
            meetingFileStore: store,
            fileRemover: MeetingFileRemover(
                trash: { [fakeTrash] in try fakeTrash.take($0) },
                removeForGood: { [weak self] url in
                    self?.deletedForGood.append(url.lastPathComponent)
                    try FileManager.default.removeItem(at: url)
                },
            ),
        ) { Self.now }
    }

    /// A queue on this harness's stores. A job it runs goes straight to `.done`,
    /// or parks for its speaker names.
    func makeQueue(parksForNaming: Bool = false, notion: NotionExportConfiguration? = nil) -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        let diarization = MockDiarization()
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: parksForNaming ? ["SPEAKER_0": [1, 0, 0]] : nil,
        )
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: outputDir,
            logDir: logDir,
            stagingDir: stagingDir,
            diarizeEnabled: true,
            echoDedupEnabled: false,
            notionExportConfigurationProvider: notion.map { configuration in { .ready(configuration) } },
            terminalJobStore: history,
            meetingFileStore: store,
        )
    }

    /// The three tracks a recorder leaves in staging, as the job handed over.
    func stagedRecording() throws -> PipelineJob {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stem = UUID().uuidString.prefix(8)
        let tracks = try ["mix", "app", "mic"].map { name in
            let track = stagingDir.appendingPathComponent("\(stem)_\(name).wav")
            try FileManager.default.moveItem(at: createTestAudioFile(in: stagingDir), to: track)
            return track
        }
        return PipelineJob(
            meetingTitle: "Budget review", appName: "Microsoft Teams",
            mixPath: tracks[0], appPath: tracks[1], micPath: tracks[2], micDelay: 0,
            meetingStartTime: Self.now.addingTimeInterval(-3600),
        )
    }

    // MARK: - Meetings

    private func write(_ name: String) throws -> URL {
        let url = recordings.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    /// A finished recorded meeting: three tracks, a transcript and a protocol.
    func recordedMeeting() throws -> PipelineJob {
        let stem = UUID().uuidString.prefix(8)
        return try storeFinished(PipelineJob(
            meetingTitle: "Budget review", appName: "Teams",
            mixPath: write("\(stem)_mix.wav"), appPath: write("\(stem)_app.wav"), micPath: write("\(stem)_mic.wav"),
            micDelay: 0, meetingStartTime: Self.now.addingTimeInterval(-3600),
        ), origin: .recorded, stem: String(stem))
    }

    /// A finished import of `source`, by default a new file inside the recordings
    /// folder: where a file sits never makes it the app's.
    func importedMeeting(source: URL? = nil) throws -> PipelineJob {
        let stem = UUID().uuidString.prefix(8)
        return try storeFinished(PipelineJob(
            meetingTitle: "Imported talk", appName: "File",
            mixPath: source ?? write("\(stem)_source.wav"), appPath: nil, micPath: nil, micDelay: 0,
        ), origin: .imported, stem: String(stem))
    }

    private func storeFinished(_ input: PipelineJob, origin: MeetingFileRecord.Origin, stem: String) throws -> PipelineJob {
        var job = input
        job.state = .done
        job.transcriptPath = try write("\(stem).txt")
        job.protocolPath = try write("\(stem).md")
        var record = MeetingFileRecord(job: job, origin: origin)
        record.outcome = .finished(protocolExpected: true)
        for (role, url) in [(MeetingFile.Role.transcript, job.transcriptPath), (.protocol, job.protocolPath)] {
            try record.list(MeetingFile(role: role, url: XCTUnwrap(url), owned: origin.owns(role)))
        }
        XCTAssertTrue(store.create(record), "test premise")
        history.record(TerminalJobRecord(job: job))
        return job
    }

    func record(of job: PipelineJob) throws -> MeetingFileRecord {
        try XCTUnwrap(store.record(for: job.id))
    }

    func paths(of job: PipelineJob, _ include: (MeetingFile) -> Bool = { _ in true }) throws -> [String] {
        try record(of: job).files.filter(include).map(\.path)
    }

    func isOnDisk(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The names of `job`'s files in `role`s, as the fake Trash reports them.
    func names(_ paths: [String]) -> [String] {
        paths.map { URL(filePath: $0).lastPathComponent }
    }
}
