@testable import MeetingTranscriber
import XCTest

// MARK: - The window's deletion actions

/// Move Audio to Trash, Move Meeting to Trash, Retry Deletion and Keep, callable
/// on their own before any button exists. A manual deletion only ever goes to the
/// Trash, a file it could not move stays visible with a retry, and a menu that has
/// gone stale cannot act on a meeting whose state changed.
extension PipelineControllerTranscriptionsTests {
    private struct Refused: Error {}

    func makeDeletionHarness() throws -> MeetingDeletionHarness {
        let suite = "MeetingDeletion-\(getpid())-\(UUID().uuidString)"
        let root = try makeTempDirectory(prefix: "meeting-deletion")
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: root.appendingPathComponent("output"),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try MeetingDeletionHarness(root: root, settings: settings)
    }

    // MARK: - Move Audio

    func testMoveAudioMovesTheAudioKeepsTheTextAndRecordsTheDate() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let audio = try harness.paths(of: job) { $0.role.isAudio }
        let text = try harness.paths(of: job) { !$0.role.isAudio }

        XCTAssertTrue(controller.moveAudioToTrash(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, harness.names(audio))
        XCTAssertEqual(audio.filter(harness.isOnDisk), [], "audio stayed")
        XCTAssertEqual(text.filter(harness.isOnDisk), text, "the transcript or protocol went")
        let record = try harness.record(of: job)
        XCTAssertEqual(record.audioDeletion, .init(kind: .manual, at: MeetingDeletionHarness.now))
        XCTAssertNil(record.pending)
        XCTAssertNil(record.incomplete)
        XCTAssertNotNil(harness.history.lookup(jobID: job.id), "the row must stay")
        XCTAssertEqual(harness.deletedForGood, [])
    }

    func testAFileTheTrashRefusesStaysAndTheRecordHoldsTheReasonAndThePathsLeft() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let refused = try XCTUnwrap(job.appPath).lastPathComponent
        harness.fakeTrash.refusal = { $0.lastPathComponent == refused ? CocoaError(.featureUnsupported) : nil }

        XCTAssertTrue(controller.moveAudioToTrash(jobID: job.id))

