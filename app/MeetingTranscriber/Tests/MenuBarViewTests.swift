@testable import MeetingTranscriber

// swiftlint:disable file_length
import ViewInspector
import XCTest

@MainActor
// swiftlint:disable:next attributes type_body_length
final class MenuBarViewTests: XCTestCase {
    // MARK: - Helpers

    private func makeStatus(
        state: TranscriberState = .idle,
        detail: String = "",
        meeting: MeetingInfo? = nil,
        error: String? = nil,
    ) -> TranscriberStatus {
        TranscriberStatus(
            version: 1,
            timestamp: "2024-01-01T00:00:00",
            state: state,
            detail: detail,
            meeting: meeting,
            error: error,
            audioPath: nil,
            pid: nil,
        )
    }

    private func makeView(
        status: TranscriberStatus? = nil,
        isWatching: Bool = false,
        pipelineQueue: PipelineQueue? = nil,
        updateChecker: UpdateChecker? = nil,
        updateInstallBlockedReason: String? = nil,
        onInstallUpdate: (() -> Void)? = nil,
        onNameSpeakers: (() -> Void)? = nil,
        onStopManualRecording: (() -> Void)? = nil,
        onRecordMicrophone: @escaping () -> Void = {},
        noMic: Bool = false,
        manualRecordingPendingOrActive: Bool = false,
        onShowAllTranscriptions: @escaping () -> Void = {},
        onOpenProtocol: @escaping (URL) -> Void = { _ in },
        onOpenLastProtocol: @escaping (URL) -> Void = { _ in },
        history: [TerminalJobRecord] = [],
        isRecordingPaused: Bool = false,
        onTogglePause: (() -> Void)? = nil,
    ) -> MenuBarView {
        var actions = MenuActions.noop
        actions.installUpdate = onInstallUpdate
        actions.recordMicrophone = onRecordMicrophone
        actions.stopManualRecording = onStopManualRecording
        actions.togglePause = onTogglePause
        actions.openProtocol = onOpenProtocol
        actions.openLastProtocol = onOpenLastProtocol
        actions.nameSpeakers = onNameSpeakers
        actions.showAllTranscriptions = onShowAllTranscriptions
        return MenuBarView(
            status: status,
            isWatching: isWatching,
            pipelineQueue: pipelineQueue ?? PipelineQueue(),
            updateChecker: updateChecker,
            updateInstallBlockedReason: updateInstallBlockedReason,
            history: history,
            noMic: noMic,
            manualRecordingPendingOrActive: manualRecordingPendingOrActive,
            isRecordingPaused: isRecordingPaused,
            actions: actions,
        )
    }

    // MARK: - Start/Stop button

    func testIdleShowsStartWatching() throws {
        let sut = makeView(status: makeStatus(state: .idle), isWatching: false)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Start Watching for Meetings"))
    }

    func testWatchingShowsStopWatching() throws {
        let sut = makeView(status: makeStatus(state: .watching), isWatching: true)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Watching for Meetings"))
    }

    // MARK: - Meeting info

    func testMeetingInfoShownWhenRecording() throws {
        let meeting = MeetingInfo(app: "Teams", title: "Standup", pid: 123)
        let sut = makeView(status: makeStatus(state: .recording, meeting: meeting))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Standup"))
    }

    func testMeetingInfoHiddenWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Standup"))
    }

    // MARK: - Error display

    func testErrorShownWhenErrorState() throws {
        let sut = makeView(status: makeStatus(state: .error, error: "Python crashed"))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Python crashed"))
    }

    func testErrorHiddenWhenNotErrorState() throws {
        let sut = makeView(status: makeStatus(state: .recording, error: "stale error"))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "stale error"))
    }

    // MARK: - Name Speakers button

    func testNameSpeakersButtonShownWhenWaiting() throws {
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .waitingForSpeakerNames), onNameSpeakers: {})
        let item = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.nameSpeakersMenuItem)
        XCTAssertNoThrow(try item.find(text: "Name Speakers…"))
    }

    func testNameSpeakersButtonHiddenWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.nameSpeakersMenuItem))
    }

    // MARK: - Detail text

    func testDetailShownWhenNonEmpty() throws {
        let sut = makeView(status: makeStatus(state: .watching, detail: "Checking Teams..."))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Checking Teams..."))
    }

    func testDetailHiddenWhenEmpty() throws {
        let sut = makeView(status: makeStatus(state: .watching, detail: ""))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Checking Teams..."))
    }

    // MARK: - Protocol link

    private func finishedJob(_ state: JobState, protocolPath: String?, transcriptPath: String?) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Retro", appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = state
        job.protocolPath = protocolPath.map { URL(fileURLWithPath: $0) }
        job.transcriptPath = transcriptPath.map { URL(fileURLWithPath: $0) }
        return job
    }

    /// "Open Last Protocol" follows the finished-job history rather than the
    /// status file, so it is there for a job that has left the queue or
    /// finished before a restart, and it opens that job's protocol.
    func testOpenLastProtocolOpensTheLastFinishedJobsProtocol() throws {
        let finished = finishedJob(.done, protocolPath: "/tmp/Retro.md", transcriptPath: "/tmp/Retro.txt")
        var openedURL: URL?
        let body = try makeView(
            status: makeStatus(state: .idle),
            onOpenLastProtocol: { openedURL = $0 },
            history: [TerminalJobRecord(job: finished)],
        ).inspect()

        try body.find(viewWithAccessibilityIdentifier: A11yID.openLastProtocolMenuItem).button().tap()

        XCTAssertEqual(openedURL, URL(fileURLWithPath: "/tmp/Retro.md"))
    }

    /// No finished job, no item: a failed job does not count.
    func testOpenLastProtocolHiddenWithoutAFinishedJob() throws {
        let failed = finishedJob(.error, protocolPath: nil, transcriptPath: "/tmp/Retro.txt")
        let body = try makeView(
            status: makeStatus(state: .protocolReady),
            history: [TerminalJobRecord(job: failed)],
        ).inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.openLastProtocolMenuItem))
    }

    // MARK: - Static buttons always present

    func testSettingsButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Settings..."))
    }

    func testQuitButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Quit"))
    }

    // MARK: - Record Microphone (issue #633)

    func testRecordMicrophoneButtonShownWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let item = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordMicrophoneMenuItem)
        XCTAssertNoThrow(try item.find(text: "Record Microphone Only"))
    }

    func testRecordMicrophoneButtonCallsCallback() throws {
        var called = false
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .idle), onRecordMicrophone: { called = true })

        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordMicrophoneMenuItem).button().tap()

        XCTAssertTrue(called)
    }

    func testRecordMicrophoneButtonHiddenWhileRecording() throws {
        // Same rule as Record with Options…: the menu offers Stop Recording instead.
        let sut = makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.recordMicrophoneMenuItem))
    }

    func testRecordMicrophoneButtonDisabledWhenNoMicIsSet() throws {
        // Visible but dead, on purpose: someone who set "No Microphone" months
        // ago needs to see the entry to learn why it cannot run, and starting
        // anyway would record nothing.
        let sut = makeView(status: makeStatus(state: .idle), noMic: true)

        let button = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordMicrophoneMenuItem)
        XCTAssertTrue(button.isDisabled())
        XCTAssertEqual(try button.help().string(), MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason)
    }

    func testRecordMicrophoneButtonDisabledWhileAManualStartIsStillInFlight() throws {
        // The window between registering a start and the loop existing. The
        // narrow `state == .recording` predicate misses it, leaving the item
        // enabled and the click silently dropped by the ownership guard.
        let sut = makeView(status: makeStatus(state: .idle), manualRecordingPendingOrActive: true)

        let button = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordMicrophoneMenuItem)
        XCTAssertTrue(button.isDisabled())
        XCTAssertEqual(try button.help().string(), MicrophoneRecordingAvailability.recordingActive.disabledReason)
    }

    func testRecordMicrophoneButtonEnabledWhenTheMicrophoneIsAllowed() throws {
        // Control for the assertion above: without it a button that was always
        // disabled would pass just as well.
        let sut = makeView(status: makeStatus(state: .idle), noMic: false)

        let button = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordMicrophoneMenuItem)
        XCTAssertFalse(button.isDisabled())
        XCTAssertEqual(try button.help().string(), "Record the system microphone, with no app audio")
    }

    // MARK: - Button tap callbacks

    func testStartStopButtonCallsCallback() throws {
        var called = false
        var actions = MenuActions.noop
        actions.startStop = { called = true }
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let body = try sut.inspect()
        try body.find(button: "Start Watching for Meetings").tap()
        XCTAssertTrue(called)
    }

    func testQuitButtonCallsCallback() throws {
        var called = false
        var actions = MenuActions.noop
        actions.quit = { called = true }
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let body = try sut.inspect()
        try body.find(button: "Quit").tap()
        XCTAssertTrue(called)
    }

    func testSettingsButtonCallsCallback() throws {
        var called = false
        var actions = MenuActions.noop
        actions.openSettings = { called = true }
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let body = try sut.inspect()
        try body.find(button: "Settings...").tap()
        XCTAssertTrue(called)
    }

    func testNameSpeakersButtonCallsCallback() throws {
        var called = false
        var actions = MenuActions.noop
        actions.nameSpeakers = { called = true }
        let sut = MenuBarView(
            status: makeStatus(state: .waitingForSpeakerNames),
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let body = try sut.inspect()
        try body.find(viewWithAccessibilityIdentifier: A11yID.nameSpeakersMenuItem).button().tap()
        XCTAssertTrue(called)
    }

    /// The way into the All Recordings window is there whatever else the menu
    /// shows: while recording with a job line above it, and idle with none.
    func testAllRecordingsItemIsAlwaysShownAndCallsItsCallback() throws {
        let queue = PipelineQueue()
        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .error
        queue.insertJobForTesting(job)
        let recording = try makeView(status: makeStatus(state: .recording), pipelineQueue: queue).inspect()
        XCTAssertNoThrow(try recording.find(viewWithAccessibilityIdentifier: A11yID.allRecordingsMenuItem))

        var called = false
        // swiftlint:disable:next trailing_closure
        let item = try makeView(status: makeStatus(state: .idle), onShowAllTranscriptions: { called = true })
            .inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.allRecordingsMenuItem)
        XCTAssertNoThrow(try item.find(text: "All Recordings…"))
        try item.button().tap()
        XCTAssertTrue(called)
    }

    /// Regenerating moved into the All Recordings window, on a row and in its
    /// toolbar, so the menu has no item for it, finished recording or not.
    func testTheMenuHasNoRegenerateProtocolItem() throws {
        var finished = PipelineJob(
            meetingTitle: "Standup", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        finished.state = .done
        finished.protocolPath = URL(fileURLWithPath: "/tmp/standup.md")
        let views = [
            makeView(status: makeStatus(state: .idle)),
            makeView(status: makeStatus(state: .idle), history: [TerminalJobRecord(job: finished)]),
        ]

        for view in views {
            let body = try view.inspect()
            XCTAssertNoThrow(try body.find(text: "All Recordings…"), "the Recordings section is searched")
            XCTAssertThrowsError(try body.find(text: "Regenerate Protocol…"))
        }
    }

    // MARK: - State label

    func testNilStatusShowsIdleLabel() throws {
        let sut = makeView(status: nil)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Idle"))
    }

    func testMeetingAppAndPidShown() throws {
        let meeting = MeetingInfo(app: "Zoom", title: "Retro", pid: 456)
        let sut = makeView(status: makeStatus(state: .recording, meeting: meeting))
        let body = try sut.inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.contains("Zoom") == true }
        XCTAssertTrue(found, "App name 'Zoom' should appear in meeting info")
    }

    // MARK: - Job sections

    func testJobSectionsHiddenWhenNoJobs() throws {
        let body = try makeView(status: makeStatus()).inspect()
        XCTAssertThrowsError(try body.find(text: "In progress"))
        XCTAssertThrowsError(try body.find(text: "Needs you"))
    }

    /// A running job sits under "In progress" with its stage and when that
    /// stage started, not a counting elapsed time.
    func testRunningJobIsShownInProgressWithItsStage() throws {
        let queue = PipelineQueue()
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .transcribing)

        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()

        XCTAssertNoThrow(try body.find(text: "In progress"))
        XCTAssertNoThrow(try body.find(text: "Standup"))
        XCTAssertNoThrow(try body.find { value, _ in value.hasPrefix("Transcribing · since ") })
    }

    /// A failed line opens what the job left and has no Dismiss: Remove takes
    /// it off for good.
    func testFailedJobOffersOpenAndNoDismiss() throws {
        let queue = PipelineQueue()
        var job = PipelineJob(
            meetingTitle: "Retro",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        let transcriptURL = URL(fileURLWithPath: "/tmp/Retro.txt")
        job.transcriptPath = transcriptURL
        job.state = .error
        queue.insertJobForTesting(job)

        var openedURL: URL?
        // swiftlint:disable:next trailing_closure
        let body = try makeView(status: makeStatus(), pipelineQueue: queue, onOpenProtocol: { openedURL = $0 }).inspect()

        XCTAssertNoThrow(try body.find(text: "Needs you"))
        XCTAssertThrowsError(try body.find(button: "Dismiss"))
        try body.find(button: "Open").tap()
        XCTAssertEqual(openedURL, transcriptURL)
    }

    func testImportFilesItemCallsCallback() throws {
        var called = false
        var actions = MenuActions.noop
        actions.processFiles = { called = true }
        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let item = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.importFilesMenuItem)
        XCTAssertNoThrow(try item.find(text: "Import Audio/Video Files…"))
        try item.button().tap()
        XCTAssertTrue(called)
    }

    /// Dismiss stays on a job waiting for speaker names, the one line it is
    /// left on, next to Name Speakers.
    func testDismissButtonCallsCallbackWithJobID() throws {
        let queue = PipelineQueue()
        var job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .speakerNamingPending
        queue.insertJobForTesting(job)

        var dismissedID: UUID?
        var actions = MenuActions.noop
        actions.dismissJob = { dismissedID = $0 }
        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Name Speakers"))
        try body.find(button: "Dismiss").tap()
        XCTAssertEqual(dismissedID, job.id)
    }

    /// A failed line offers Remove instead of Dismiss.
    func testRemoveButtonShownForErrorJob() throws {
        let queue = PipelineQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Webex",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Failed")

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: .noop,
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Remove"))
        XCTAssertThrowsError(try body.find(button: "Dismiss"))
        XCTAssertNoThrow(try body.find(text: "Failed"))
    }

    /// Retry is the only way to run a failed job again without importing its
    /// audio by hand. The queue has its own logDir: the default one is the
    /// app's real data folder.
    ///
    /// Each row carries its own identifier, so the second row's button retries
    /// the second job and leaves the first alone.
    func testRetryButtonRequeuesTheJobOfItsOwnRow() throws {
        let dir = try makeTempDirectory(prefix: "menubar_retry_test")
        let queue = PipelineQueue(logDir: dir)
        let first = try queue.insertJobForTesting(mixPath: emptyFile("first_mix.wav", in: dir), state: .error, error: "Failed")
        let second = try queue.insertJobForTesting(mixPath: emptyFile("second_mix.wav", in: dir), state: .error, error: "Failed")

        let sut = makeView(status: makeStatus(), pipelineQueue: queue)
        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.jobRetryButton(1))
            .button()
            .tap()

        XCTAssertEqual(queue.jobs.first { $0.id == second }?.state, .waiting, "Retry did not requeue its own row's job")
        XCTAssertEqual(queue.jobs.first { $0.id == first }?.state, .error, "Retry requeued another row's job")
    }

    /// The button follows the queue's own check rather than the job's state,
    /// so it is absent for a failed job the queue would refuse to retry. The
    /// full set of refusals is covered on the queue; this is the one case a
    /// button keyed on the state alone would get wrong.
    func testRetryButtonIsAbsentForAFailedJobTheQueueWouldRefuse() throws {
        let dir = try makeTempDirectory(prefix: "menubar_retry_absent_test")
        let queue = PipelineQueue(logDir: dir)
        let mixPath = try emptyFile("shared_mix.wav", in: dir)
        queue.insertJobForTesting(mixPath: mixPath, state: .transcribing)
        queue.insertJobForTesting(mixPath: mixPath, state: .error, error: "This recording is already being processed")

        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()

        XCTAssertThrowsError(
            try body.find(viewWithAccessibilityIdentifier: A11yID.jobRetryButton(1)),
            "Retry offered while another job is still transcribing the same recording",
        )
    }

    private func emptyFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    // MARK: - Record with Options button

    func testRecordAppButtonExistsWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let item = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordWithOptionsMenuItem)
        XCTAssertNoThrow(try item.find(text: "Record with Options…"))
    }

    func testRecordAppButtonHiddenDuringRecording() throws {
        let sut = makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.recordWithOptionsMenuItem))
    }

    func testRecordAppButtonCallsCallback() throws {
        var called = false
        var actions = MenuActions.noop
        actions.recordApp = { called = true }
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let body = try sut.inspect()
        try body.find(viewWithAccessibilityIdentifier: A11yID.recordWithOptionsMenuItem).button().tap()
        XCTAssertTrue(called)
    }

    // MARK: - Stop Recording button (manual)

    func testStopRecordingButtonVisibleDuringManualRecording() throws {
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .recording), onStopManualRecording: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingButtonHiddenWhenNoManualRecording() throws {
        let sut = makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingButtonCallsCallback() throws {
        var called = false
        var actions = MenuActions.noop
        actions.stopManualRecording = { called = true }
        let sut = MenuBarView(
            status: makeStatus(state: .recording),
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
        let body = try sut.inspect()
        try body.find(button: "Stop Recording").tap()
        XCTAssertTrue(called)
    }

    // MARK: - Pause / Resume Recording

    /// The one wiring test: found by its identifier, tapped, the callback ran;
    /// labelled by the pause state, on the line directly under Stop Recording.
    func testThePauseItemSitsUnderStopRecordingAndCallsItsCallback() throws {
        for (paused, label, other) in [(false, "Pause Recording", "Resume Recording"), (true, "Resume Recording", "Pause Recording")] {
            var toggles = 0
            let sut = makeView(
                status: makeStatus(state: .recording),
                onStopManualRecording: {},
                isRecordingPaused: paused,
                // swiftlint:disable:next trailing_closure
                onTogglePause: { toggles += 1 },
            )

            let item = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.pauseResumeRecording)
            XCTAssertNoThrow(try item.find(text: label), label)
            XCTAssertThrowsError(try item.find(text: other), label)
            let titles = try sut.inspect().findAll(ViewType.Button.self).map { try $0.find(ViewType.Text.self).string() }
            XCTAssertEqual(Array(titles.prefix(2)), ["Stop Recording", label])

            try item.button().tap()
            XCTAssertEqual(toggles, 1, label)
        }
    }

    func testThePauseItemIsAbsentWithoutACallback() throws {
        // swiftlint:disable:next trailing_closure
        let body = try makeView(status: makeStatus(state: .recording), onStopManualRecording: {}).inspect()

        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.pauseResumeRecording))
        XCTAssertThrowsError(try body.find(text: "Pause Recording"))
        XCTAssertThrowsError(try body.find(text: "Resume Recording"))
    }

    // MARK: - Update indicator

    func testUpdateIndicatorShownWhenUpdateAvailable() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())
        checker.availableUpdate = try ReleaseInfo(
            tagName: "v1.0.0",
            name: "Release v1.0.0",
            prerelease: false,
            htmlURL: XCTUnwrap(URL(string: "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0")),
            dmgURL: URL(string: "https://example.com/app.dmg"),
        )

        let sut = makeView(status: makeStatus(), updateChecker: checker)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Update Available: v1.0.0"))
    }

    func testUpdateIndicatorHiddenWhenNoUpdate() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())

        let sut = makeView(status: makeStatus(), updateChecker: checker)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Update Available:"))
    }

    func testUpdateIndicatorHiddenWhenNoChecker() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Update Available:"))
    }

    // MARK: - mt-update install item

    private static let buildSummary = "upstream 1a2b3c4 · wapp/main 5d6e7f8"
    /// A wired install callback, for tests that only need the item enabled.
    private static let wiredInstall: () -> Void = {}

    /// A checker in mt-update mode offering `summary`. No process runs, and
    /// the pending record would land in a throwaway defaults suite.
    private func makeMtUpdateChecker(summary: String? = buildSummary) throws -> UpdateChecker {
        let suite = "MenuBarViewTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let checker = try UpdateChecker(
            provider: MockUpdateProvider(),
            installer: MockMtUpdateInstaller(),
            pendingStore: PendingUpdateInstallStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite))),
        )
        checker.availableBuildSummary = summary
        return checker
    }

    private func installItem(in view: MenuBarView) throws -> InspectableView<ViewType.Button> {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.menuInstallUpdateButton)
            .find(ViewType.Button.self)
    }

    /// The one wiring test: found by its identifier, named after the build,
    /// tapped, the callback ran.
    func testInstallItemNamesTheBuildAndCallsTheInstallCallback() throws {
        var installs = 0
        // swiftlint:disable:next trailing_closure
        let sut = try makeView(status: makeStatus(), updateChecker: makeMtUpdateChecker(), onInstallUpdate: { installs += 1 })

        let item = try installItem(in: sut)
        XCTAssertNoThrow(try item.find(text: "Install Update: \(Self.buildSummary)"))
        XCTAssertFalse(item.isDisabled())
        try item.tap()

        XCTAssertEqual(installs, 1)
    }

    func testInstallItemIsDisabledWhileBlockedCheckingOrUnwired() throws {
        let rows: [(name: String, reason: String?, checking: Bool, callback: (() -> Void)?)] = [
            ("blocked", "Not available while meetings are being processed.", false, Self.wiredInstall),
            ("checking", nil, true, Self.wiredInstall),
            ("no callback", nil, false, nil),
        ]
        for row in rows {
            let checker = try makeMtUpdateChecker()
            checker.isChecking = row.checking
            let sut = makeView(
                status: makeStatus(), updateChecker: checker,
                updateInstallBlockedReason: row.reason, onInstallUpdate: row.callback,
            )

            XCTAssertTrue(try installItem(in: sut).isDisabled(), row.name)
        }
    }

    /// While mt-update runs the menu shows a line that cannot be clicked, and
    /// without a build on offer there is nothing to install.
    func testInstallingShowsAnInertLineAndNoBuildOffersNoItem() throws {
        let installing = try makeMtUpdateChecker()
        installing.installState = .installing(since: Date())
        let rows: [(name: String, checker: UpdateChecker, showsInstalling: Bool)] = try [
            ("installing", installing, true),
            ("no build", makeMtUpdateChecker(summary: nil), false),
        ]
        for row in rows {
            let body = try makeView(status: makeStatus(), updateChecker: row.checker, onInstallUpdate: Self.wiredInstall).inspect()

            XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.menuInstallUpdateButton), row.name)
            XCTAssertThrowsError(try body.find(button: "Installing Update…"), row.name)
            XCTAssertEqual((try? body.find(text: "Installing Update…")) != nil, row.showsInstalling, row.name)
        }
    }

    // MARK: - Import Files button

    func testImportFilesItemAlwaysExists() throws {
        for state in [TranscriberState.idle, .recording] {
            let body = try makeView(status: makeStatus(state: state)).inspect()
            XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.importFilesMenuItem), "\(state)")
        }
    }

    // MARK: - Error job display

    func testErrorJobShowsErrorMessage() throws {
        let queue = PipelineQueue()
        let job = PipelineJob(
            meetingTitle: "Broken",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Transcription failed")

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: .noop,
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Transcription failed"))
    }

    // MARK: - Record/Stop button mutual exclusion

    func testRecordAppAndStopBothHiddenDuringAutoRecording() throws {
        let sut = makeView(status: makeStatus(state: .recording), onStopManualRecording: nil)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.recordWithOptionsMenuItem))
        XCTAssertThrowsError(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingReplacesRecordAppButton() throws {
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .idle), onStopManualRecording: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Recording"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.recordWithOptionsMenuItem))
    }

    // MARK: - Job state labels

    func testWaitingJobShowsWaitingLabel() throws {
        let queue = PipelineQueue()
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)

        let sut = makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Waiting..."))
    }

    func testCancelButtonShownForWaitingJob() throws {
        let queue = PipelineQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)

        let sut = makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Cancel"))
    }

    func testCancelButtonHiddenForDoneJob() throws {
        let queue = PipelineQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let sut = makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(button: "Cancel"))
    }

    func testDoneJobWithoutPathsHidesOpenButton() throws {
        let queue = PipelineQueue()
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .done)

        let sut = makeView(status: makeStatus(), pipelineQueue: queue)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(button: "Open"))
    }

    // MARK: - All state labels shown

    func testAllTranscriberStateLabelsRendered() throws {
        let states: [TranscriberState] = [
            .idle, .watching, .recording, .transcribing,
            .generatingProtocol, .protocolReady, .error,
        ]
        for state in states {
            let sut = makeView(status: makeStatus(state: state))
            let body = try sut.inspect()
            XCTAssertNoThrow(
                try body.find(text: state.label),
                "State label '\(state.label)' not found for \(state)",
            )
        }
    }

    // MARK: - Multiple jobs

    func testMultipleJobsRendered() throws {
        let queue = PipelineQueue()
        let job1 = PipelineJob(
            meetingTitle: "Meeting 1",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix1.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let job2 = PipelineJob(
            meetingTitle: "Meeting 2",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix2.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job1)
        queue.enqueue(job2)

        let sut = MenuBarView(
            status: makeStatus(),
            isWatching: false,
            pipelineQueue: queue,
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: .noop,
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Meeting 1"))
        XCTAssertNoThrow(try body.find(text: "Meeting 2"))
    }
}
