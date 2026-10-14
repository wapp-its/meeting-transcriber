import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// "Nothing heard for 5 minutes. Stop the recording?" on a detected meeting's
/// recording. The question runs inside the meeting-end wait: "Stop now" ends
/// the recording as a meeting end does and watching goes on, the app is then
/// kept out of detection until its call signal has gone once, and the question
/// gives way to "the meeting seems to have ended" while that one is open.
/// Driven on `TestClock`, polling once a virtual second with a 10 s end grace
/// and a 20 s silence, with the silence clock injected in that clock's terms,
/// so every timing below is exact and no test waits in real time.
@MainActor
final class WatchLoopSilencePromptDetectedTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    /// A call per app: a poll confirms the first meeting in `confirmed` whose
    /// signal is there and whose app is not excluded, and a meeting counts as
    /// active while its app's signal is there. No cooldown after a reset, so
    /// a still-signalling app would be detected again at the very next poll.
    private final class ScriptedDetector: MeetingDetecting {
        private var confirmed: [DetectedMeeting] = []
        private var signalling: Set<String> = []

        func checkOnce() -> DetectedMeeting? {
            checkOnce(excluding: [])
        }

        func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
            confirmed.first { signalling.contains($0.pattern.appName) && !excludedApps.contains($0.pattern.appName) }
        }

        func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
            signalling.contains(meeting.pattern.appName)
        }

        func reset(appName _: String?) {}

        /// `meeting`'s app is in a call: its signal is there.
        func call(_ meeting: DetectedMeeting) {
            let app = meeting.pattern.appName
            if !confirmed.contains(where: { $0.pattern.appName == app }) { confirmed.append(meeting) }
            signalling.insert(app)
        }

        /// The app's signal is gone.
        func hangUp(_ app: String) {
            signalling.remove(app)
        }
    }

    /// Both questions go to a `RecordingNotifier`, and every post and every
    /// withdrawal is also noted in `events`, in the order they happened.
    /// Consent prompts are counted and answered Record, so an app that asks
    /// first is recorded as soon as it has been asked.
    private final class Notifier: AppNotifying {
        let questions = RecordingNotifier()
        private(set) var prompts = 0
        /// "ask <title>" and "withdraw <id>".
        private(set) var events: [String] = []

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        // swiftlint:disable async_without_await
        @MainActor
        func askToRecord(title _: String, body _: String) async -> ConsentAnswer {
            prompts += 1
            return .granted
        }

        // swiftlint:enable async_without_await

        @MainActor
        func askBeforeEndingRecording(id: String, title: String, body: String, onAnswer: @escaping MeetingEndQuestionHandler) {
            events.append("ask \(title)")
            questions.askBeforeEndingRecording(id: id, title: title, body: body, onAnswer: onAnswer)
        }

        func withdrawMeetingEndQuestion(id: String) {
            events.append("withdraw \(id)")
            questions.withdrawMeetingEndQuestion(id: id)
        }
    }

    /// Everything a loop under test talks to. `onTick` runs after every
    /// virtual sleep, before the next poll, with the seconds since the clock
    /// started. It is handed the harness rather than capturing it, so no test
    /// builds a reference cycle.
    @MainActor
    private final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        static let meetingEndTitle = "Meeting seems to have ended"
        let clock = TestClock(start: start)
        let detector = ScriptedDetector()
        let notifier = Notifier()
        let diagnostics = RecordingDiagnostics()
        /// The configured silence; nil is switched off.
        var after: TimeInterval? = 20
        /// When speech was last heard, in seconds from the start; nil is never.
        var lastSpeech: TimeInterval?
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        /// The recorder for each start, which can stop it only with a mix path.
        var nextRecorder: @MainActor (Harness) -> any RecordingProvider = { _ in makeMockRecorder() }
        private(set) var recorderStarts = 0
        /// How many silence questions and meeting-end questions had been
        /// asked, and how many questions taken back, before the poll at each
        /// second.
        private(set) var beforePoll: [Int: (silence: Int, meetingEnd: Int, withdrawn: Int)] = [:]
        private(set) var answeredFirstSilenceQuestion = false
        private(set) weak var loop: WatchLoop?

        func makeLoop(
            queue: PipelineQueue? = nil,
            maxDuration: TimeInterval = 3600,
            countdown: TimeInterval = WatchLoop.meetingEndQuestionCountdown,
            recordWithoutAsking: [String] = ["Microsoft Teams"],
        ) -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
                self.beforePoll[Int(self.elapsed)] = (
                    self.silenceQuestionIDs.count, self.meetingEndQuestionIDs.count, self.withdrawnIDs.count,
                )
                await self.onTick(self, self.elapsed)
            }
            let speechActivity: () -> SpeechActivity? = {
                SpeechActivity(observedSince: Self.start, lastSpeechAt: self.lastSpeech.map { Self.start.addingTimeInterval($0) })
            }
            let loop = WatchLoop(
                detector: detector,
                recorderFactory: {
                    self.recorderStarts += 1
                    return self.nextRecorder(self)
                },
                pipelineQueue: queue,
                pollInterval: 1,
                endGracePeriod: 10,
                maxDuration: maxDuration,
                meetingEndCountdown: countdown,
                recordWithoutAskingApps: { recordWithoutAsking },
                speechActivity: speechActivity,
                silencePromptAfter: { self.after },
                notifier: notifier,
                diagnostics: diagnostics,
                nowProvider: { self.clock.now },
                sleepProvider: sleepProvider,
            )
            loop.permissionChecker = { .allHealthy }
            self.loop = loop
            return loop
        }

        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(Self.start)
        }

        var silenceQuestionIDs: [String] {
            notifier.questions.meetingEndQuestions.filter { $0.title != Self.meetingEndTitle }.map(\.id)
        }

        var meetingEndQuestionIDs: [String] {
            notifier.questions.meetingEndQuestions.filter { $0.title == Self.meetingEndTitle }.map(\.id)
        }

        var withdrawnIDs: [String] {
            notifier.questions.withdrawnMeetingEndQuestions
        }

        var noticeLines: [String] {
            diagnostics.lines.filter { $0.level == .notice }.map(\.line)
        }

        /// The silence question's lines, in the order written.
        var silenceLines: [String] {
            diagnostics.lines.map(\.line).filter { $0.hasPrefix("silence_question") }
        }

        /// What ended the recording: an automatic stop or a stop by hand.
        var endLines: [String] {
            diagnostics.lines.map(\.line).filter { $0.hasPrefix("recording_auto_stop") || $0.hasPrefix("recording_stopped_by_hand") }
        }

        /// Answer question `id` the way a tap on one of its actions would.
        func answer(_ id: String?, with answer: MeetingEndAnswer) {
            if let id { notifier.questions.answerMeetingEndQuestion(id, with: answer) }
        }

        /// "Stop now" on the first silence question, once, at the first poll
        /// after it went up.
        func stopNowOnTheFirstSilenceQuestion() {
            guard !answeredFirstSilenceQuestion, let id = silenceQuestionIDs.first else { return }
            answeredFirstSilenceQuestion = true
            answer(id, with: .stopNow)
        }
    }

    /// One way the recording ends while the silence question is open.
    @MainActor
    private struct OtherEnd {
        let name: String
        var maxDuration: TimeInterval = 3600
        var countdown: TimeInterval = WatchLoop.meetingEndQuestionCountdown
        var trackSeconds = 27
        /// Run through the watch loop rather than the recording alone.
        var throughWatching = false
        let act: @MainActor (Harness, TimeInterval) -> Void
        let keptSeconds: Int
        let endLines: [String]
        let lastSilenceLine: String
    }

    private enum Settle {
        case keepRecording
        case signalReturns
    }

    private static let teams = DetectedMeeting(
        pattern: .teams, windowTitle: "Quarterly Review", ownerName: "Microsoft Teams", windowPID: 4242,
    )

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "silence-prompt-detected")
    }

    // MARK: - Helpers

    /// Mix, app and microphone tracks of `seconds` at 16 kHz.
    private func makeRecorderWithTracks(seconds: Int) throws -> MockRecorder {
        let recorder = MockRecorder()
        let dir = try makeTempDirectory(prefix: "silence-prompt-detected-tracks")
        let samples = (0 ..< seconds * 16000).map { Float($0 % 1000) / 2000 }
        let urls = try [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic].map { suffix in
            let url = dir.appendingPathComponent("20261014_100000\(suffix)")
            try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
            return url
        }
        recorder.mixPath = urls[0]
        recorder.appPath = urls[1]
        recorder.micPath = urls[2]
        return recorder
    }

    /// Frames of the mix, app and microphone track, in that order.
    private func trackFrames(_ recorder: MockRecorder) throws -> [AVAudioFramePosition] {
        try [recorder.mixPath, recorder.appPath, recorder.micPath].map { url in
            try AVAudioFile(forReading: XCTUnwrap(url)).length
        }
    }

    // MARK: - R1 / R2: asked, and Stop now

    /// Speech last heard at 5 s, asked at 25 s, "Stop now" at 27 s: the
    /// recording ends at that poll, is processed as a meeting end is with
    /// every track cut to 15 s, and the loop goes back to watching.
    func testStopNowEndsASilentDetectedRecordingCutAndWatchingGoesOn() async throws {
        let harness = Harness()
        harness.lastSpeech = 5
        let recorder = try makeRecorderWithTracks(seconds: 27)
        harness.nextRecorder = { _ in recorder }
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        harness.detector.call(Self.teams)
        harness.onTick = { h, t in
            if t == 27 { h.answer(h.silenceQuestionIDs.last, with: .stopNow) }
        }

        loop.start()
        await waitFor(!queue.jobs.isEmpty && loop.state == .watching, timeout: .seconds(5))
        let state = loop.state
        loop.stop()

        let question = try XCTUnwrap(harness.notifier.questions.meetingEndQuestions.first)
        XCTAssertEqual(question.title, "Nothing heard for 1 minute")
        XCTAssertEqual(question.body, "Stop the recording? Without an answer, it keeps recording.")
        XCTAssertEqual(state, .watching, "back to watching, not idle")
        XCTAssertEqual(queue.jobs.count, 1, "processed as a meeting end is")
        XCTAssertEqual(queue.jobs.first?.mixPath, recorder.mixPath)
        XCTAssertEqual(try trackFrames(recorder), [240_000, 240_000, 240_000], "every track ends 10 s after the last speech")
        // Exact lines, so nothing else, a title least of all, rides along.
        XCTAssertEqual(harness.noticeLines, [
            "silence_question_posted trigger=auto silent_s=20",
            "recording_auto_stop trigger=auto reason=silence_stop silent_s=22",
            "redetect_hold_set app=Microsoft Teams",
            "recording_cut kept_s=15",
        ])
    }

    // MARK: - R5: the re-detection hold

    /// Stopped through the question while its signal stays, the app is
    /// neither recorded nor asked about; one poll without the signal releases
    /// it, and its next call is recorded. Once for an app that records
    /// without asking, once for one that asks first.
    func testAnAppStoppedForSilenceIsHeldUntilItsSignalHasGoneOnce() async {
        for asksFirst in [false, true] {
            let label = asksFirst ? "asks first" : "records without asking"
            let harness = Harness()
            let loop = harness.makeLoop(recordWithoutAsking: asksFirst ? [] : ["Microsoft Teams"])
            harness.onTick = { h, _ in h.stopNowOnTheFirstSilenceQuestion() }
            harness.detector.call(Self.teams)
            loop.start()

            await waitFor(loop.appsHeldFromDetection == ["Microsoft Teams"] && loop.state == .watching, timeout: .seconds(5))
            XCTAssertEqual(
                harness.diagnostics.lines(.notice, startingWith: "recording_auto_stop trigger=auto reason=silence_stop").count, 1,
                "\(label): precondition: stopped through the question",
            )
            let promptsBefore = harness.notifier.prompts
            let heldAt = harness.elapsed
            await waitFor(harness.elapsed >= heldAt + 6, timeout: .seconds(5))
            XCTAssertGreaterThanOrEqual(harness.elapsed, heldAt + 6, "\(label): precondition: at least five more polls")
            XCTAssertEqual(harness.recorderStarts, 1, "\(label): not recorded again while the signal stays")
            XCTAssertEqual(harness.notifier.prompts, promptsBefore, "\(label): nor asked about")
            XCTAssertEqual(promptsBefore, asksFirst ? 1 : 0, "\(label): precondition: asked once before recording")

            harness.detector.hangUp("Microsoft Teams")
            await waitFor(loop.appsHeldFromDetection.isEmpty, timeout: .seconds(5))
            XCTAssertEqual(
                harness.diagnostics.lines(.notice, startingWith: "redetect_hold"),
                ["redetect_hold_set app=Microsoft Teams", "redetect_hold_released app=Microsoft Teams"], label,
            )

            harness.detector.call(Self.teams)
            await waitFor(harness.recorderStarts == 2, timeout: .seconds(5))
            XCTAssertEqual(harness.recorderStarts, 2, "\(label): the next call is recorded")
            XCTAssertEqual(harness.notifier.prompts, asksFirst ? 2 : 0, "\(label): and asked about as usual")
            loop.stop()
        }
    }

    // MARK: - R7: one question at a time

    /// Asked at 20 s; the signal goes at 25 s, and "the meeting seems to have
    /// ended" goes up at 35 s, in the poll that takes the silence question
    /// back and after it. No silence question while that one is open. Settled
    /// without a stop at 60 s, by "Keep recording" or by the signal coming
    /// back, the next silence question comes a full 20 s later.
    func testTheSilenceQuestionGivesWayToTheMeetingEndQuestion() async throws {
        for settle in [Settle.keepRecording, .signalReturns] {
            let name = "\(settle)"
            let harness = Harness()
            let loop = harness.makeLoop()
            harness.detector.call(Self.teams)
            harness.onTick = { h, t in
                if t == 25 { h.detector.hangUp("Microsoft Teams") }
                if t == 60 {
                    switch settle {
                    case .keepRecording: h.answer(h.meetingEndQuestionIDs.first, with: .keepRecording)
                    case .signalReturns: h.detector.call(Self.teams)
                    }
                }
                if t == 85 { h.loop?.stopDetectedRecording() }
            }

            try await loop.handleMeeting(Self.teams)

            XCTAssertEqual(harness.silenceQuestionIDs.count, 2, name)
            let silenceID = try XCTUnwrap(harness.silenceQuestionIDs.first, name)
            XCTAssertEqual(harness.beforePoll[35]?.meetingEnd, 0, name)
            XCTAssertEqual(harness.beforePoll[36]?.meetingEnd, 1, "\(name): the meeting-end question at 35 s")
            XCTAssertEqual(
                Array(harness.notifier.events.prefix(3)),
                ["ask Nothing heard for 1 minute", "withdraw \(silenceID)", "ask \(Harness.meetingEndTitle)"],
                "\(name): taken back in that poll, before the other one goes up",
            )
            XCTAssertEqual(harness.beforePoll[61]?.withdrawn, 2, "\(name): precondition: the meeting-end question settled at 60 s")
            XCTAssertEqual(harness.beforePoll[61]?.silence, 1, "\(name): no silence question while it was open")
            XCTAssertEqual(harness.beforePoll[80]?.silence, 1, "\(name): nothing until a full period after it was settled")
            XCTAssertEqual(harness.beforePoll[81]?.silence, 2, name)
            XCTAssertEqual(harness.silenceLines, [
                "silence_question_posted trigger=auto silent_s=20",
                "silence_question_withdrawn trigger=auto reason=held",
                "silence_question_posted trigger=auto silent_s=80",
                "silence_question_withdrawn trigger=auto reason=ended",
            ], name)
        }
    }

    /// The ends the test below drives. The countdown's has no "Stop now":
    /// the meeting-end question going up took the silence question back.
    private var otherEnds: [OtherEnd] {
        [
            OtherEnd(
                name: "duration cap", maxDuration: 26,
                act: { h, t in if t == 27 { h.stopNowOnTheFirstSilenceQuestion() } },
                keptSeconds: 27, endLines: ["recording_auto_stop trigger=auto reason=max_duration"],
                lastSilenceLine: "silence_question_withdrawn trigger=auto reason=ended",
            ),
            OtherEnd(
                name: "meeting-end countdown", countdown: 30, trackSeconds: 66,
                act: { h, t in if t == 26 { h.detector.hangUp("Microsoft Teams") } },
                keptSeconds: 36, endLines: ["recording_auto_stop trigger=auto reason=countdown_expired signal_absent_s=40"],
                lastSilenceLine: "silence_question_withdrawn trigger=auto reason=held",
            ),
            OtherEnd(
                name: "Stop Watching", throughWatching: true,
                act: { h, t in
                    if t == 27 {
                        h.stopNowOnTheFirstSilenceQuestion()
                        h.loop?.stop()
                    }
                },
                keptSeconds: 27, endLines: [],
                lastSilenceLine: "silence_question_withdrawn trigger=auto reason=ended",
            ),
            OtherEnd(
                name: "Stop Recording", throughWatching: true,
                act: { h, t in
                    if t == 27 {
                        h.stopNowOnTheFirstSilenceQuestion()
                        h.loop?.stopDetectedRecording()
                    }
                },
                keptSeconds: 27, endLines: ["recording_stopped_by_hand trigger=auto"],
                lastSilenceLine: "silence_question_withdrawn trigger=auto reason=ended",
            ),
        ]
    }

    /// Every other end with the silence question open ends the recording as
    /// it ends without that question, with a "Stop now" to it waiting where
    /// the end comes first, and takes the question back: the duration cap,
    /// Stop Watching and the menu's Stop Recording at the end, the
    /// meeting-end question when it goes up, its countdown then ending the
    /// recording cut back to the signal loss plus grace.
    func testEveryOtherEndWithdrawsTheSilenceQuestionAndEndsAsBefore() async throws {
        for end in otherEnds {
            let harness = Harness()
            harness.lastSpeech = 5
            let recorder = try makeRecorderWithTracks(seconds: end.trackSeconds)
            harness.nextRecorder = { _ in recorder }
            let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "silence-prompt-detected-queue"))
            let loop = harness.makeLoop(queue: queue, maxDuration: end.maxDuration, countdown: end.countdown)
            harness.detector.call(Self.teams)
            harness.onTick = { h, t in end.act(h, t) }

            if end.throughWatching {
                loop.start()
                await waitFor(!queue.jobs.isEmpty, timeout: .seconds(5))
                loop.stop()
            } else {
                try await loop.handleMeeting(Self.teams)
            }

            XCTAssertEqual(harness.silenceQuestionIDs.count, 1, "\(end.name): precondition: one silence question, open at the end")
            XCTAssertEqual(Set(harness.silenceQuestionIDs).subtracting(harness.withdrawnIDs), [], "\(end.name): taken back")
            XCTAssertEqual(harness.silenceLines.count, 2, end.name)
            XCTAssertEqual(harness.silenceLines.last, end.lastSilenceLine, end.name)
            XCTAssertEqual(harness.endLines, end.endLines, end.name)
            let frames = AVAudioFramePosition(end.keptSeconds * 16000)
            XCTAssertEqual(try trackFrames(recorder), [frames, frames, frames], end.name)
            XCTAssertEqual(queue.jobs.count, 1, end.name)
        }
    }
}