        let record = try harness.record(of: job)
        XCTAssertEqual(record.incomplete?.reason, "this volume has no Trash")
        XCTAssertEqual(record.incomplete?.kind, .audioToTrash)
        XCTAssertEqual(harness.names(record.incomplete?.paths ?? []), [refused])
        XCTAssertTrue(try harness.isOnDisk(XCTUnwrap(job.appPath).path), "a refused file went")
        XCTAssertEqual(harness.deletedForGood, [], "never deleted for good instead")
        XCTAssertNil(record.pending)
        XCTAssertNil(record.audioDeletion)
    }

    func testAnUnreachableFileStaysListedAndTheReasonSaysWhy() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let audio = try harness.paths(of: job) { $0.role.isAudio }
        let unplugged = harness.root.appendingPathComponent("unplugged")
        try FileManager.default.moveItem(at: harness.recordings, to: unplugged)

        XCTAssertTrue(controller.moveAudioToTrash(jobID: job.id))

        let record = try harness.record(of: job)
        XCTAssertEqual(record.incomplete?.reason, "3 files are on a drive or in a folder that is not available")
        XCTAssertEqual(record.incomplete?.paths, audio)
        XCTAssertEqual(record.files.filter { $0.state == .gone }, [], "out of reach is not gone")
        XCTAssertEqual(harness.fakeTrash.moved, [])
    }

    // MARK: - Move Meeting

    func testMoveMeetingMovesEveryFileAndTheMeetingLeavesEveryList() async throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        controller.queue.insertJobForTesting(job)
        let files = try harness.paths(of: job)

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, harness.names(files))
        await waitFor(harness.store.record(for: job.id) == nil, timeout: .seconds(5))
        XCTAssertNil(harness.store.record(for: job.id))
        XCTAssertNil(MeetingFileStore(path: harness.recordPath).record(for: job.id), "the record came back after a restart")
        XCTAssertNil(harness.history.lookup(jobID: job.id), "the finished-job entry stayed")
        XCTAssertFalse(controller.queue.jobs.contains { $0.id == job.id }, "the queue job stayed")
        XCTAssertNil(controller.jobStatus(forID: job.id), "the automation API must answer 404")
        XCTAssertFalse(controller.transcriptionEntries.contains { $0.id == job.id }, "the row stayed")
        let mix = try XCTUnwrap(job.mixPath).standardizedFileURL.path
        XCTAssertTrue(ProcessedRecordingsLedger(logDir: harness.logDir).load().contains(mix), "orphan recovery would bring it back")
    }

    /// A meeting kept only as a Notion page, after its audio went: a row no other
    /// action could remove.
    func testAMeetingWithNoLocalFileLeftLeavesTheListTheSameWay() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let files = try harness.paths(of: job)
        for path in files {
            try FileManager.default.removeItem(atPath: path)
        }
        harness.store.update(jobID: job.id) { record in
            for index in record.files.indices {
                record.files[index].state = .gone
            }
        }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertNil(harness.store.record(for: job.id))
        XCTAssertNil(controller.jobStatus(forID: job.id))
    }

    func testAnImportsSourceFileIsNeverMoved() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.importedMeeting()
        let source = try XCTUnwrap(job.mixPath)
        let text = try harness.paths(of: job) { $0.owned }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, harness.names(text))
        XCTAssertTrue(harness.isOnDisk(source.path), "the user's own file went")
        XCTAssertNil(harness.store.record(for: job.id))
        XCTAssertNil(harness.history.lookup(jobID: job.id))
    }

    func testAPartialMeetingDeletionLeavesTheRowAndTheRecordMarkedIncomplete() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        controller.queue.insertJobForTesting(job)
        let refused = try XCTUnwrap(job.protocolPath).lastPathComponent
        harness.fakeTrash.refusal = { $0.lastPathComponent == refused ? Refused() : nil }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        let record = try harness.record(of: job)
        XCTAssertEqual(record.incomplete?.kind, .meetingToTrash)
        XCTAssertEqual(harness.names(record.incomplete?.paths ?? []), [refused])
        XCTAssertNil(record.pending)
        XCTAssertNotNil(harness.history.lookup(jobID: job.id), "the row must stay")
        XCTAssertTrue(controller.queue.jobs.contains { $0.id == job.id })
    }

    // MARK: - Retry

    func testRetryMovesOnlyTheFileStillThereAndCompletesTheAction() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let audioJob = try harness.recordedMeeting()
        let meetingJob = try harness.recordedMeeting()
        let cases: [(job: PipelineJob, first: (UUID) -> Bool)] = [
            (audioJob, { controller.moveAudioToTrash(jobID: $0) }),
            (meetingJob, { controller.moveMeetingToTrash(jobID: $0) }),
        ]
        for testCase in cases {
            let refused = try XCTUnwrap(testCase.job.micPath).lastPathComponent
            harness.fakeTrash.refusal = { $0.lastPathComponent == refused ? Refused() : nil }
            XCTAssertTrue(testCase.first(testCase.job.id))
            XCTAssertNotNil(try harness.record(of: testCase.job).incomplete, "test premise")
            let movedBefore = harness.fakeTrash.moved.count
            harness.fakeTrash.refusal = { _ in nil }

            XCTAssertTrue(controller.retryDeletion(jobID: testCase.job.id))

            XCTAssertEqual(Array(harness.fakeTrash.moved.dropFirst(movedBefore)), [refused])
        }
        XCTAssertEqual(try harness.record(of: audioJob).audioDeletion, .init(kind: .manual, at: MeetingDeletionHarness.now))
        XCTAssertNil(try harness.record(of: audioJob).incomplete)
        XCTAssertNil(harness.store.record(for: meetingJob.id), "the retry did not complete the removal")
        XCTAssertNil(harness.history.lookup(jobID: meetingJob.id))
    }

    /// The user cleared the file out by hand, say from the drive that came back.
    func testARetryThatFindsTheRemainingFilesGoneCompletesTheRemoval() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        harness.fakeTrash.refusal = { _ in Refused() }
        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))
        for path in try harness.paths(of: job) {
            try FileManager.default.removeItem(atPath: path)
        }

        XCTAssertTrue(controller.retryDeletion(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertNil(harness.store.record(for: job.id))
    }

    /// "Incomplete" is for manual deletions: an automatic one is the next check's.
    func testRetryRefusesAMeetingWithNothingIncompleteOrAnAutomaticFailure() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()

        XCTAssertFalse(controller.retryDeletion(jobID: job.id))

        harness.store.update(jobID: job.id) { $0.incomplete = .init(reason: "earlier", paths: [], kind: .automatic) }
        XCTAssertFalse(controller.retryDeletion(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, [])
    }

    // MARK: - Keep

    func testKeepIsStoredAndSurvivesARestart() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()

        XCTAssertTrue(controller.setKeep(jobID: job.id, true))
        XCTAssertEqual(MeetingFileStore(path: harness.recordPath).record(for: job.id)?.keep, true)

        XCTAssertTrue(controller.setKeep(jobID: job.id, false))
        XCTAssertEqual(MeetingFileStore(path: harness.recordPath).record(for: job.id)?.keep, false)
    }

    // MARK: - Refusals

    /// Each state a stale menu can still act on. Every action refuses, nothing
    /// changes, and each guard is seen without the others helping: the record says
    /// finished while the queue says otherwise, and the other way round.
    func testEveryActionRefusesAMeetingInAStateItMayNotChange() throws {
        typealias Outcome = MeetingFileRecord.Outcome
        struct State {
            var name: String
            var outcome: Outcome = .finished(protocolExpected: true)
            var live: JobState?
            var exportRunning = false
            var pending = false
        }
        var states = [JobState.waiting, .transcribing, .diarizing, .generatingProtocol, .speakerNamingPending, .error].map { state in
            State(name: "a job \(state.rawValue)", live: state)
        }
        states += [
            State(name: "a Notion export running", live: .done, exportRunning: true),
            State(name: "another deletion pending", pending: true),
            State(name: "a failed meeting", outcome: .failed),
            State(name: "a meeting in progress with no job here", outcome: .inProgress),
            State(name: "a meeting that left the queue", outcome: .leftUnfinished),
        ]
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        for state in states {
            var job = try harness.recordedMeeting()
            job.state = state.live ?? .done
            if state.exportRunning { job.beginNotionExport(speakerNames: [], localBackupSaved: true) }
            if state.live != nil { controller.queue.insertJobForTesting(job) }
            harness.store.update(jobID: job.id) { record in
                record.outcome = state.outcome
                record.incomplete = .init(reason: "earlier", paths: [], kind: .meetingToTrash)
                if state.pending {
                    record.pending = .init(kind: .audioToTrash, paths: [], process: .init(pid: 7, launchTime: .distantPast))
                }
            }
            let before = try harness.record(of: job)
            let files = try harness.paths(of: job)

            XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id), state.name)
            XCTAssertFalse(controller.moveMeetingToTrash(jobID: job.id), state.name)
            XCTAssertFalse(controller.retryDeletion(jobID: job.id), state.name)
            XCTAssertFalse(controller.setKeep(jobID: job.id, true), state.name)

            XCTAssertEqual(try harness.record(of: job), before, state.name)
            XCTAssertEqual(files.filter(harness.isOnDisk), files, state.name)
            XCTAssertEqual(harness.fakeTrash.moved, [], state.name)
            XCTAssertEqual(controller.queue.jobs.contains { $0.id == job.id }, state.live != nil, state.name)
            XCTAssertNotNil(harness.history.lookup(jobID: job.id), state.name)
        }
    }

    /// A2: a row finished before this version has no record to go by, and its
    /// files are never inferred from anywhere else.
    func testEveryActionRefusesAMeetingWithoutARecord() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        harness.store.remove(jobID: job.id)

        XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id))
        XCTAssertFalse(controller.moveMeetingToTrash(jobID: job.id))
        XCTAssertFalse(controller.retryDeletion(jobID: job.id))
        XCTAssertFalse(controller.setKeep(jobID: job.id, true))

        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertNotNil(harness.history.lookup(jobID: job.id))
        XCTAssertTrue(try harness.isOnDisk(XCTUnwrap(job.mixPath).path))
    }

    /// A4: Move Meeting is what an import has; its audio and Keep are not the app's.
    /// The 16 kHz copy is the app's own file, so only the origin refuses here.
    func testAudioAndKeepRefuseAnImport() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.importedMeeting()
        let copy = try createTestAudioFile(in: harness.recordings)
        harness.store.update(jobID: job.id) { $0.list(MeetingFile(role: .mix16k, url: copy, owned: true)) }
        let before = try harness.record(of: job)

        XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id))
        XCTAssertFalse(controller.setKeep(jobID: job.id, true))

        XCTAssertEqual(try harness.record(of: job), before)
        XCTAssertEqual(harness.fakeTrash.moved, [])
    }

    /// R4: no audio file left, so there is nothing for the action to be about, and
    /// the date of the earlier deletion must not move.
    func testMoveAudioRefusesWhenNoAudioIsLeft() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        XCTAssertTrue(controller.moveAudioToTrash(jobID: job.id))
        let before = try harness.record(of: job)

        XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id))

        XCTAssertEqual(try harness.record(of: job), before)
    }

    /// A half-deleted meeting has one way on. Finishing its audio here would drop
    /// the mark of what is still left of it.
    func testMoveAudioRefusesAMeetingWhoseOwnDeletionIsIncomplete() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        harness.fakeTrash.refusal = { _ in Refused() }
        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))
        let before = try harness.record(of: job)
        harness.fakeTrash.refusal = { _ in nil }

        XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id))

        XCTAssertEqual(try harness.record(of: job), before)
        XCTAssertEqual(harness.fakeTrash.moved, [])
    }

    func testAPendingWriteThatFailsMovesNothing() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let files = try harness.paths(of: job)
        let folder = harness.logDir.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        XCTAssertFalse(controller.moveAudioToTrash(jobID: job.id))
        XCTAssertFalse(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertEqual(files.filter(harness.isOnDisk), files)
        XCTAssertNotNil(harness.history.lookup(jobID: job.id))
    }

    /// Another build's write since this store last read the file counts.
    func testAnActionReadsTheRecordFileAgainBeforeItDecides() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let otherBuild = MeetingFileStore(path: harness.recordPath)
        otherBuild.update(jobID: job.id) { $0.pending = .init(kind: .audioToTrash, paths: [], process: .current) }
        XCTAssertNil(harness.store.record(for: job.id)?.pending, "test premise: this store has not read that write")

        XCTAssertFalse(controller.setKeep(jobID: job.id, true))
        XCTAssertFalse(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertEqual(harness.fakeTrash.moved, [])
    }

    // MARK: - Security scope

    func testAnActionRunsInsideTheScopeOfTheChosenFolderAndClosesIt() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        harness.settings.setCustomOutputDir(harness.outputDir)
        let root = try XCTUnwrap(harness.settings.customOutputDir, "test premise")
        let job = try harness.recordedMeeting()
        var openWhileMoving: [Int] = []
        harness.fakeTrash.beforeMove = { [scopes = harness.scopes] _ in
            openWhileMoving.append(scopes.opened.count - scopes.closed.count)
        }

        XCTAssertTrue(controller.moveAudioToTrash(jobID: job.id))

        XCTAssertEqual(harness.scopes.opened.map(\.path), [root.path], "opened on the resolved root")
        XCTAssertEqual(harness.scopes.closed.map(\.path), [root.path], "left open")
        XCTAssertEqual(openWhileMoving, [1, 1, 1])
    }

    /// `.fallback` names a folder the user never chose, with no scope to open;
    /// `.defaultLocation` needs none.
    func testNoScopeIsOpenedForTheDefaultFolderOrTheFallback() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        XCTAssertTrue(try controller.moveAudioToTrash(jobID: harness.recordedMeeting().id))
        harness.settings.customOutputDirBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        guard case .fallback = harness.settings.outputDirectoryResolution else {
            XCTFail("test premise: the bookmark must not resolve")
            return
        }
        XCTAssertTrue(try controller.moveAudioToTrash(jobID: harness.recordedMeeting().id))

        XCTAssertEqual(harness.scopes.opened, [])
    }
}
