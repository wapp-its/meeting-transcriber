@testable import MeetingTranscriber
import XCTest

/// Pausing the recording in the watch loop: what pause and resume answer and
/// leave in the loop's state, that a paused recording ends like a running
/// one by every way a recording ends, and that its job carries the pauses.
/// Driven on `TestClock`, polling once a virtual second with a 10 s end grace
/// and the app's 2-minute countdown, so every timing below is exact and no
/// test waits in real time.
@MainActor
final class WatchLoopPauseTests: XCTestCase {
    private static let manualTitle = "Weekly sync"

    private let meeting = DetectedMeeting(
        pattern: .teams,
        windowTitle: "Quarterly Review | Microsoft Teams",
        ownerName: "Microsoft Teams",
        windowPID: 4242,
    )

    /// What one pause or resume answered and left in the loop's state.
    private struct Step: Equatable {
        let outcome: RecordingPauseOutcome
        let pausedSince: Date?
        let detail: String
    }

    /// The tick action of a table row: the harness, and the seconds since the
    /// clock started.
    private typealias Act = @MainActor (PauseHarness, TimeInterval) -> Void

    // MARK: - Helpers

    private func makeQueue() throws -> PipelineQueue {
        try PipelineQueue(logDir: makeTempDirectory(prefix: "pause-queue"))
    }

    /// Start a manual recording of a running app and wait until it has ended.
    private func recordManually(_ loop: WatchLoop) async throws {
        try await loop.startManualRecording(pid: 42, appName: "Zoom", title: Self.manualTitle)
        await waitFor(loop.state == .idle, timeout: .seconds(10))
        XCTAssertEqual(loop.state, .idle, "precondition: the recording ended")
    }

    /// Detect the meeting through the real watch loop and wait until watching
    /// has ended, which the harness does at the first poll after the stop.
    private func recordDetected(_ loop: WatchLoop, on harness: PauseHarness) async {
        harness.signal.detectable = meeting
        loop.start()
        await waitFor(harness.recorder.stopCalled && loop.state == .idle, timeout: .seconds(10))
        XCTAssertEqual(loop.state, .idle, "precondition: the recording ended")
    }

    private func pause(_ seconds: TimeInterval, _ end: TimeInterval, offset: TimeInterval) -> RecordingPause {
        RecordingPause(startedAt: PauseHarness.at(seconds), endedAt: PauseHarness.at(end), offsetSeconds: offset)
    }

    // MARK: - Pause and resume

    /// A running manual recording pauses and resumes once each, asked twice
    /// each time, and the status line follows. One line per change goes to
    /// the diagnostic log, the resume with how long it was paused, and none
    /// names the recording.
    func testPausingAndResumingAManualRecording() async throws {
        let harness = PauseHarness()
        harness.recorder.pauseOffsets = [10]
        let loop = try harness.makeLoop(queue: makeQueue())
        var steps: [Step] = []
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            let step = { (outcome: RecordingPauseOutcome) in
                steps.append(Step(outcome: outcome, pausedSince: loop.pausedSince, detail: loop.detail))
            }
            if t == 10 {
                step(loop.pauseRecording())
                step(loop.pauseRecording())
            }
            if t == 30 {
                step(loop.resumeRecording())
                step(loop.resumeRecording())
            }
            if t == 40 { loop.stopManualRecording() }
        }

        try await recordManually(loop)

