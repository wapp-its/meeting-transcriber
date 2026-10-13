@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The menu bar menu shows one line per job, with the job's actions in a
/// submenu, and names what each record item actually records.
@MainActor
final class MenuBarJobMenuTests: XCTestCase {
    private func makeView(
        pipelineQueue: PipelineQueue = PipelineQueue(),
        history: [TerminalJobRecord] = [],
        noMic: Bool = false,
        onRemoveFailedJob: @escaping (UUID) -> Void = { _ in },
    ) -> MenuBarView {
        MenuBarView(
            status: nil,
            isWatching: false,
            pipelineQueue: pipelineQueue,
            updateChecker: nil,
            history: history,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: noMic,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onRemoveFailedJob: onRemoveFailedJob,
            onDismissJob: { _ in },
            onQuit: {},
        )
    }

    private func makeJob(_ title: String, state: JobState = .waiting) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: title,
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/\(title)_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = state
        return job
    }

    // MARK: - Record items

    func testRecordAppLabelSaysTheMicrophoneIsRecordedToo() {
        XCTAssertEqual(MenuBarView.recordAppLabel(noMic: false), "Record App + Microphone...")
        XCTAssertEqual(MenuBarView.recordAppLabel(noMic: true), "Record App Audio...")
    }

    func testRecordAppItemFollowsTheNoMicrophoneSetting() throws {
        let body = try makeView(noMic: true).inspect()
        XCTAssertNoThrow(try body.find(text: "Record App Audio..."))
        XCTAssertThrowsError(try body.find(text: "Record App + Microphone..."))
    }

    // MARK: - Job lines

    /// Four failed jobs took four lines each, plus empty ones, when a job row
    /// was an `HStack`: the menu turns every part of a row into its own item.
    /// The menu keeps only the three jobs that finished last, so the four
    /// failed ones give three lines.
    func testEachJobIsOneSubmenuWithoutRowLayoutParts() throws {
        let queue = PipelineQueue()
        for title in ["One", "Two", "Three", "Four"] {
            let job = makeJob(title)
            queue.enqueue(job)
            queue.updateJobState(id: job.id, to: .error, error: "Transcription failed")
        }

        let body = try makeView(pipelineQueue: queue).inspect()

        XCTAssertEqual(body.findAll(ViewType.Menu.self).count, 3)
        XCTAssertTrue(body.findAll(ViewType.Spacer.self).isEmpty, "a Spacer becomes an empty menu line")
        XCTAssertNoThrow(try body.find(text: "Three — Failed"))
    }

    /// A failed job is taken off the menu by Remove, which also takes it out
    /// of the history; Dismiss is left to a job waiting for speaker names.
    func testAJobsActionsAndFullErrorSitInItsSubmenu() throws {
        let queue = PipelineQueue()
        let job = makeJob("Broken")
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Transcription failed")

        let menu = try makeView(pipelineQueue: queue).inspect().find(ViewType.Menu.self)

        XCTAssertNoThrow(try menu.find(text: "Transcription failed"))
        XCTAssertNoThrow(try menu.find(button: "Remove"))
        XCTAssertThrowsError(try menu.find(button: "Dismiss"))
    }

    /// The menu lists the work in flight and only the three jobs that
    /// finished last, so it no longer grows with every finished recording.
    func testOneRunningAndFiveDoneJobsGiveFourLines() throws {
        let queue = PipelineQueue()
        queue.insertJobForTesting(makeJob("Running", state: .transcribing))
        for number in 1 ... 5 {
            queue.insertJobForTesting(makeJob("Done \(number)", state: .done))
        }

        let body = try makeView(pipelineQueue: queue).inspect()

        XCTAssertEqual(body.findAll(ViewType.Menu.self).count, 4)
        XCTAssertNoThrow(try body.find(text: "Running"))
        for title in ["Done 3", "Done 4", "Done 5"] {
            XCTAssertNoThrow(try body.find(text: "\(title) — Done"), "\(title) finished among the last three")
        }
        for title in ["Done 1", "Done 2"] {
            XCTAssertThrowsError(try body.find(text: "\(title) — Done"), "\(title) finished before the last three")
        }
    }

    /// After a restart a failed job is known only from the history until the
    /// pipeline loads it: its line says why it failed and offers Remove, but
    /// no Retry, which the queue would refuse for a job it does not hold.
    func testAFailedJobKnownOnlyFromTheHistoryOffersRemoveButNoRetry() throws {
        let id = UUID()
        let record = TerminalJobRecord(status: JobStatusDTO(
            jobID: id.uuidString, state: .error, meetingTitle: "Lost", transcriptPath: nil, protocolPath: nil,
            error: "Audio file missing", warnings: [],
        ))
        var removedID: UUID?

        // swiftlint:disable:next trailing_closure
        let menu = try makeView(history: [record], onRemoveFailedJob: { removedID = $0 })
            .inspect()
            .find(ViewType.Menu.self)

        XCTAssertNoThrow(try menu.find(text: "Audio file missing"))
        XCTAssertThrowsError(try menu.find(viewWithAccessibilityIdentifier: A11yID.jobRetryButton(0)))
        try menu.find(viewWithAccessibilityIdentifier: A11yID.jobRemoveButton(0)).button().tap()
        XCTAssertEqual(removedID, id)
    }

    // MARK: - Summary

    func testStatusIsShortForEveryState() {
        var job = makeJob("Standup")
        let expected: [(JobState, String)] = [
            (.waiting, "Waiting..."),
            (.transcribing, "Transcribing... 1:05"),
            (.diarizing, "Transcribing... 1:05"),
            (.generatingProtocol, "Transcribing... 1:05"),
            (.speakerNamingPending, "Speaker names needed"),
            (.done, "Done"),
            (.error, "Failed"),
        ]
        for (state, status) in expected {
            job.state = state
            XCTAssertEqual(JobMenuSummary.status(of: job, progress: "Transcribing... 1:05"), status, "\(state)")
        }
        job.state = .done
        job.warnings = ["Diarization failed"]
        XCTAssertEqual(JobMenuSummary.status(of: job, progress: ""), "Done, with warnings")
    }

    func testEveryStateHasItsOwnSymbol() {
        var job = makeJob("Standup")
        var symbols: Set<String> = []
        for state in [JobState.waiting, .transcribing, .diarizing, .generatingProtocol, .speakerNamingPending, .done, .error] {
            job.state = state
            symbols.insert(JobMenuSummary.symbol(of: job))
        }
        XCTAssertEqual(symbols.count, 7)
    }
}
