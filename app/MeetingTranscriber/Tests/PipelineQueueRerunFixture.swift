import AudioTapLib
import Foundation
@testable import MeetingTranscriber
import XCTest

/// Shared set-up for the re-run tests: a finished meeting made by a real run of
/// the queue, with its record and its finished entry, in a temp folder, and the
/// stubs its re-run reads. A fixture object rather than a base class, since test
/// cases keep their members private.
@MainActor
final class PipelineQueueRerunFixture {
    struct Timeout: Error {
        let waitingFor: String
    }

    let tmpDir: URL
    let store: MeetingFileStore
    let terminal: TerminalJobStore
    let engine = MockEngine()
    let diarization = MockDiarization()
    let protocolGen = MockProtocolGen()
    let meetingStart = Date(timeIntervalSinceReferenceDate: 780_000_000)
    /// Holds the template "Board", so a job can name one that is not the default.
    let templates: ProtocolTemplateStore

    init(tmpDir: URL) throws {
        self.tmpDir = tmpDir
        store = MeetingFileStore(path: Self.storePath(in: tmpDir))
        terminal = TerminalJobStore(path: tmpDir.appendingPathComponent("records/terminal_jobs.json"))
        templates = ProtocolTemplateStore(directory: tmpDir.appendingPathComponent("templates"))
        try FileManager.default.createDirectory(at: templates.directory, withIntermediateDirectories: true)
        try "Board notes".write(to: templates.fileURL(named: "Board"), atomically: true, encoding: .utf8)
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        parkForNaming(false)
    }

    /// Where the record store writes, which a second store reads as the other build.
    var storePath: URL {
        Self.storePath(in: tmpDir)
    }

    private static func storePath(in tmpDir: URL) -> URL {
        tmpDir.appendingPathComponent("records/meeting_files.json")
    }

    var outputDir: URL {
        tmpDir.appendingPathComponent("output")
    }

    var protocolsDir: URL {
        outputDir.appendingPathComponent("protocols")
    }

    var recordingsDir: URL {
        outputDir.appendingPathComponent("recordings")
    }

    var stagingDir: URL {
        tmpDir.appendingPathComponent("staging")
    }

    var speakersDB: URL {
        tmpDir.appendingPathComponent("speakers.json")
    }

    /// The file the record store writes, as bytes, so a test can say nothing changed.
    var recordFileBytes: Data? {
        try? Data(contentsOf: storePath)
    }