        let paused = "Paused: \(Self.manualTitle)"
        let running = "Recording: \(Self.manualTitle)"
        XCTAssertEqual(steps, [
            Step(outcome: .changed, pausedSince: PauseHarness.at(10), detail: paused),
            Step(outcome: .unchanged, pausedSince: PauseHarness.at(10), detail: paused),
            Step(outcome: .changed, pausedSince: nil, detail: running),
            Step(outcome: .unchanged, pausedSince: nil, detail: running),
        ])
        XCTAssertEqual(harness.recorder.pauseCallCount, 1)
        XCTAssertEqual(harness.recorder.resumeCallCount, 1)
        XCTAssertEqual(harness.diagnostics.lines.map(\.line), ["recording_paused", "recording_resumed paused_s=20"])
    }

    /// Nothing to pause while nothing records, nor while a detected meeting is
    /// `.recording` before its recorder has started: nothing is called,
    /// logged or changed. A resume then changes nothing either.
    func testThereIsNothingToPauseWithoutARunningCapture() async throws {
        let harness = PauseHarness()
        let queue = try makeQueue()
        let loop = harness.makeLoop(queue: queue)
        XCTAssertEqual(loop.pauseRecording(), .nothingToPause, "nothing records")
        XCTAssertEqual(loop.resumeRecording(), .unchanged, "nothing records")
        var beforeCapture: (state: WatchLoop.State, canPause: Bool, outcome: RecordingPauseOutcome)?
        harness.onRecorderRequested = { h in
            guard let loop = h.loop else { return }
            beforeCapture = (loop.state, loop.canPause, loop.pauseRecording())
        }
        harness.onTick = { h, t in if t == 3 { h.loop?.stop() } }

        await recordDetected(loop, on: harness)

        XCTAssertEqual(beforeCapture?.state, .recording, "precondition: asked while the meeting was recording")
        XCTAssertEqual(beforeCapture?.canPause, false)
        XCTAssertEqual(beforeCapture?.outcome, .nothingToPause)
        XCTAssertEqual(harness.recorder.pauseCallCount, 0, "the recorder is not called")
        XCTAssertTrue(harness.diagnostics.lines(.notice, startingWith: "recording_paused").isEmpty)
        XCTAssertNil(try XCTUnwrap(queue.jobs.first).pauses, "the recording was never paused")
    }

    // MARK: - Every end while paused

    /// A manual recording paused at 10 s and never resumed ends by Stop
    /// Recording, by its app quitting, and at the maximum length, which counts
    /// the paused time; the job's pause ends at the stop, and the loop is no
    /// longer paused.
    func testAPausedManualRecordingEndsLikeARunningOne() async throws {
        let ends: [(name: String, maxDuration: TimeInterval, end: TimeInterval, act: Act)] = [
            ("Stop Recording", 3600, 30, { h, t in if t == 30 { h.loop?.stopManualRecording() } }),
            ("the app quits", 3600, 30, { h, t in if t == 30 { h.appAlive = false } }),
            ("the maximum length", 30, 31, { _, _ in }),
        ]
        for (name, maxDuration, end, act) in ends {
            let harness = PauseHarness()
            harness.recorder.pauseOffsets = [10]
            let queue = try makeQueue()
            let loop = harness.makeLoop(queue: queue, maxDuration: maxDuration)
            harness.onTick = { h, t in
                if t == 10 { _ = h.loop?.pauseRecording() }
                act(h, t)
            }

            try await recordManually(loop)

            XCTAssertEqual(queue.jobs.count, 1, name)
            XCTAssertEqual(queue.jobs.first?.pauses, [pause(10, end, offset: 10)], "\(name): the pause ends at the stop")
            XCTAssertNil(loop.pausedSince, name)
            XCTAssertFalse(loop.isPaused, name)
            XCTAssertFalse(harness.recorder.isPaused, name)
        }
    }

    /// A detected meeting paused at 5 s ends by Stop Watching and at the
    /// maximum length, which counts the paused time, the same way.
    func testAPausedDetectedMeetingEndsLikeARunningOne() async throws {
        let ends: [(name: String, maxDuration: TimeInterval, end: TimeInterval, act: Act)] = [
            ("Stop Watching", 3600, 30, { h, t in if t == 30 { h.loop?.stop() } }),
            ("the maximum length", 30, 31, { _, _ in }),
        ]
        for (name, maxDuration, end, act) in ends {
            let harness = PauseHarness()
            harness.recorder.pauseOffsets = [5]
            let queue = try makeQueue()
            let loop = harness.makeLoop(queue: queue, maxDuration: maxDuration)
            harness.onTick = { h, t in
                if t == 5 { _ = h.loop?.pauseRecording() }
                act(h, t)
            }

            await recordDetected(loop, on: harness)

            XCTAssertEqual(queue.jobs.count, 1, name)
            XCTAssertEqual(queue.jobs.first?.pauses, [pause(5, end, offset: 5)], "\(name): the pause ends at the stop")
            let left = harness.afterEnd ?? loop.snapshot
            XCTAssertNotEqual(left.phase, .recording, name)
            XCTAssertNil(left.pausedSince, "\(name): no longer paused")
            XCTAssertFalse(harness.recorder.isPaused, name)
            XCTAssertFalse(harness.diagnostics.lines.contains { $0.line.contains("Quarterly Review") }, "\(name): no line names the meeting")
        }
    }

    /// The signal goes away while the meeting is paused: the end grace and the
    /// question's countdown run as they would unpaused, a resume during the
    /// countdown does not answer it, and the job carries the pause. Where that
    /// pause ends against the countdown's cut is the cut's business.
    func testASignalLostWhilePausedStillEndsThroughGraceAndCountdown() async throws {
        let harness = PauseHarness()
        harness.recorder.pauseOffsets = [3]
        let queue = try makeQueue()
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            if t == 3 { _ = h.loop?.pauseRecording() }
            if t == 5 { h.signal.active = false }
            if t == 60 { _ = h.loop?.resumeRecording() }
        }

        await recordDetected(loop, on: harness)

        XCTAssertEqual(harness.notifier.meetingEndQuestions.count, 1, "asked once, at the end of the grace")
        XCTAssertEqual(
            harness.diagnostics.lines(.notice, startingWith: "recording_auto_stop"),
            ["recording_auto_stop trigger=auto reason=countdown_expired signal_absent_s=130"],
            "ends when the unanswered countdown runs out, as unpaused",
        )
        let pauses = try XCTUnwrap(queue.jobs.first?.pauses)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(pauses.map(\.startedAt), [PauseHarness.at(3)])
        XCTAssertEqual(pauses.map(\.offsetSeconds), [3])
    }

    /// "Keep recording" answers the question and nothing else: the recording
    /// stays paused until it is stopped by hand.
    func testKeepRecordingDoesNotResumeAPausedRecording() async throws {
        let harness = PauseHarness()
        harness.recorder.pauseOffsets = [3]
        let queue = try makeQueue()
        let loop = harness.makeLoop(queue: queue)
        var afterKeep: Step?
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            if t == 3 { _ = loop.pauseRecording() }
            if t == 5 { h.signal.active = false }
            if t == 20, let id = h.notifier.meetingEndQuestions.first?.id {
                h.notifier.answerMeetingEndQuestion(id, with: .keepRecording)
            }
            if t == 22 { afterKeep = Step(outcome: .unchanged, pausedSince: loop.pausedSince, detail: loop.detail) }
            if t == 40 { loop.stopDetectedRecording() }
        }

        await recordDetected(loop, on: harness)

        XCTAssertEqual(afterKeep, Step(outcome: .unchanged, pausedSince: PauseHarness.at(3), detail: "Paused: Quarterly Review"))
        XCTAssertEqual(harness.recorder.resumeCallCount, 0, "the recorder was never resumed")
        XCTAssertEqual(queue.jobs.first?.pauses, [pause(3, 40, offset: 3)], "paused until the stop")
    }

    // MARK: - The job's pauses

    /// Two pauses reach the job at the positions the capture measured. When
    /// the capture reports another number of positions, each is estimated
    /// from the wall clock (time since the capture started, minus the pauses
    /// before it) and a warning says so, naming nothing of the recording.
    func testThePausesReachTheJobAtTheCapturesPositionsOrTheWallClocks() async throws {
        let rows: [(name: String, captured: [TimeInterval], offsets: [TimeInterval], warnings: [String])] = [
            ("captured", [9.5, 19.5], [9.5, 19.5], []),
            ("another count", [9.5], [10, 20], ["recording_pause_offsets_fallback pauses=2 captured=1"]),
        ]
        for (name, captured, offsets, warnings) in rows {
            let harness = PauseHarness()
            harness.recorder.pauseOffsets = captured
            let queue = try makeQueue()
            let loop = harness.makeLoop(queue: queue)
            harness.onTick = { h, t in
                guard let loop = h.loop else { return }
                if t == 10 || t == 30 { _ = loop.pauseRecording() }
                if t == 20 || t == 35 { _ = loop.resumeRecording() }
                if t == 40 { loop.stopManualRecording() }
            }

            try await recordManually(loop)

            XCTAssertEqual(queue.jobs.count, 1, name)
            XCTAssertEqual(queue.jobs.first?.pauses, [pause(10, 20, offset: offsets[0]), pause(30, 35, offset: offsets[1])], name)
            XCTAssertEqual(harness.diagnostics.lines(.warning, startingWith: "recording_pause"), warnings, name)
        }
    }

    /// A recording that ends paused, then one never paused on the same loop:
    /// the second starts with an empty log, so its job carries no pauses.
    func testTheNextRecordingStartsWithAnEmptyPauseLog() async throws {
        let harness = PauseHarness()
        harness.recorder.pauseOffsets = [10]
        let queue = try makeQueue()
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            if t == 10 { _ = h.loop?.pauseRecording() }
            if t == 20 { h.loop?.stopManualRecording() }
        }
        try await recordManually(loop)
        harness.recorder.pauseOffsets = []
        harness.onTick = { h, t in if t == 50 { h.loop?.stopManualRecording() } }

        try await recordManually(loop)

        XCTAssertEqual(queue.jobs.map(\.pauses), [[pause(10, 20, offset: 10)], nil])
        XCTAssertTrue(harness.diagnostics.lines(.warning, startingWith: "recording_pause").isEmpty)
    }

    // MARK: - The long-silence question

    /// Paused time is not silence. With nothing heard and the question set to
    /// five minutes, an unpaused recording is asked at 300 s. Paused from
    /// 100 s to 1000 s it is not asked while paused, and the count restarts at
    /// the resume; paused and resumed between two polls, it restarts there.
    func testAPausedRecordingNeverReachesTheSilenceQuestion() async throws {
        let rows: [(name: String, pauseAt: TimeInterval?, resumeAt: TimeInterval?, askedAt: TimeInterval)] = [
            ("never paused", nil, nil, 300),
            ("paused through the silence", 100, 1000, 1300),
            ("paused between two polls", 200, 200, 500),
        ]
        for (name, pauseAt, resumeAt, askedAt) in rows {
            let harness = PauseHarness()
            harness.silenceAfter = 300
            let loop = try harness.makeLoop(queue: makeQueue())
            var firstAsked: TimeInterval?
            harness.onTick = { h, t in
                // A question asked at the poll before this tick.
                if firstAsked == nil, !h.notifier.meetingEndQuestions.isEmpty { firstAsked = t - 1 }
                if t == pauseAt { _ = h.loop?.pauseRecording() }
                if t == resumeAt { _ = h.loop?.resumeRecording() }
                if t == 1400 { h.loop?.stopManualRecording() }
            }

            try await recordManually(loop)

            XCTAssertEqual(firstAsked, askedAt, name)
        }
    }
}

