@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// The open "Meeting seems to have ended" question as a value
/// (`WatchLoop.meetingEndQuestion`), for code outside its notification: the
/// text that was posted, the deadline the loop's countdown ends the recording
/// at, set while that countdown runs and nil after every way out of it, and
/// answered through the notifier only while it is the open one. Driven on
/// `TestClock` through `handleMeeting` against the real `NotificationManager`,
/// polling once a virtual second with a 10 s end grace and a 30 s countdown:
/// the signal goes at 5 s, the question goes up at 15 s and, unanswered, runs
/// out at 45 s.
@MainActor
final class WatchLoopMeetingEndQuestionTests: XCTestCase {
    /// A meeting signal, with the calls behind it for the new-call way out.
    private final class Signal: MeetingDetecting {
        var active = true
        var calls = ActiveCalls.unidentified

        func checkOnce() -> DetectedMeeting? {
            nil
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            active
        }

        func activeCalls(_: DetectedMeeting) -> ActiveCalls {
            calls
        }

        func reset(appName _: String?) {}
    }

    /// Answers whatever it is asked to and records it, so only the loop can
    /// refuse a question that is not the open one.
    private final class AnsweringNotifier: AppNotifying {
        private(set) var answers: [(id: String, answer: MeetingEndAnswer)] = []

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        @MainActor
        func answerMeetingEndQuestion(id: String, answer: MeetingEndAnswer) -> Bool {
            answers.append((id, answer))
            return true
        }
    }

