@testable import MeetingTranscriber
import XCTest

/// Every Notion export a test's exporters were asked for: the database each went
/// to and the page it was told to update (nil: a create).
actor RerunExportLog {
    private(set) var calls: [(database: String, page: String?)] = []
    var failing = false

    func setFailing(_ fails: Bool) {
        failing = fails
    }

    func note(database: String, page: String?) -> Bool {
        calls.append((database, page))
        return failing
    }
}

/// An exporter bound to one database, as `NotionClient` is, that logs each call.
struct RerunLoggingExporter: NotionExporting {
    let database: String
    let log: RerunExportLog

    // swiftlint:disable:next function_parameter_count
    func exportMeeting(
        title _: String, date _: Date?, tags _: [String], markdown _: String, transcript _: String?,
        existingPageID: String?, onPageCreated: @Sendable (NotionPageResult) async -> Void,
    ) async throws -> NotionPageResult {
        if await log.note(database: database, page: existingPageID) { throw URLError(.notConnectedToInternet) }
        let page = NotionPageResult(pageID: existingPageID ?? "page-1", url: "https://www.notion.so/page-1")
        if existingPageID == nil { await onPageCreated(page) }
        return page
    }

    static func configuration(_ database: String, _ log: RerunExportLog) -> NotionExportConfiguration {
        NotionExportConfiguration(exporter: Self(database: database, log: log), databaseID: database) { Self(database: $0, log: log) }
    }
}

/// A re-run's success (R5): its files take the meeting's current names, the current
/// ones stay beside them as earlier versions, the record, the finished entry and the
/// readback follow, and its Notion export updates the meeting's page.
@MainActor
final class PipelineQueueRerunSwapTests: XCTestCase {
    private typealias Fixture = PipelineQueueRerunFixture

    private func makeFixture() throws -> Fixture {
        try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_swap"))
    }