/// Everything a loop under test talks to. `onTick` runs after every virtual
/// second, before that second's poll, with the seconds since the clock
/// started; `onRecorderRequested` runs when the loop asks for its recorder,
/// before the capture starts. Both are handed the harness rather than
/// capturing it, so no test builds a reference cycle.
///
/// At the first poll back in watching after the recording stopped, the
/// harness notes the loop's state and stops watching, so the meeting is not
/// recorded a second time.
@MainActor
private final class PauseHarness {
    /// A meeting signal the test switches; `checkOnce` reports the meeting
    /// only while `detectable` is set.
    final class Signal: MeetingDetecting {
        var active = true
        var detectable: DetectedMeeting?

        func checkOnce() -> DetectedMeeting? {
            detectable
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            active
        }

        func reset(appName _: String?) {}
    }

    static let start = Date(timeIntervalSince1970: 1_000_000)
    let clock = TestClock(start: start)
    let signal = Signal()
    let notifier = RecordingNotifier()
    let diagnostics = RecordingDiagnostics()
    let recorder: MockRecorder
    var appAlive = true
    /// The long-silence question's setting; nil is switched off.
    var silenceAfter: TimeInterval?
    var onTick: @MainActor (PauseHarness, TimeInterval) -> Void = { _, _ in }
    var onRecorderRequested: @MainActor (PauseHarness) -> Void = { _ in }
    /// The loop's state at the first poll back in watching after the stop.
    private(set) var afterEnd: WatchLoopState?
    private(set) weak var loop: WatchLoop?

