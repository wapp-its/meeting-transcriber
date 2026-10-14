@testable import MeetingTranscriber
import XCTest

/// The menu bar icon pulses while a "meeting seems to have ended" countdown
/// runs (`AppState.meetingEndCountdownOverlay`). The loop state that says a
/// countdown runs is the open question's id, `WatchLoop.meetingEndQuestionID`,
/// not a deadline of its own: nil before a countdown, set while it runs, and
/// nil again after every way out of it, so the icon can neither miss a
/// countdown nor go on pulsing after one. Driven on `TestClock` through
/// `handleMeeting`, polling once a virtual second with a 10 s end grace and a
/// 30 s countdown: the signal goes at 5 s, the question goes up at 15 s and,
/// unanswered, runs out at 45 s.
@MainActor
final class WatchLoopMeetingEndDeadlineTests: XCTestCase {
    private final class SwitchableSignal: MeetingDetecting {
        var active = true

        func checkOnce() -> DetectedMeeting? {
            nil
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            active
        }

        func reset(appName _: String?) {}
    }

    private struct SleepFailure: Error {}

    /// Everything a loop under test talks to. `onTick` runs after every
    /// virtual second, before that second's poll, with the seconds since the
    /// clock started; it is handed the harness rather than capturing it, so
    /// no test builds a reference cycle.
    @MainActor
    private final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        static let countdownTitle = "Meeting seems to have ended"
        let clock = TestClock(start: start)
        let signal = SwitchableSignal()
        let notifier = RecordingNotifier()
        /// The long-silence question's setting; nil is off.
        var silenceAfter: TimeInterval?
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        /// Makes the sleep `onTick` just ran in throw.
        var sleepFails = false
        /// The recording under test, so `onTick` can cancel it.
        var run: Task<Void, any Error>?
        /// Whether a countdown ran before the poll at each second.
        private(set) var countdownOpen: [Int: Bool] = [:]
        private(set) weak var loop: WatchLoop?

