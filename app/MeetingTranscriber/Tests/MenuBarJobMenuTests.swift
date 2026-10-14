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
            onOpenProtocol: { _ in },
            onOpenLastProtocol: { _ in },
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
    func testEachJobIsOneSubmenuWithoutRowLayoutParts() throws {
        let queue = PipelineQueue()
        for title in ["One", "Two", "Three", "Four"] {
            let job = makeJob(title)
            queue.enqueue(job)
            queue.updateJobState(id: job.id, to: .error, error: "Transcription failed")
        }

        let body = try makeView(pipelineQueue: queue).inspect()

        XCTAssertEqual(body.findAll(ViewType.Menu.self).count, 4)
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

    /// The work under way sits under "In progress", the jobs waiting on the
    /// user under "Needs you", and finished jobs are not in the menu at all.
    /// A header with no job under it is left out.
    func testJobsSitUnderInProgressAndNeedsYouAndFinishedOnesAreLeftOut() throws {
        let queue = PipelineQueue()
        queue.insertJobForTesting(makeJob("Running", state: .transcribing))
        queue.insertJobForTesting(makeJob("Queued"))
        queue.insertJobForTesting(makeJob("Unnamed", state: .speakerNamingPending))
        queue.insertJobForTesting(makeJob("Broken", state: .error))
        queue.insertJobForTesting(makeJob("Finished", state: .done))
        var warned = makeJob("Warned", state: .done)
        warned.warnings = ["Diarization failed"]
        queue.insertJobForTesting(warned)

        let body = try makeView(pipelineQueue: queue).inspect()

        XCTAssertNoThrow(try body.find(text: "In progress"))
        XCTAssertNoThrow(try body.find(text: "Needs you"))
        XCTAssertEqual(body.findAll(ViewType.Menu.self).count, 4)
        for line in ["Queued — Waiting...", "Unnamed — Speaker names needed", "Broken — Failed"] {
            XCTAssertNoThrow(try body.find(text: line), line)
        }
        for title in ["Finished", "Warned"] {
            XCTAssertThrowsError(try body.find(text: title), "\(title) finished, so it belongs to the window")
        }

        let needsYouOnly = PipelineQueue()
        needsYouOnly.insertJobForTesting(makeJob("Broken", state: .error))
        let onlyFailed = try makeView(pipelineQueue: needsYouOnly).inspect()
        XCTAssertNoThrow(try onlyFailed.find(text: "Needs you"))
        XCTAssertThrowsError(try onlyFailed.find(text: "In progress"), "a header shown with no job under it")
    }

    /// The line of a running job, and its submenu, read the same however
    /// much time passes and however often the history is reloaded: they
    /// change only at a job event, here the audio length becoming known. No
    /// live elapsed time and no "longer than usual" are left in the menu.
    func testARunningJobsLinesChangeOnlyAtAJobEvent() async throws {
        let dir = try makeTempDirectory(prefix: "menu_job_line")
        let log = StageTimingLog(path: dir.appendingPathComponent("stage_timing.jsonl"))
        await log.append([StageTimingEvent(
            ts: Date(), jobID: UUID(), stage: .transcribing,
            wallClockSeconds: 60, audioSeconds: 240, engine: nil, diarizerMode: nil,
        )])
        let queue = PipelineQueue(logDir: dir, stageTimingLog: log)
        await queue.reloadStageSpeeds()
        let job = makeJob("Standup")
        queue.insertJobForTesting(job)
        queue.updateJobState(id: job.id, to: .transcribing)

        let beforeAudio = try menuTexts(queue)
        XCTAssertTrue(beforeAudio.contains { $0.hasPrefix("Standup — Transcribing · since ") && !$0.contains("ready") })

        queue.recordAudioDuration(jobID: job.id, frames: 16000 * 600)
        let clock = try XCTUnwrap(queue.stageClock(forJobID: job.id))
        XCTAssertEqual(clock.expectedFinish, clock.startedAt.addingTimeInterval(150))
        let afterAudio = try menuTexts(queue)
        XCTAssertNotEqual(afterAudio, beforeAudio, "the audio length is a job event; the finish should appear")
        XCTAssertTrue(afterAudio.contains { $0.hasPrefix("Standup — Transcribing · since ") && $0.contains(" · ready about ") })

        try await Task.sleep(for: .milliseconds(1200))
        await log.append([StageTimingEvent(
            ts: Date(), jobID: UUID(), stage: .transcribing,
            wallClockSeconds: 600, audioSeconds: 60, engine: nil, diarizerMode: nil,
        )])
        await queue.reloadStageSpeeds()

        XCTAssertEqual(try menuTexts(queue), afterAudio)
        XCTAssertEqual(queue.stageClock(forJobID: job.id), clock)
        XCTAssertFalse(afterAudio.contains { $0.contains("longer than usual") || $0.contains("Ø") })
    }

    /// Every text in the menu, the job submenus' included, in order.
    private func menuTexts(_ queue: PipelineQueue) throws -> [String] {
        try makeView(pipelineQueue: queue).inspect().findAll(ViewType.Text.self).map { try $0.string() }
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

    /// A running stage reads `<stage> · since <start> · ready about <finish>`,
    /// in the system's short time format (fixed here to a Swiss locale), and
    /// without the last part while there is no expected finish. A finish on
    /// the next day shows its time only.
    func testARunningStagesLineReadsSinceAndReadyAbout() throws {
        let zurich = try XCTUnwrap(TimeZone(identifier: "Europe/Zurich"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zurich
        func at(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
        }
        func clock(_ stage: StageKind, from start: Date, to finish: Date?) -> StageClock {
            StageClock(config: StageConfig(stage: stage, engine: nil, diarizerMode: nil), startedAt: start, expectedFinish: finish)
        }
        let cases: [(JobState, StageClock?, String)] = try [
            (
                .transcribing,
                clock(.transcribing, from: at(14, 9, 17), to: at(14, 9, 21)),
                "Transcribing · since 09:17 · ready about 09:21",
            ),
            (.diarizing, clock(.diarizing, from: at(14, 9, 17), to: nil), "Diarizing · since 09:17"),
            (
                .generatingProtocol,
                clock(.generatingProtocol, from: at(14, 23, 58), to: at(15, 0, 3)),
                "Generating Protocol · since 23:58 · ready about 00:03",
            ),
            (.transcribing, nil, "Transcribing"),
        ]
        for (state, stageClock, line) in cases {
            XCTAssertEqual(
                JobMenuSummary.stageProgress(
                    state: state, clock: stageClock, locale: Locale(identifier: "de_CH"), timeZone: zurich,
                ),
                line,
            )
        }
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
