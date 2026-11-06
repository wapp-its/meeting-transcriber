@testable import MeetingTranscriber
import XCTest

/// A meeting's file record after the meeting entered the queue: leaving it, a
/// Retry, speaker naming, the raw transcript option and a Notion export. Each is
/// a place where the disk changes without a job's own stage writing the file, so
/// each is a place the record could fall behind and a later deletion refuse the
/// app's own file. `PipelineQueueMeetingFilesTests` covers the run itself.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueMeetingFilesLifecycleTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var store: MeetingFileStore!
    // swiftlint:enable implicitly_unwrapped_optional

    private let meetingStart = Date(timeIntervalSinceReferenceDate: 780_000_000)

    /// The files `SpeakerNamingSession.removeNamingData` takes with it.
    private let namingRoles: Set<MeetingFile.Role> = [.naming, .mix16k, .app16k, .mic16k, .segments]

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "meeting_files_lifecycle_test")
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

    private func makeEngine() -> MockEngine {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        return engine
    }

    /// A queue that diarizes, so every 16 kHz copy is produced, and unless told
    /// otherwise runs a job straight to `.done`.
    private func makeQueue(
        engine: MockEngine? = nil,
        protocolGen: MockProtocolGen? = MockProtocolGen(),
        parksForNaming: Bool = false,
        saveRawTranscript: Bool = true,
        completedJobLifetime: TimeInterval = 60,
        notion: NotionExportConfiguration? = nil,
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
            protocolGeneratorFactory: { protocolGen },
            outputDir: outputDir,
            logDir: logDir,
            stagingDir: stagingDir,
            diarizeEnabled: true,
            echoDedupEnabled: false,
            saveRawTranscriptSeparately: saveRawTranscript,
            completedJobLifetime: completedJobLifetime,
            notionExportConfigurationProvider: notion.map { configuration in { .ready(configuration) } },
            meetingFileStore: store,
        )
    }

    /// The three tracks a recorder leaves in staging.
    private func makeRecording() throws -> PipelineJob {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stem = UUID().uuidString.prefix(8)
        let tracks = try ["mix", "app", "mic"].map { name in
            let track = stagingDir.appendingPathComponent("\(stem)_\(name).wav")
            try FileManager.default.moveItem(at: createTestAudioFile(in: stagingDir), to: track)
            return track
        }
        return PipelineJob(
            meetingTitle: "Google Chrome", appName: "Microsoft Teams",
            mixPath: tracks[0], appPath: tracks[1], micPath: tracks[2], micDelay: 0,
            meetingStartTime: meetingStart,
        )
    }

    private func run(_ job: PipelineJob, in queue: PipelineQueue) async {
        queue.enqueue(job, origin: .recorded)
        await queue.awaitProcessing()
    }

    /// A recorded job waiting for its speaker names, every file of it written.
    private func parkForNaming(in queue: PipelineQueue) async throws -> PipelineJob {
        let job = try makeRecording()
        await run(job, in: queue)
        XCTAssertEqual(queue.job(withID: job.id)?.state, .speakerNamingPending, "test premise")
        return job
    }

    private func record(of job: PipelineJob) throws -> MeetingFileRecord {
        try XCTUnwrap(store.record(for: job.id))
    }

    private func file(_ role: MeetingFile.Role, of job: PipelineJob) throws -> MeetingFile {
        try XCTUnwrap(record(of: job).files.first { $0.role == role }, "\(role) is not listed")
    }

    private func roles(in state: MeetingFile.State, of job: PipelineJob) throws -> Set<MeetingFile.Role> {
        try Set(record(of: job).files.filter { $0.state == state }.map(\.role))
    }

    private func permissions(of path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    // MARK: - Leaving the queue

    func testCancellingAWaitingJobLeavesItUnfinishedAndListsItsRecordingWhereItMoved() async throws {
        let queue = makeQueue()
        let job = try makeRecording()
        queue.enqueue(job, origin: .recorded)
        let staged = try record(of: job).files.map(\.path)

        queue.cancelJob(id: job.id)
        await queue.lastRecordingRelocation?.value

        let record = try record(of: job)
        XCTAssertEqual(record.outcome, .leftUnfinished)
        XCTAssertEqual(record.files.map(\.role), [.mix, .appTrack, .micTrack])
        let recordings = outputDir.appendingPathComponent("recordings").resolvingSymlinksInPath().path
        for listed in record.files {
            XCTAssertFalse(staged.contains(listed.path), "\(listed.role) is still listed in staging")
            XCTAssertEqual(URL(fileURLWithPath: listed.path).deletingLastPathComponent().path, recordings, "\(listed.role)")
            XCTAssertEqual(listed.state, .present, "\(listed.role)")
            XCTAssertEqual(listed.identity, FileIdentity.of(listed.path), "\(listed.role)")
            XCTAssertNotNil(listed.identity, "\(listed.role) is not on disk")
        }
    }

    /// The queue removes a finished job after a minute, and that says nothing
    /// about how the meeting ended. Removing it takes the sidecars with it.
    func testTheQueuesReapingOfAFinishedJobKeepsItsOutcome() async throws {
        let queue = makeQueue(completedJobLifetime: 0.01)
        let job = try makeRecording()

        await run(job, in: queue)
        await waitFor(queue.jobs.isEmpty, timeout: .seconds(5))

        XCTAssertTrue(queue.jobs.isEmpty, "test premise: the job was reaped")
        XCTAssertEqual(try record(of: job).outcome, .finished(protocolExpected: true))
        XCTAssertEqual(try roles(in: .gone, of: job), [.mix16k, .app16k, .mic16k, .segments])
        XCTAssertEqual(try roles(in: .present, of: job), [.mix, .appTrack, .micTrack, .transcript, .protocol])
    }

    func testRemovingAFailedJobKeepsItsOutcome() async throws {
        let engine = makeEngine()
        engine.shouldThrow = true
        let queue = makeQueue(engine: engine)
        let job = try makeRecording()
        await run(job, in: queue)

        queue.removeJob(id: job.id)

        XCTAssertNil(queue.job(withID: job.id), "test premise: the job was removed")
        XCTAssertEqual(try record(of: job).outcome, .failed)
    }

    func testDismissingAJobAwaitingNamesLeavesItUnfinishedAndItsNamingFilesGone() async throws {
        let queue = makeQueue(parksForNaming: true)
        let job = try await parkForNaming(in: queue)
        let naming = try file(.naming, of: job)
        XCTAssertEqual(naming.state, .present)
        XCTAssertEqual(naming.identity, FileIdentity.of(naming.path))
        XCTAssertNotNil(naming.identity, "the naming file is not on disk")

        queue.removeJob(id: job.id)

        XCTAssertEqual(try record(of: job).outcome, .leftUnfinished)
        XCTAssertEqual(try roles(in: .gone, of: job), namingRoles)
        XCTAssertEqual(try roles(in: .present, of: job), [.mix, .appTrack, .micTrack, .transcript])
    }

    /// A missing folder answers "no such file" as well, and that is the drive
    /// that was unplugged: its files come back with it.
    func testFilesInAFolderThatIsNotThereStayListedAsPresent() async throws {
        let queue = makeQueue(parksForNaming: true)
        let job = try await parkForNaming(in: queue)
        let recordings = outputDir.appendingPathComponent("recordings")
        try FileManager.default.moveItem(at: recordings, to: outputDir.appendingPathComponent("unplugged"))

        queue.removeJob(id: job.id)

        XCTAssertEqual(try roles(in: .gone, of: job), [])
    }

    /// The job never comes back, so it does not stay "in progress" for good.
    func testAJobTheRestoreDiscardsForItsMissingAudioLeftUnfinished() async throws {
        let job = try makeRecording()
        store.create(MeetingFileRecord(job: job, origin: .recorded))
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try PipelineSnapshot.save([job], to: logDir)
        try FileManager.default.removeItem(at: XCTUnwrap(job.mixPath))
        let queue = makeQueue()

        queue.loadSnapshot()
        await queue.awaitSnapshotFlush()

        XCTAssertNil(queue.job(withID: job.id), "test premise: the restore discarded the job")
        XCTAssertEqual(try record(of: job).outcome, .leftUnfinished)
    }

    // MARK: - Retry

    func testARetryReturnsToInProgressAndChangesNothingElseOfTheRecord() async throws {
        let engine = makeEngine()
        engine.shouldThrow = true
        let queue = makeQueue(engine: engine)
        let job = try makeRecording()
        await run(job, in: queue)
        XCTAssertEqual(try record(of: job).outcome, .failed, "test premise")
        let deletion = MeetingFileRecord.AudioDeletion(kind: .manual, at: meetingStart)
        let failure = MeetingFileRecord.DeletionFailure(reason: "no Trash", paths: [], kind: .audioToTrash)
        store.update(jobID: job.id) { record in
            record.keep = true
            record.audioDeletion = deletion
            record.incomplete = failure
        }
        engine.shouldThrow = false
        var expected = try record(of: job)
        expected.outcome = .inProgress
        XCTAssertEqual(expected.recordingDate, meetingStart, "test premise")
        XCTAssertTrue(expected.keep, "test premise")
        XCTAssertEqual(expected.audioDeletion, deletion, "test premise")
        XCTAssertEqual(expected.incomplete, failure, "test premise")

        XCTAssertTrue(queue.retryJob(id: job.id))

        XCTAssertEqual(try record(of: job), expected)

        await queue.awaitProcessing()

        XCTAssertEqual(try record(of: job).outcome, .finished(protocolExpected: true), "judged by its new outcome")
        XCTAssertEqual(try record(of: job).recordingDate, meetingStart)
    }

    // MARK: - Speaker naming

    func testEveryWayOutOfNamingMarksItsFilesGone() async throws {
        let resolutions: [(name: String, resolve: (PipelineQueue, UUID) -> Void)] = [
            ("confirmed", { $0.completeSpeakerNaming(jobID: $1, result: .confirmed(["SPEAKER_0": "Alice"])) }),
            ("skipped", { $0.completeSpeakerNaming(jobID: $1, result: .skipped) }),
            ("stale", { queue, _ in queue.cleanupStalePending(maxAge: -1) }),
        ]
        for (name, resolve) in resolutions {
            let queue = makeQueue(parksForNaming: true)
            let job = try await parkForNaming(in: queue)

            resolve(queue, job.id)
            await waitFor(queue.job(withID: job.id)?.state == .done, timeout: .seconds(10))

            XCTAssertEqual(queue.job(withID: job.id)?.state, .done, "test premise: \(name)")
            XCTAssertEqual(try roles(in: .gone, of: job), namingRoles, name)
        }
    }

    /// The rewrite replaces the file and with it its inode. A record that kept
    /// the old one would make the app refuse its own transcript as replaced.
    func testConfirmedNamesLeaveTheIdentitiesOfTheFilesOnDisk() async throws {
        let queue = makeQueue(parksForNaming: true)
        let job = try await parkForNaming(in: queue)
        let before = try file(.transcript, of: job)

        queue.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))
        await waitFor(queue.job(withID: job.id)?.state == .done, timeout: .seconds(10))

        let after = try file(.transcript, of: job)
        XCTAssertEqual(after.path, before.path)
        XCTAssertNotEqual(FileIdentity.of(after.path), before.identity, "test premise: the file was replaced")
        XCTAssertEqual(after.identity, FileIdentity.of(after.path))
        XCTAssertEqual(after.state, .present)
        let notes = try file(.protocol, of: job)
        XCTAssertEqual(notes.identity, FileIdentity.of(notes.path))
        XCTAssertNotNil(notes.identity, "the protocol is not on disk")
    }

    /// A late re-diarization rewrites the transcript and saves the naming file a
    /// second time; the identity of both follows.
    func testALateRerunLeavesTheIdentitiesOfTheFilesOnDisk() async throws {
        let queue = makeQueue(parksForNaming: true)
        let job = try await parkForNaming(in: queue)
        let before = try [file(.transcript, of: job), file(.naming, of: job)]

        XCTAssertNil(queue.completeSpeakerNaming(jobID: job.id, result: .rerun(2)))
        await waitFor(queue.job(withID: job.id)?.state == .speakerNamingPending, timeout: .seconds(10))

        XCTAssertEqual(queue.job(withID: job.id)?.state, .speakerNamingPending, "test premise")
        for old in before {
            let after = try file(old.role, of: job)
            XCTAssertEqual(after.path, old.path, "\(old.role)")
            XCTAssertNotEqual(FileIdentity.of(after.path), old.identity, "test premise: \(old.role) was replaced")
            XCTAssertEqual(after.identity, FileIdentity.of(after.path), "\(old.role)")
        }
    }

    /// The naming data of a parked job, and the name its files go by.
    private func parkedNamingData(of job: PipelineJob, in queue: PipelineQueue) throws -> (
        data: PipelineQueue.SpeakerNamingData, slug: String,
    ) {
        let slug = try XCTUnwrap(queue.job(withID: job.id)?.namingSlug)
        return try (XCTUnwrap(SpeakerNamingStore(outputDir: outputDir).load(slug: slug)), slug)
    }

    /// A save that did not land says nothing about what sits at its path: here a
    /// link to someone else's file, which the record must never take for the
    /// meeting's own.
    func testAFailedNamingSaveLeavesTheRecordAsItWas() async throws {
        let queue = makeQueue(parksForNaming: true)
        let job = try await parkForNaming(in: queue)
        let before = try record(of: job).files
        let (data, slug) = try parkedNamingData(of: job, in: queue)
        let naming = try URL(fileURLWithPath: file(.naming, of: job).path)
        let theirs = tmpDir.appendingPathComponent("theirs.txt")
        try Data("theirs".utf8).write(to: theirs)
        try FileManager.default.removeItem(at: naming)
        try FileManager.default.createSymbolicLink(at: naming, withDestinationURL: theirs)
        let folder = naming.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        }

        XCTAssertFalse(queue.naming.saveNamingData(data, slug: slug, in: outputDir), "test premise")

        XCTAssertEqual(try record(of: job).files, before)
    }

    /// A save into another folder while the first cannot be reached: the first
    /// file still exists, so a later deletion has to find both.
    func testANamingFileInAFolderThatIsNotThereStaysListedBesideANewOne() async throws {
        let queue = makeQueue(parksForNaming: true)
        let job = try await parkForNaming(in: queue)
        let first = try file(.naming, of: job).path
        let (data, slug) = try parkedNamingData(of: job, in: queue)
        try FileManager.default.moveItem(at: outputDir, to: tmpDir.appendingPathComponent("unplugged"))
        let other = tmpDir.appendingPathComponent("other")

        XCTAssertTrue(queue.naming.saveNamingData(data, slug: slug, in: other), "test premise")

        let second = other.appendingPathComponent("recordings/\(slug)_naming.json")
        let listed = try record(of: job).files.filter { $0.role == .naming }
        XCTAssertEqual(listed.map(\.path), [first, MeetingFile.resolvedPath(second)])
        XCTAssertEqual(listed.map(\.state), [.present, .present])
    }

    // MARK: - The raw transcript option

    func testWithTheRawTranscriptOptionOffItsFilesAreGoneAfterDone() async throws {
        let queue = makeQueue(saveRawTranscript: false)
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertNil(queue.job(withID: job.id)?.transcriptPath, "test premise: the transcript was removed")
        XCTAssertEqual(try roles(in: .gone, of: job), [.transcript, .segments])
    }

    /// A protocol that failed keeps the only copy of the meeting's text.
    func testARawTranscriptKeptAfterAFailedProtocolStaysListed() async throws {
        let generator = MockProtocolGen()
        generator.shouldThrow = true
        let queue = makeQueue(protocolGen: generator, saveRawTranscript: false)
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertEqual(try roles(in: .gone, of: job), [])
        XCTAssertEqual(try file(.transcript, of: job).state, .present)
    }

    // MARK: - Segments file permissions

    func testTheSegmentsFileIsWrittenOwnerOnly() async throws {
        let queue = makeQueue()
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertEqual(try permissions(of: file(.segments, of: job).path), FileManager.ownerOnlyPermissions)
    }

    /// Only a write sets the permission, and reading one for a re-run is none.
    func testAnOlderSegmentsFileKeepsItsPermissions() async throws {
        let queue = makeQueue(parksForNaming: true)
        let job = try await parkForNaming(in: queue)
        let segments = try file(.segments, of: job).path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: segments)

        XCTAssertNil(queue.completeSpeakerNaming(jobID: job.id, result: .rerun(2)))
        await waitFor(queue.job(withID: job.id)?.state == .speakerNamingPending, timeout: .seconds(10))

        XCTAssertEqual(try permissions(of: segments), 0o644)
    }

    // MARK: - Notion export

    /// Answers at once, after creating its page, and fails after that if told to.
    private actor ScriptedNotionExporter: NotionExporting {
        struct AppendFailed: Error {}

        private let failsAfterCreatingThePage: Bool

        init(failsAfterCreatingThePage: Bool = false) {
            self.failsAfterCreatingThePage = failsAfterCreatingThePage
        }

        func exportMeeting( // swiftlint:disable:this function_parameter_count
            title _: String, date _: Date?, tags _: [String], markdown _: String,
            transcript _: String?, existingPageID _: String?,
            onPageCreated: @Sendable (NotionPageResult) async -> Void,
        ) async throws -> NotionPageResult {
            let page = NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
            await onPageCreated(page)
            if failsAfterCreatingThePage { throw AppendFailed() }
            return page
        }
    }

    private func configuration(
        _ exporter: any NotionExporting, skipLocalMarkdown: Bool = false,
    ) -> NotionExportConfiguration {
        NotionExportConfiguration(exporter: exporter, databaseID: "database-1", skipLocalMarkdown: skipLocalMarkdown)
    }

    /// The page exists as soon as it is created, with none of the content
    /// appended yet, so that alone is not a saved protocol.
    func testTheNotionMarkWaitsForTheWholeExport() async throws {
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let queue = makeQueue(notion: configuration(exporter))
        let job = try makeRecording()
        queue.enqueue(job, origin: .recorded)
        await waitFor { queue.job(withID: job.id)?.notionPageID != nil }
        XCTAssertNotNil(queue.job(withID: job.id)?.notionPageID, "test premise: the page exists")

        XCTAssertFalse(try record(of: job).savedToNotion)

        await exporter.release()
        await queue.awaitProcessing()
        XCTAssertTrue(try record(of: job).savedToNotion)
    }

    func testAnExportThatFailsAfterCreatingItsPageLeavesTheMarkOff() async throws {
        let queue = makeQueue(notion: configuration(ScriptedNotionExporter(failsAfterCreatingThePage: true)))
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertEqual(queue.job(withID: job.id)?.notionExportStatus, .failed, "test premise")
        XCTAssertNotNil(queue.job(withID: job.id)?.notionPageID, "test premise: the page was created")
        XCTAssertFalse(try record(of: job).savedToNotion)
    }

    func testACompletedExportSetsTheMarkAndKeepsItWhenTheLocalFileGoes() async throws {
        let queue = makeQueue(notion: configuration(ScriptedNotionExporter(), skipLocalMarkdown: true))
        let job = try makeRecording()

        await run(job, in: queue)

        XCTAssertNil(queue.job(withID: job.id)?.protocolPath, "test premise: the local file was removed")
        XCTAssertTrue(try record(of: job).savedToNotion)
        XCTAssertEqual(try file(.protocol, of: job).state, .gone)
    }

    /// The page holds what the failed export left of it, so the meeting's latest
    /// export is what counts.
    func testALaterExportThatFailsTakesTheMarkBack() async throws {
        let queue = makeQueue(notion: configuration(ScriptedNotionExporter()))
        let job = try makeRecording()
        await run(job, in: queue)
        XCTAssertTrue(try record(of: job).savedToNotion, "test premise")

        let succeeded = await queue.exportToNotion(
            jobID: job.id, protocolMD: "# Notes", transcript: nil, speakerNames: [],
            configuration: configuration(ScriptedNotionExporter(failsAfterCreatingThePage: true)),
        )

        XCTAssertFalse(succeeded, "test premise")
        XCTAssertFalse(try record(of: job).savedToNotion)
    }

    /// A re-export queued before the job's `.done` starts only after it, and a
    /// quit in between ends it failed without it ever having run.
    func testAQueuedReExportTakesTheMarkBackBeforeItRuns() async throws {
        let exporter = ScriptedNotionExporter()
        let queue = makeQueue(notion: configuration(exporter))
        let job = try makeRecording()
        await run(job, in: queue)
        XCTAssertTrue(try record(of: job).savedToNotion, "test premise")

        queue.queueNotionExport(
            PendingNotionExport(
                protocolMD: "# Notes", transcript: nil, speakerNames: [],
                configuration: configuration(exporter), savedLocally: true,
            ),
            jobID: job.id,
        )

        XCTAssertFalse(try record(of: job).savedToNotion)
    }
}