        func makeLoop(maxDuration: TimeInterval) -> WatchLoop {
            let sleepProvider: (TimeInterval) async throws -> Void = { interval in
                await self.clock.sleep(for: interval)
                self.countdownOpen[Int(self.elapsed)] = self.loop?.meetingEndQuestionID != nil
                await self.onTick(self, self.elapsed)
                if self.sleepFails { throw SleepFailure() }
            }
            // A mix that does not exist, so a cut fails and touches no file.
            let recorder = MockRecorder()
            recorder.mixPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("countdown-\(UUID().uuidString)\(RecordingFileSuffix.mix)")
            let loop = WatchLoop(
                detector: signal,
                recorderFactory: { recorder },
                pollInterval: 1,
                endGracePeriod: 10,
                maxDuration: maxDuration,
                meetingEndCountdown: 30,
                speechActivity: { SpeechActivity(observedSince: Self.start, lastSpeechAt: nil) },
                silencePromptAfter: { self.silenceAfter },
                notifier: notifier,
                diagnostics: RecordingDiagnostics(),
                nowProvider: { self.clock.now },
                sleepProvider: sleepProvider,
            )
            self.loop = loop
            return loop
        }

        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(Self.start)
        }

        /// The ids of the countdown questions and of the silence questions asked.
        func questionIDs(countdown: Bool) -> [String] {
            notifier.meetingEndQuestions.filter { ($0.title == Self.countdownTitle) == countdown }.map(\.id)
        }

        /// Answer the first question of that kind the way a tap would.
        func answer(_ answer: MeetingEndAnswer, countdown: Bool) {
            if let id = questionIDs(countdown: countdown).first {
                notifier.answerMeetingEndQuestion(id, with: answer)
            }
        }

        /// Record `meeting` on `loop` and say how it ended.
        func record(_ meeting: DetectedMeeting, on loop: WatchLoop) async -> Result<Void, any Error>? {
            run = Task { try await loop.handleMeeting(meeting) }
            return await run?.result
        }

        /// Whether a countdown ran before each poll in `seconds`, leaving out
        /// any second the loop never slept to.
        func open(_ seconds: ClosedRange<Int>) -> [Bool] {
            seconds.compactMap { countdownOpen[$0] }
        }
    }

    /// One way out of the countdown, taken at 20 s unless it is the
    /// countdown's own end or the maximum length.
    private struct WayOut {
        let name: String
        var maxDuration: TimeInterval = 60
        /// The second the recording ends at.
        let endsAt: TimeInterval
        /// The question is gone but the recording runs on, to the maximum length.
        var runsOn = false
        var throwsError = false
        var act: @MainActor (Harness, TimeInterval) -> Void = { _, _ in }
    }

    private let meeting = DetectedMeeting(
        pattern: .zoom, windowTitle: "Weekly Sync", ownerName: "zoom.us", windowPID: 4242,
    )

    private var waysOut: [WayOut] {
        [
            WayOut(name: "signal back", endsAt: 61, runsOn: true) { h, t in if t == 20 { h.signal.active = true } },
            WayOut(name: "Keep recording", endsAt: 61, runsOn: true) { h, t in
                if t == 20 { h.answer(.keepRecording, countdown: true) }
            },
            WayOut(name: "Stop now", endsAt: 20) { h, t in if t == 20 { h.answer(.stopNow, countdown: true) } },
            WayOut(name: "expiry", endsAt: 45),
            WayOut(name: "maximum length", maxDuration: 30, endsAt: 31),
            WayOut(name: "Stop Recording", endsAt: 20) { h, t in if t == 20 { h.loop?.stopDetectedRecording() } },
            WayOut(name: "Stop Watching", endsAt: 20) { h, t in if t == 20 { h.run?.cancel() } },
            WayOut(name: "thrown error", endsAt: 20, throwsError: true) { h, t in if t == 20 { h.sleepFails = true } },
        ]
    }

    func testTheCountdownStateIsSetOnlyWhileItRunsAndClearedByEveryWayOut() async {
        for way in waysOut {
            let name = way.name
            let harness = Harness()
            harness.onTick = { h, t in
                if t == 5 { h.signal.active = false }
                way.act(h, t)
            }

            let loop = harness.makeLoop(maxDuration: way.maxDuration)
            let result = await harness.record(meeting, on: loop)

            switch result {
            case .success: XCTAssertFalse(way.throwsError, "\(name): ended without the error")
            case let .failure(error): XCTAssertTrue(way.throwsError && error is SleepFailure, "\(name): \(error)")
            case nil: XCTFail("\(name): never ran")
            }
            XCTAssertEqual(harness.elapsed, way.endsAt, "\(name): precondition: ended the named way")
            XCTAssertEqual(harness.questionIDs(countdown: true).count, 1, "\(name): precondition: one countdown")
            let before = 1 ... 15, running = 16 ... (way.runsOn ? 20 : Int(way.endsAt))
            XCTAssertEqual(harness.open(before), before.map { _ in false }, "\(name): set before the countdown")
            XCTAssertEqual(harness.open(running), running.map { _ in true }, "\(name): not set while it runs")
            if way.runsOn {
                let after = 21 ... Int(way.endsAt)
                XCTAssertEqual(harness.open(after), after.map { _ in false }, "\(name): still set after the question went")
            }
            XCTAssertNil(loop.meetingEndQuestionID, "\(name): still set after the recording ended")
        }
    }

    /// The long-silence question has no countdown, so nothing pulses while it
    /// is open. Its "Stop now" cannot end a running countdown, since the
    /// countdown going up takes the silence question back; answered just
    /// before the poll the countdown would go up at, it ends the recording
    /// there and no countdown opens.
    func testTheSilenceQuestionSetsNothingAndItsStopNowLeavesNothingSet() async {
        let harness = Harness()
        harness.silenceAfter = 12
        harness.onTick = { h, t in
            if t == 5 { h.signal.active = false }
            if t == 15 { h.answer(.stopNow, countdown: false) }
        }

        let loop = harness.makeLoop(maxDuration: 60)
        _ = await harness.record(meeting, on: loop)

        XCTAssertEqual(harness.questionIDs(countdown: false).count, 1, "precondition: the silence question went up at 12 s")
        XCTAssertEqual(harness.elapsed, 15, "precondition: its Stop now ended the recording")
        XCTAssertTrue(harness.questionIDs(countdown: true).isEmpty, "a countdown opened")
        XCTAssertEqual(harness.open(1 ... 15), (1 ... 15).map { _ in false })
        XCTAssertNil(loop.meetingEndQuestionID)
    }

    /// The icon's input follows the current loop's countdown, and is off with
    /// no loop.
    func testTheMenuBarIconsCountdownFlagFollowsTheLoop() async throws {
        let dir = try makeTempDirectory(prefix: "countdown-overlay")
        let suite = "WatchLoopMeetingEndDeadlineTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
            defaultOutputDir: dir.appendingPathComponent("output", isDirectory: true),
        )
        let state = AppState(
            settings: settings, notifier: SilentNotifier(), pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: dir),
        )
        XCTAssertFalse(state.meetingEndCountdownOverlay, "no loop")
        let harness = Harness()
        let loop = harness.makeLoop(maxDuration: 60)
        state.watching.watchLoop = loop
        var overlay: [Int: Bool] = [:]
        harness.onTick = { [weak state] h, t in
            if t == 5 { h.signal.active = false }
            overlay[Int(t)] = state?.meetingEndCountdownOverlay
        }

        _ = await harness.record(meeting, on: loop)

        XCTAssertEqual(harness.elapsed, 45, "precondition: the countdown ran out")
        XCTAssertEqual(Set(overlay.values), [false, true])
        XCTAssertEqual(overlay, harness.countdownOpen)
        XCTAssertFalse(state.meetingEndCountdownOverlay, "on after the countdown")
    }
}