    init() {
        recorder = MockRecorder()
        // Never written: a cut of it fails and keeps the recording, as the
        // meeting-end tests show. Unique, so no other test's file is touched.
        recorder.mixPath = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID().uuidString)_mix.wav")
    }

    static func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func makeLoop(queue: PipelineQueue, maxDuration: TimeInterval = 3600) -> WatchLoop {
        let sleepProvider: (TimeInterval) async -> Void = { interval in
            await self.clock.sleep(for: interval)
            if self.recorder.stopCalled, self.afterEnd == nil, let loop = self.loop, loop.state == .watching {
                self.afterEnd = loop.snapshot
                loop.stop()
                return
            }
            self.onTick(self, self.clock.now.timeIntervalSince(Self.start))
        }
        let recorderFactory: @MainActor () async -> any RecordingProvider = {
            self.onRecorderRequested(self)
            return self.recorder
        }
        // Nothing is ever heard, counted from the start.
        let speechActivity = { SpeechActivity(observedSince: Self.start, lastSpeechAt: nil) }
        let appAlive: (pid_t) -> Bool = { _ in self.appAlive }
        let loop = WatchLoop(
            detector: signal,
            recorderFactory: recorderFactory,
            pipelineQueue: queue,
            pollInterval: 1,
            endGracePeriod: 10,
            maxDuration: maxDuration,
            recordWithoutAskingApps: { ["Microsoft Teams"] },
            speechActivity: speechActivity,
            silencePromptAfter: { self.silenceAfter },
            notifier: notifier,
            diagnostics: diagnostics,
            nowProvider: { self.clock.now },
            sleepProvider: sleepProvider,
            pidAliveCheck: appAlive,
        )
        loop.permissionChecker = { .allHealthy }
        self.loop = loop
        return loop
    }
}