    /// The re-run of `meeting` in `queue` held at its success, then let swap.
    /// `beforeSwap` runs while it is held.
    @discardableResult
    private func rerunToSuccess(
        _ meeting: PipelineJob, in queue: PipelineQueue, _ fixture: Fixture, beforeSwap: (MeetingFileRecord.RerunMarker) throws -> Void = { _ in },
    ) async throws -> MeetingFileRecord.RerunMarker {
        queue.isRegenerationRunning = { true }
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        let marker = try fixture.marker(meeting.id, in: queue)
        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .done, "test premise: the re-run succeeded")
        try beforeSwap(marker)
        queue.isRegenerationRunning = { false }
        try await fixture.poll("the swap to end") { queue.job(withID: meeting.id)?.rerun == nil }
        return marker
    }

    private func earlier(_ url: URL, _ marker: MeetingFileRecord.RerunMarker) -> URL {
        let name = EarlierVersionName.name(for: url.path, stamp: marker.stamp, taken: []) ?? ""
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func newFile(_ role: MeetingFile.Role, _ marker: MeetingFileRecord.RerunMarker) throws -> MeetingFile {
        try XCTUnwrap(marker.files.last { $0.role == role }, "the re-run wrote no \(role)")
    }

    private func paths(of id: UUID, _ fixture: Fixture) throws -> (transcript: URL?, notes: URL?) {
        let status = try XCTUnwrap(fixture.finishedEntry(id)?.status)
        return (status.transcriptPath.map { URL(filePath: $0) }, status.protocolPath.map { URL(filePath: $0) })
    }

    // MARK: - Success

    func testASuccessKeepsTheEarlierFilesBesideTheNewOnesAndTheReadbackShowsTheNewResult() async throws {
        let fixture = try makeFixture()
        let first = fixture.makeQueue(completedJobLifetime: 0)
        let meeting = try await fixture.finishedMeeting(in: first, leavingTheQueue: true)
        let (transcript, notes) = try paths(of: meeting.id, fixture)
        let current = try (XCTUnwrap(transcript), XCTUnwrap(notes))
        let report = current.1.deletingLastPathComponent()
            .appendingPathComponent("\(current.1.deletingPathExtension().lastPathComponent) (Summary).md")
        try "A report of the meeting".write(to: report, atomically: true, encoding: .utf8)
        let before = try fixture.outputFiles()
        let entryBefore = try XCTUnwrap(fixture.finishedEntry(meeting.id))
        _ = try await fixture.finishedMeeting(in: first, leavingTheQueue: true) // a newer meeting
        let queue = fixture.makeQueue()

        let marker = try await rerunToSuccess(meeting, in: queue, fixture)

        let after = try fixture.outputFiles()
        let (newTranscript, newNotes) = try (newFile(.transcript, marker), newFile(.protocol, marker))
        XCTAssertEqual(after[earlier(current.0, marker).path], before[current.0.path], "the earlier transcript changed")
        XCTAssertEqual(after[earlier(current.1, marker).path], before[current.1.path], "the earlier notes changed")
        XCTAssertEqual(FileIdentity.of(current.0.path), newTranscript.identity, "the new transcript is not current")
        XCTAssertEqual(FileIdentity.of(current.1.path), newNotes.identity, "the new notes are not current")
        XCTAssertEqual(after[report.path], before[report.path], "the additional report changed")
        XCTAssertFalse(after.keys.contains { $0.contains(".rerun-") }, "a file of the re-run is left: \(after.keys.sorted())")

        let record = try fixture.record(meeting.id)
        XCTAssertNil(record.rerun)
        XCTAssertEqual(record.rerunNote, .init(stamp: marker.stamp, committed: true))
        XCTAssertEqual(record.outcome, .finished(protocolExpected: true))
        XCTAssertEqual(record.files.last { $0.role == .transcript }?.identity, newTranscript.identity)
        XCTAssertEqual(record.files.last { $0.role == .protocol }?.identity, newNotes.identity)
        let kept = record.files.filter { $0.role == .previousProtocol && $0.owned && $0.state == .present }.map(\.path)
        XCTAssertEqual(Set(kept), [earlier(current.0, marker).path, earlier(current.1, marker).path])
        let trashed = Set(record.filesCovered(by: .meetingToTrash).map(\.path))
        XCTAssertTrue(trashed.isSuperset(of: kept + [current.0.path, current.1.path]), "Move Meeting to Trash misses a file")
        let confirmation = TrashConfirmationText.moveMeeting(
            meetingTitle: meeting.meetingTitle, record: record,
            audio: .init(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 1000), hasNotionPage: false, hasFailedExport: false,
        )
        for path in kept {
            XCTAssertTrue(confirmation.lines.last?.contains(URL(filePath: path).lastPathComponent) ?? false, "not named: \(path)")
        }

        // Open Notes, Open Transcript, Last Recording and the automation API.
        let job = try XCTUnwrap(queue.job(withID: meeting.id), "the finished job left at once")
        XCTAssertEqual(job.transcriptPath, current.0)
        XCTAssertEqual(job.protocolPath, current.1)
        XCTAssertEqual(fixture.terminal.records.last?.status.jobID, meeting.id.uuidString, "Last Recording does not show it")
        let entry = try XCTUnwrap(fixture.finishedEntry(meeting.id))
        XCTAssertEqual(entry.status.transcriptPath, current.0.path)
        XCTAssertEqual(entry.status.protocolPath, current.1.path)
        XCTAssertEqual(entry.enqueuedAt, entryBefore.enqueuedAt, "the row moved")
        await PipelineSnapshotStore.flush(fixture.logDir)
        let saved = try PipelineSnapshot.load(from: fixture.logDir, named: fixture.rerunFile.lastPathComponent) ?? []
        XCTAssertTrue(saved.isEmpty || saved.allSatisfy { $0.id != meeting.id }, "the re-run file still holds the job")
        let controller = try makeController(on: queue, fixture)
        XCTAssertEqual(controller.jobStatus(forID: meeting.id)?.protocolPath, current.1.path)
    }

    func testAMeetingWithItsAITitleKeepsItAndItsEarlierVersionsCarryIt() async throws {
        let fixture = try makeFixture()
        fixture.protocolGen.headingTitle = "Budget Review"
        let queue = fixture.makeQueue(useAITitleForFilenames: true, completedJobLifetime: 0)
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let (transcript, notes) = try paths(of: meeting.id, fixture)
        let current = try (XCTUnwrap(transcript), XCTUnwrap(notes))
        XCTAssertTrue(current.0.lastPathComponent.hasPrefix("budget_review"), "test premise: \(current.0.lastPathComponent)")

        let marker = try await rerunToSuccess(meeting, in: queue, fixture)

        XCTAssertEqual(try paths(of: meeting.id, fixture).transcript, current.0)
        XCTAssertEqual(try paths(of: meeting.id, fixture).notes, current.1)
        for url in [current.0, current.1] {
            let kept = earlier(url, marker)
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "no earlier version at \(kept.lastPathComponent)")
            XCTAssertTrue(kept.lastPathComponent.hasPrefix("budget_review.until-"), kept.lastPathComponent)
        }
    }

    func testWithNotesOffOnlyTheTranscriptIsSwapped() async throws {
        let fixture = try makeFixture()
        var generator: (any ProtocolGenerating)? = fixture.protocolGen
        // The fixture takes several closures; the label says which one this is.
        // swiftlint:disable:next trailing_closure
        let queue = fixture.makeQueue(completedJobLifetime: 0, protocolGenerator: { generator })
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let (transcript, notes) = try paths(of: meeting.id, fixture)
        let current = try (XCTUnwrap(transcript), XCTUnwrap(notes))
        let before = try fixture.outputFiles()
        let notesIdentity = FileIdentity.of(current.1.path)
        generator = nil

        let marker = try await rerunToSuccess(meeting, in: queue, fixture)

        XCTAssertEqual(try fixture.outputFiles()[current.1.path], before[current.1.path], "the current notes changed")
        XCTAssertEqual(FileIdentity.of(current.1.path), notesIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlier(current.1, marker).path), "the notes got an earlier version")
        XCTAssertEqual(try fixture.outputFiles()[earlier(current.0, marker).path], before[current.0.path])
        XCTAssertEqual(FileIdentity.of(current.0.path), try newFile(.transcript, marker).identity)
        XCTAssertEqual(try paths(of: meeting.id, fixture).notes, current.1)
    }

    func testAMeetingWithoutNotesGetsTheNewNotesUnderItsNotesNameAndNoEarlierNotes() async throws {
        let fixture = try makeFixture()
        var generator: (any ProtocolGenerating)?
        // swiftlint:disable:next trailing_closure
        let queue = fixture.makeQueue(completedJobLifetime: 0, protocolGenerator: { generator })
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let transcript = try XCTUnwrap(paths(of: meeting.id, fixture).transcript)
        XCTAssertNil(try paths(of: meeting.id, fixture).notes, "test premise: no notes")
        generator = fixture.protocolGen

        let marker = try await rerunToSuccess(meeting, in: queue, fixture)

        let notes = transcript.deletingPathExtension().appendingPathExtension("md")
        XCTAssertEqual(FileIdentity.of(notes.path), try newFile(.protocol, marker).identity)
        XCTAssertEqual(try paths(of: meeting.id, fixture).notes, notes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlier(notes, marker).path))
        XCTAssertEqual(try fixture.record(meeting.id).files.filter { $0.role == .previousProtocol }.count, 1, "one earlier transcript")
    }

    func testTheNewSegmentsFileTakesTheCurrentNameAndTheEarlierOneIsDeleted() async throws {
        // Kept: word timings the meeting kept from its first run. Unlisted: a record
        // without a segments file, whose new one goes where the speaker naming reads it.
        for kept in [true, false] {
            let fixture = try makeFixture()
            let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0), leavingTheQueue: true)
            let transcript = try XCTUnwrap(paths(of: meeting.id, fixture).transcript)
            let segments = fixture.recordingsDir.appendingPathComponent("\(transcript.deletingPathExtension().lastPathComponent)_segments.json")
            if kept {
                try Data("earlier word timings".utf8).write(to: segments)
                XCTAssertTrue(fixture.store.update(jobID: meeting.id) { $0.list(MeetingFile(role: .segments, url: segments, owned: true)) })
            } else {
                XCTAssertTrue(fixture.store.update(jobID: meeting.id) { $0.files.removeAll { $0.role == .segments } })
            }
            let queue = fixture.makeQueue()

            let marker = try await rerunToSuccess(meeting, in: queue, fixture)

            let new = try newFile(.segments, marker)
            XCTAssertEqual(FileIdentity.of(segments.path), new.identity, "kept \(kept): the new segments file is not current")
            let names = try FileManager.default.contentsOfDirectory(atPath: segments.deletingLastPathComponent().path)
            XCTAssertFalse(names.contains { $0.contains("_segments.until-") }, "kept \(kept): the earlier segments file is kept: \(names)")
            let record = try fixture.record(meeting.id)
            XCTAssertEqual(record.files.last { $0.role == .segments }?.identity, new.identity, "kept \(kept)")
            let listed = record.files.filter { $0.role == .previousProtocol && $0.state != .gone }.map { URL(filePath: $0.path).lastPathComponent }
            XCTAssertFalse(listed.contains { $0.contains("_segments") }, "kept \(kept): the earlier segments file is listed: \(listed)")
        }
    }

    // MARK: - The raw transcript setting

    func testTheRawTranscriptSettingAtTheClickDecidesTheCurrentTranscript() async throws {
        let rows: [(name: String, first: Bool, rerun: Bool)] = [
            ("off, still off", false, false),
            ("off, turned on", false, true),
            ("kept, turned off", true, false),
        ]
        for row in rows {
            let fixture = try makeFixture()
            let first = fixture.makeQueue(saveRawTranscriptSeparately: row.first, completedJobLifetime: 0)
            let meeting = try await fixture.finishedMeeting(in: first, leavingTheQueue: true)
            let notes = try XCTUnwrap(paths(of: meeting.id, fixture).notes, row.name)
            let txt = notes.deletingPathExtension().appendingPathExtension("txt")
            XCTAssertEqual(FileManager.default.fileExists(atPath: txt.path), row.first, "\(row.name): test premise")
            let queue = fixture.makeQueue(saveRawTranscriptSeparately: row.rerun, completedJobLifetime: 0)

            let marker = try await rerunToSuccess(meeting, in: queue, fixture)

            let record = try fixture.record(meeting.id)
            XCTAssertEqual(FileIdentity.of(notes.path), try newFile(.protocol, marker).identity, row.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: earlier(notes, marker).path), "\(row.name): no earlier notes")
            XCTAssertEqual(FileManager.default.fileExists(atPath: txt.path), row.rerun, "\(row.name): the current transcript")
            XCTAssertEqual(FileManager.default.fileExists(atPath: earlier(txt, marker).path), row.first, "\(row.name): earlier transcript")
            XCTAssertEqual(try paths(of: meeting.id, fixture).transcript, row.rerun ? txt : nil, row.name)
            let transcriptEntry = record.files.last { $0.role == .transcript }
            XCTAssertEqual(transcriptEntry?.path, txt.path, row.name)
            XCTAssertEqual(transcriptEntry?.state == .gone, !row.rerun, row.name)
            if !row.rerun {
                let segments = try FileManager.default.contentsOfDirectory(atPath: fixture.recordingsDir.path)
                    .filter { $0.hasSuffix("_segments.json") }
                XCTAssertTrue(segments.isEmpty, "\(row.name): a segments file is left: \(segments)")
                XCTAssertTrue(record.files.filter { $0.role == .segments }.allSatisfy { $0.state == .gone }, row.name)
            }
        }
    }

    // MARK: - Notion

    func testTheExportUpdatesThePageInTheRecordsDatabaseAndAFailedOneIsRetriedThere() async throws {
        for fails in [false, true] {
            let fixture = try makeFixture()
            let log = RerunExportLog()
            let first = fixture.makeQueue(completedJobLifetime: 0, notion: RerunLoggingExporter.configuration("db-record", log))
            let meeting = try await fixture.finishedMeeting(in: first, leavingTheQueue: true)
            XCTAssertEqual(try fixture.record(meeting.id).runInputs?.notionPageID, "page-1", "test premise")
            // Settings name another database now.
            let queue = fixture.makeQueue(completedJobLifetime: 0, notion: RerunLoggingExporter.configuration("db-settings", log))
            await log.setFailing(fails)
            let callsBefore = await log.calls.count

            let marker = try await rerunToSuccess(meeting, in: queue, fixture)
            try await fixture.poll("the export to end") { queue.notionExportTasks[meeting.id] == nil }

            var calls = await log.calls.dropFirst(callsBefore)
            XCTAssertEqual(calls.map(\.database), ["db-record"], "fails \(fails)")
            XCTAssertEqual(calls.map(\.page), ["page-1"], "fails \(fails): not an update of the page")
            let notes = try XCTUnwrap(paths(of: meeting.id, fixture).notes)
            XCTAssertEqual(FileIdentity.of(notes.path), try newFile(.protocol, marker).identity, "fails \(fails): the swap was undone")
            guard fails else { continue }
            XCTAssertTrue(queue.canRetryNotionExport(id: meeting.id), "no Retry Notion Export")
            await log.setFailing(false)

            let retried = await queue.retryNotionExport(id: meeting.id)

            XCTAssertTrue(retried)
            calls = await log.calls.dropFirst(callsBefore + 1)
            XCTAssertEqual(calls.map(\.database), ["db-record"])
            XCTAssertEqual(calls.map(\.page), ["page-1"])
        }
    }

    func testARecordWithAPageButNoDatabaseUpdatesThatPageInTheConfiguredDatabase() async throws {
        let fixture = try makeFixture()
        let log = RerunExportLog()
        let first = fixture.makeQueue(completedJobLifetime: 0, notion: RerunLoggingExporter.configuration("db-settings", log))
        let meeting = try await fixture.finishedMeeting(in: first, leavingTheQueue: true)
        // A record from before the run inputs named the database.
        XCTAssertTrue(fixture.store.update(jobID: meeting.id) { $0.runInputs?.notionDatabaseID = nil }, "test premise")
        let queue = fixture.makeQueue(completedJobLifetime: 0, notion: RerunLoggingExporter.configuration("db-settings", log))
        let callsBefore = await log.calls.count

        try await rerunToSuccess(meeting, in: queue, fixture)
        try await fixture.poll("the export to end") { queue.notionExportTasks[meeting.id] == nil }

        let calls = await log.calls.dropFirst(callsBefore)
        XCTAssertEqual(calls.map(\.database), ["db-settings"])
        XCTAssertEqual(calls.map(\.page), ["page-1"], "a second page was made")
    }

    // MARK: - Queue replacement

    func testASwapWaitingInAReplacedQueueRunsInTheQueueThatAdoptedIt() async throws {
        let fixture = try makeFixture()
        let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0), leavingTheQueue: true)
        let queue = fixture.makeQueue()
        queue.isRegenerationRunning = { true }
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        let marker = try fixture.marker(meeting.id, in: queue)
        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .done, "test premise: the re-run succeeded")
        let replacement = fixture.makeQueue()

        replacement.adoptJobs(of: queue)
        queue.retire()

        try await fixture.poll("the swap to end") { replacement.job(withID: meeting.id)?.rerun == nil }
        let transcript = try XCTUnwrap(paths(of: meeting.id, fixture).transcript)
        XCTAssertEqual(FileIdentity.of(transcript.path), try newFile(.transcript, marker).identity)
        XCTAssertNil(try fixture.record(meeting.id).rerun)
    }

    // MARK: - Helpers

    private func makeController(on queue: PipelineQueue, _ fixture: Fixture) throws -> PipelineController {
        let suite = "PipelineQueueRerunSwapTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: fixture.outputDir)
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: fixture.tmpDir.appendingPathComponent("controller"), initialQueue: queue),
            terminalJobStore: fixture.terminal, meetingFileStore: fixture.store,
        )
    }
}