    /// Whether the next diarization leaves a speaker to name (an unknown voice
    /// with an embedding) or runs the job straight to `.done`.
    func parkForNaming(_ parks: Bool) {
        diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: parks ? ["SPEAKER_0": [1, 0, 0]] : nil,
        )
    }

    func makeQueue(
        engine: (any TranscribingEngine)? = nil,
        stagingDir: URL? = nil,
        logDir: URL? = nil,
        diarizeEnabled: Bool = true,
        numSpeakers: Int = 0,
        vadConfig: VADConfig? = nil,
        engineForKind: ((TranscriptionEngineSetting) -> (any TranscribingEngine)?)? = nil,
        rerunSettings: (() -> PipelineJob.RerunSettings)? = nil,
        useAITitleForFilenames: Bool = false,
        completedJobLifetime: TimeInterval = 60,
        notion: NotionExportConfiguration? = nil,
        recordingRetention: RecordingRetention? = nil,
        protocolGenerator: (() -> (any ProtocolGenerating)?)? = nil,
        stageTimingLog: StageTimingLog? = nil,
    ) -> PipelineQueue {
        let (diarization, protocolGen, speakersDB) = (diarization, protocolGen, speakersDB)
        return PipelineQueue(
            engine: engine ?? self.engine,
            diarizationFactory: { diarization },
            protocolGeneratorFactory: protocolGenerator ?? { protocolGen },
            outputDir: outputDir,
            logDir: logDir ?? tmpDir.appendingPathComponent("logs"),
            stagingDir: stagingDir ?? self.stagingDir,
            diarizeEnabled: diarizeEnabled,
            echoDedupEnabled: false,
            numSpeakers: numSpeakers,
            useAITitleForFilenames: useAITitleForFilenames,
            protocolTemplateStore: templates,
            speakerMatcherFactory: { SpeakerMatcher(dbPath: speakersDB) },
            vadConfig: vadConfig,
            engineForKind: engineForKind,
            rerunSettings: rerunSettings,
            stageTimingLog: stageTimingLog,
            completedJobLifetime: completedJobLifetime,
            notionExportConfigurationProvider: notion.map { configuration in { .ready(configuration) } },
            terminalJobStore: terminal,
            meetingFileStore: store,
            inFlightRuns: InFlightRunRegistry(),
            recordingRetention: recordingRetention,
        )
    }

    /// A recorded call's three tracks, as a recorder leaves them in `folder`.
    func makeRecording(
        in folder: URL? = nil, title: String = "Google Chrome", micMuteIntervals: [MicMuteInterval] = [],
    ) throws -> PipelineJob {
        let folder = folder ?? stagingDir
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = UUID().uuidString.prefix(8)
        let tracks = try ["mix", "app", "mic"].map { name in
            let track = folder.appendingPathComponent("\(stem)_\(name).wav")
            try FileManager.default.moveItem(at: createTestAudioFile(in: folder), to: track)
            return track
        }
        return PipelineJob(
            meetingTitle: title, appName: "Microsoft Teams",
            mixPath: tracks[0], appPath: tracks[1], micPath: tracks[2], micDelay: 0, micMuteIntervals: micMuteIntervals,
            meetingStartTime: meetingStart,
        )
    }

    /// `job` (a recorded call unless given) run to its end in `queue`, once more
    /// out of the queue when `leavingTheQueue`. Finished unless `allowingAnyEnd`,
    /// for a run left waiting for names.
    @discardableResult
    func finishedMeeting(
        in queue: PipelineQueue, _ job: PipelineJob? = nil, leavingTheQueue: Bool = false, allowingAnyEnd: Bool = false,
    ) async throws -> PipelineJob {
        let job = try job ?? makeRecording()
        queue.enqueue(job, origin: .recorded)
        await queue.awaitProcessing()
        if !allowingAnyEnd {
            XCTAssertEqual(finishedEntry(job.id)?.status.state, .done, "test premise: the first run finished")
        }
        if leavingTheQueue {
            try await poll("the finished job to leave the queue") { queue.job(withID: job.id) == nil }
        }
        return job
    }

    func record(_ id: UUID) throws -> MeetingFileRecord {
        try XCTUnwrap(store.record(for: id))
    }

    func finishedEntry(_ id: UUID) -> TerminalJobRecord? {
        terminal.records.last { $0.status.jobID == id.uuidString }
    }

    /// The marker of `id`'s re-run, from the job.
    func marker(_ id: UUID, in queue: PipelineQueue) throws -> MeetingFileRecord.RerunMarker {
        try XCTUnwrap(queue.job(withID: id)?.rerun?.marker, "no re-run job")
    }

    /// The stem every file of `job`'s re-run carries.
    func rerunStem(of job: PipelineJob, in queue: PipelineQueue) throws -> String {
        let base = PipelineQueue.namingSlug(title: job.meetingTitle, jobID: job.id, startTime: meetingStart)
        return try marker(job.id, in: queue).stem(base: base)
    }

    /// Every file under the output folder, by path, with its bytes.
    func outputFiles() throws -> [String: Data] {
        guard let walker = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var files: [String: Data] = [:]
        for case let url as URL in walker where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files[url.path] = try Data(contentsOf: url)
        }
        return files
    }

    /// Polls `condition` every 10 ms until it holds, or throws after 15 s.
    func poll(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout(waitingFor: what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
