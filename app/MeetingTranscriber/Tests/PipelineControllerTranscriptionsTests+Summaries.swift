@testable import MeetingTranscriber
import XCTest

/// The summaries the controller keeps for All Recordings (spec R4, R7): the rows carry
/// the shown one, Save stores nothing for a meeting no longer listed, Move Meeting to
/// Trash drops them once its files went, and a launch drops those of meetings no list
/// holds. Every summary here is made up.
extension PipelineControllerTranscriptionsTests {
    private func notesSummary(_ text: String) -> MeetingSummaries {
        MeetingSummaries(notes: .init(text: text, writtenAt: MeetingDeletionHarness.now))
    }

    func testTheRowsCarryTheShownSummaryAndSaveStoresOnlyForAListedMeeting() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        controller.summaryStore.update(jobID: job.id) { _ in self.notesSummary("From the notes") }

        XCTAssertEqual(controller.transcriptionEntries.first { $0.id == job.id }?.summary, "From the notes")
        XCTAssertTrue(controller.saveTypedSummary(jobID: job.id, field: "Mine\n"))
        XCTAssertEqual(controller.transcriptionEntries.first { $0.id == job.id }?.summary, "Mine")

        let gone = UUID()
        XCTAssertFalse(controller.saveTypedSummary(jobID: gone, field: "Mine"), "a meeting moved to the Trash while the sheet was open")
        XCTAssertNil(controller.summaryStore.summaries(for: gone))
    }

    /// The queue's notes saves reach the summaries through the controller, only for a
    /// meeting the window lists.
    func testTheQueuesNotesSavesReachTheSummariesOfListedMeetings() throws {
        let harness = try makeDeletionHarness()
        let queue = harness.makeQueue()
        let controller = harness.controller(queue: queue)
        controller.configureCallbacks(on: queue)
        let job = try harness.recordedMeeting()

        queue.onNotesSaved?(job.id, .text("## Summary\nFrom the queue."), job.meetingTitle)
        queue.onNotesSaved?(UUID(), .text("## Summary\nUnlisted."), "Other")

        XCTAssertEqual(controller.summaryStore.summaries, [job.id: notesSummary("From the queue.")])
    }

    /// Regenerate Notes hands the notes it saved to the same place.
    func testAppStateHandsTheRegeneratorsNotesToTheSummaries() throws {
        let harness = try makeDeletionHarness()
        let job = try harness.recordedMeeting()
        let state = AppState(pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: harness.logDir), settings: harness.settings)

        state.protocolRegenerator.environment.notesReplaced(job.id, "## Summary\nFrom a regeneration.", job.meetingTitle)

        XCTAssertEqual(state.pipeline.summaryStore.summaries(for: job.id)?.notes?.text, "From a regeneration.")
    }

    /// Moving the meeting drops its summaries once its files went; a move the Trash
    /// refused keeps them, as Move Audio to Trash does.
    func testMoveMeetingDropsTheSummariesOnceItsFilesWent() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let (moved, refused, audioOnly) = try (harness.recordedMeeting(), harness.recordedMeeting(), harness.recordedMeeting())
        for job in [moved, refused, audioOnly] {
            controller.summaryStore.update(jobID: job.id) { _ in self.notesSummary(job.id.uuidString) }
        }
        let refusedFile = try XCTUnwrap(refused.appPath).lastPathComponent
        harness.fakeTrash.refusal = { $0.lastPathComponent == refusedFile ? CocoaError(.featureUnsupported) : nil }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: moved.id))
        XCTAssertTrue(controller.moveMeetingToTrash(jobID: refused.id))
        XCTAssertTrue(controller.moveAudioToTrash(jobID: audioOnly.id))

        XCTAssertNotNil(try harness.record(of: refused).incomplete, "test premise: the refused move is incomplete")
        let summaries = MeetingSummaryStore(path: harness.logDir.appendingPathComponent(MeetingSummaryStore.filename)).summaries
        XCTAssertEqual(Set(summaries.keys), [refused.id, audioOnly.id])
    }

    /// A launch keeps the summaries of meetings the finished-job list or the record
    /// file holds, and drops the rest.
    func testALaunchDropsTheSummariesOfMeetingsNoListHolds() throws {
        let harness = try makeDeletionHarness()
        let (listed, recordOnly, unknown) = try (harness.recordedMeeting(), UUID(), UUID())
        harness.store.create(MeetingFileRecord(jobID: recordOnly, origin: .recorded, recordingDate: MeetingDeletionHarness.now, files: []))
        let store = MeetingSummaryStore(path: harness.logDir.appendingPathComponent(MeetingSummaryStore.filename))
        for id in [listed.id, recordOnly, unknown] {
            store.update(jobID: id) { _ in self.notesSummary("Kept") }
        }
        let controller = harness.controller()

        controller.activate { nil }

        XCTAssertEqual(Set(controller.summaryStore.summaries.keys), [listed.id, recordOnly])
    }
}