    /// Everything a loop under test talks to. `onTick` runs after every
    /// virtual second, before that second's poll, with the seconds since the
    /// clock started; it is handed the harness rather than capturing it, so
    /// no test builds a reference cycle.
    @MainActor
    private final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: start)
        let signal = Signal()
        let scheduler: FakeNotificationScheduler
        let notifier: NotificationManager
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        /// The recording under test, so `onTick` can cancel it.
        var run: Task<MeetingEndReason, any Error>?
        /// What each answer given through the loop returned.
        private(set) var answered: [Bool] = []
        /// The loop's open question before the poll at each second.
        private(set) var openBeforePoll: [Int: MeetingEndQuestion?] = [:]
        private(set) weak var loop: WatchLoop?

        init() {
            let scheduler = FakeNotificationScheduler()
            let canDeliver: @Sendable () -> Bool = { true }
            let notifier = NotificationManager(scheduler: scheduler, canDeliver: canDeliver)
            notifier.setUp()
            self.scheduler = scheduler
            self.notifier = notifier
        }

        func makeLoop(maxDuration: TimeInterval = 60) -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
                self.openBeforePoll.updateValue(self.loop?.meetingEndQuestion, forKey: Int(self.elapsed))
                await self.onTick(self, self.elapsed)
            }
            // A mix that does not exist, so a cut fails and touches no file.
            let recorder = MockRecorder()
            recorder.mixPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("countdown-question-\(UUID().uuidString)\(RecordingFileSuffix.mix)")
            let loop = WatchLoop(
                detector: signal,
                recorderFactory: { recorder },
                pollInterval: 1,
                endGracePeriod: 10,
                maxDuration: maxDuration,
                meetingEndCountdown: 30,
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

        /// The meeting-end notifications posted, in order.
        var postedQuestions: [UNNotificationRequest] {
            scheduler.added.filter { $0.content.categoryIdentifier == NotificationManager.meetingEndCategoryID }
        }

        /// Record `meeting` on `loop` until its recording ends.
        func record(_ meeting: DetectedMeeting, on loop: WatchLoop) async {
            run = Task { try await loop.handleMeeting(meeting) }
            _ = await run?.result
        }

        /// Answer the open question the way the prompt window does: through
        /// the loop, by the question it read.
        func answerOpenQuestion(_ answer: MeetingEndAnswer) {
            guard let loop, let question = loop.meetingEndQuestion else { return }
            answered.append(loop.answerMeetingEndQuestion(question, answer: answer))
        }

        /// The open question before each poll in `seconds`, leaving out any
        /// second the loop never slept to.
        func open(_ seconds: ClosedRange<Int>) -> [MeetingEndQuestion?] {
            seconds.compactMap { openBeforePoll[$0] }
        }

        /// The open question before the poll at `second`.
        func open(at second: Int) -> MeetingEndQuestion? {
            openBeforePoll[second].flatMap(\.self)
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
        var act: @MainActor (Harness, TimeInterval) -> Void = { _, _ in }
    }

    private let meeting = DetectedMeeting(
        pattern: .zoom, windowTitle: "Weekly Sync", ownerName: "zoom.us", windowPID: 4242,
    )

    private var waysOut: [WayOut] {
        [
            WayOut(name: "signal back", endsAt: 61, runsOn: true) { h, t in if t == 20 { h.signal.active = true } },
            WayOut(name: "Keep recording", endsAt: 61, runsOn: true) { h, t in
                if t == 20 { h.answerOpenQuestion(.keepRecording) }
            },
            WayOut(name: "Stop now", endsAt: 20) { h, t in if t == 20 { h.answerOpenQuestion(.stopNow) } },
            WayOut(name: "expiry", endsAt: 45),
            WayOut(name: "cap", maxDuration: 30, endsAt: 31),
            WayOut(name: "a new call", endsAt: 20) { h, t in if t == 20 { h.signal.calls = .ids(["call-2"]) } },
            WayOut(name: "a stop by hand", endsAt: 20) { h, t in if t == 20 { h.loop?.stopDetectedRecording() } },
            WayOut(name: "Stop Watching", endsAt: 20) { h, t in if t == 20 { h.run?.cancel() } },
        ]
    }

    private func makeQuestion() -> MeetingEndQuestion {
        MeetingEndQuestion(
            id: UUID().uuidString, app: "Zoom", title: "Meeting seems to have ended", body: "No sign of the Zoom call.",
            deadline: Harness.start,
        )
    }

    /// What a window shows is what the notification shows, and it counts down
    /// to the deadline the loop ends the recording at.
    func testTheQuestionIsWhatWasPostedWithTheDeadlineTheLoopEnforces() async throws {
        let harness = Harness()
        harness.onTick = { h, t in if t == 5 { h.signal.active = false } }
        let loop = harness.makeLoop()

        await harness.record(meeting, on: loop)

        let posted = try XCTUnwrap(harness.postedQuestions.first)
        let question = try XCTUnwrap(harness.open(at: 16), "open after the poll that asked")
        XCTAssertEqual(harness.postedQuestions.count, 1, "asked once")
        XCTAssertEqual(question.id, posted.identifier, "the notification's id, which answers it")
        XCTAssertEqual(question.title, posted.content.title)
        XCTAssertEqual(question.body, posted.content.body)
        XCTAssertEqual(question.app, "Zoom")
        XCTAssertEqual(question.deadline, Harness.start.addingTimeInterval(45), "asked at 15 s with a 30 s countdown")
        XCTAssertEqual(harness.elapsed, 45, "the unanswered countdown ended the recording at that deadline")
    }

    func testTheQuestionIsSetWhileItsCountdownRunsAndClearedByEveryWayOut() async {
        for way in waysOut {
            let name = way.name
            let harness = Harness()
            harness.signal.calls = .ids(["call-1"])
            harness.onTick = { h, t in
                if t == 5 {
                    h.signal.active = false
                    h.signal.calls = .ids([])
                }
                way.act(h, t)
            }
            let loop = harness.makeLoop(maxDuration: way.maxDuration)

            await harness.record(meeting, on: loop)

            XCTAssertEqual(harness.elapsed, way.endsAt, "\(name): precondition: ended the named way")
            XCTAssertEqual(harness.postedQuestions.count, 1, "\(name): precondition: one countdown")
            XCTAssertTrue(harness.answered.allSatisfy(\.self), "\(name): the window's answer was refused")
            let question = harness.open(at: 16)
            XCTAssertNotNil(question, "\(name): not set once asked")
            let running = 16 ... (way.runsOn ? 20 : Int(way.endsAt))
            XCTAssertEqual(harness.open(running), running.map { _ in question }, "\(name): not the same question while it runs")
            if way.runsOn {
                let after = 21 ... Int(way.endsAt)
                XCTAssertEqual(harness.open(after), after.map { _ in nil }, "\(name): still set after the question went")
            }
            XCTAssertNil(loop.meetingEndQuestion, "\(name): still set after the recording ended")
        }
    }

    /// R5 errors: an answer to a question that is not the open one, or with
    /// none open, reaches no notifier and parks nothing for the next poll.
    func testTheLoopAnswersOnlyTheOpenQuestion() {
        let notifier = AnsweringNotifier()
        let (loop, _) = makeTestWatchLoop(notifier: notifier)
        let open = makeQuestion()
        XCTAssertFalse(loop.answerMeetingEndQuestion(open, answer: .stopNow), "no question open")

        loop.meetingEndQuestion = open
        XCTAssertFalse(loop.answerMeetingEndQuestion(makeQuestion(), answer: .stopNow), "another question")
        XCTAssertTrue(notifier.answers.isEmpty, "nothing reached the notifier")
        XCTAssertNil(loop.meetingEndAnswer, "nothing parked for the next poll")

        XCTAssertTrue(loop.answerMeetingEndQuestion(open, answer: .keepRecording))
        XCTAssertEqual(notifier.answers.map(\.id), [open.id])
        XCTAssertEqual(notifier.answers.map(\.answer), [.keepRecording])
    }

    /// The window reads and answers the countdown through `AppState`, which
    /// follows whatever loop is current.
    func testAppStateReadsAndAnswersTheCurrentLoopsQuestion() throws {
        let dir = try makeTempDirectory(prefix: "meeting-end-question")
        let suite = "WatchLoopMeetingEndQuestionTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)),
            defaultOutputDir: dir.appendingPathComponent("output", isDirectory: true),
        )
        let state = AppState(
            pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: dir), settings: settings, notifier: SilentNotifier(),
        )
        let open = makeQuestion()
        XCTAssertNil(state.meetingEndQuestion, "no loop")
        XCTAssertFalse(state.answerMeetingEndQuestion(open, answer: .stopNow), "nothing is watching")

        let notifier = AnsweringNotifier()
        let (loop, _) = makeTestWatchLoop(notifier: notifier)
        state.watching.watchLoop = loop
        XCTAssertNil(state.meetingEndQuestion, "no question open")
        loop.meetingEndQuestion = open
        XCTAssertEqual(state.meetingEndQuestion, open)
        XCTAssertFalse(state.answerMeetingEndQuestion(makeQuestion(), answer: .stopNow), "another question")
        XCTAssertTrue(state.answerMeetingEndQuestion(open, answer: .stopNow))
        XCTAssertEqual(notifier.answers.map(\.answer), [.stopNow])

        state.watching.watchLoop = nil
        XCTAssertNil(state.meetingEndQuestion, "loop removed")
    }
}
