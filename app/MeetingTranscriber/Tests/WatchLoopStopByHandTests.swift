import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// "Stop Recording" on a detected meeting's recording: the meeting-end wait
/// ends at its next poll, the recording is processed like any meeting end, and
/// the app is kept out of detection while its call signal stays. Driven on
/// `TestClock`, polling once a virtual second with a 10 s end grace and the
/// app's 2-minute countdown, so every timing below is exact and no test waits
/// in real time.
@MainActor
final class WatchLoopStopByHandTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
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

    /// The meeting-end questions go to a `RecordingNotifier`; consent prompts
    /// are counted and answered Record, so an app that asks first is recorded
    /// as soon as it has been asked.
    private final class Notifier: AppNotifying {
        let questions = RecordingNotifier()
        private(set) var prompts: [String] = []

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        // swiftlint:disable async_without_await
        @MainActor
        func askToRecord(title: String, body _: String) async -> ConsentAnswer {
            prompts.append(title)
            return .granted
        }

        // swiftlint:enable async_without_await

        @MainActor
        func askBeforeEndingRecording(id: String, title: String, body: String, onAnswer: @escaping MeetingEndQuestionHandler) {
            questions.askBeforeEndingRecording(id: id, title: title, body: body, onAnswer: onAnswer)
        }

        func withdrawMeetingEndQuestion(id: String) {
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
        let clock = TestClock(start: start)
        let detector = ScriptedDetector()
        let notifier = Notifier()
        let diagnostics = RecordingDiagnostics()
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        /// The recorder for each start, which can stop it only with a mix path.
        var nextRecorder: @MainActor (Harness) -> any RecordingProvider = { _ in makeMockRecorder() }
        private(set) var recorderStarts = 0
        private(set) weak var loop: WatchLoop?

        func makeLoop(
            queue: PipelineQueue? = nil,
            recordWithoutAsking: [String] = ["Microsoft Teams"],
            recordOnlyTo outputDir: URL? = nil,
        ) -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
                await self.onTick(self, self.elapsed)
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
                // Far beyond any test, so only what a test does ends a recording.
                maxDuration: 1_000_000,
                recordOnly: { outputDir != nil },
                recordOnlyDestination: { .unscoped(outputDir ?? FileManager.default.temporaryDirectory) },
                recordWithoutAskingApps: { recordWithoutAsking },
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

        var noticeLines: [String] {
            diagnostics.lines.filter { $0.level == .notice }.map(\.line)
        }

        var autoStopLines: [String] {
            diagnostics.lines.map(\.line).filter { $0.hasPrefix("recording_auto_stop") }
        }

        var askedIDs: [String] {
            notifier.questions.meetingEndQuestions.map(\.id)
        }

        /// Answer the first question the way a tap would.
        func answerFirstQuestion(_ answer: MeetingEndAnswer) {
            if let id = askedIDs.first {
                notifier.questions.answerMeetingEndQuestion(id, with: answer)
            }
        }
    }

    private enum Tap {
        case keepRecording
        case stopRecording
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    private static let basename = "20261006_100000"

    private func meeting(_ pattern: AppMeetingPattern, owner: String) -> DetectedMeeting {
        DetectedMeeting(pattern: pattern, windowTitle: "Quarterly Review", ownerName: owner, windowPID: 4242)
    }

    private var teams: DetectedMeeting {
        meeting(.teams, owner: "Microsoft Teams")
    }

    private var zoom: DetectedMeeting {
        meeting(.zoom, owner: "zoom.us")
    }

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "stop-by-hand")
    }

    // MARK: - Helpers

    /// Three 30 s, 16 kHz tracks shaped like a dual-source recording, so the
    /// audio and a stop at 30 virtual seconds agree.
    private func makeRecorderWithTracks() throws -> StopCountingRecorder {
        let recorder = StopCountingRecorder()
        let samples = (0 ..< 30 * 16000).map { Float($0 % 1000) / 2000 }
        var urls: [URL] = []
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let url = tmpDir.appendingPathComponent("\(Self.basename)\(suffix)")
            try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
            urls.append(url)
        }
        recorder.mixPath = urls[0]
        recorder.appPath = urls[1]
        recorder.micPath = urls[2]
        return recorder
    }

    private func trackFrames(_ recorder: MockRecorder) throws -> [AVAudioFramePosition] {
        try [recorder.mixPath, recorder.appPath, recorder.micPath].map { url in
            try AVAudioFile(forReading: XCTUnwrap(url)).length
        }
    }

    private final class StopCountingRecorder: MockRecorder {
        private(set) var stops = 0

        override func stop() throws -> RecordingResult {
            stops += 1
            return try super.stop()
        }
    }

    /// Wait for `app`'s recording, stop it by hand, and wait until the loop
    /// watches again.
    private func stopByHand(_ app: String, _ loop: WatchLoop) async {
        await waitFor(loop.state == .recording && loop.currentMeeting?.pattern.appName == app, timeout: .seconds(5))
        XCTAssertTrue(loop.stopDetectedRecording(), "\(app) is recording")
        await waitFor(loop.state == .watching, timeout: .seconds(5))
    }

    // MARK: - The signal is there

    func testAStopByHandEndsAtTheNextPollAndKeepsTheWholeRecording() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks()
        harness.nextRecorder = { _ in recorder }
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        harness.detector.call(teams)
        var accepted = false
        harness.onTick = { h, t in
            if t == 20, let loop = h.loop { accepted = loop.stopDetectedRecording() }
        }

        try await loop.handleMeeting(teams)

        XCTAssertTrue(accepted)
        XCTAssertEqual(harness.elapsed, 20, "ends at the poll after the request")
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(queue.jobs.count, 1, "processed as a meeting end is")
        XCTAssertEqual(try trackFrames(recorder), [480_000, 480_000, 480_000], "nothing is cut")
        XCTAssertTrue(harness.askedIDs.isEmpty, "no meeting-end question")
        // Exact lines, so nothing else, a title least of all, rides along.
        XCTAssertEqual(harness.noticeLines, ["recording_stopped_by_hand trigger=auto", "redetect_hold_set app=Microsoft Teams"])
        XCTAssertTrue(harness.autoStopLines.isEmpty, "a stop by hand is not an automatic stop")
    }

    // MARK: - The meeting-end question is open

    /// Lost at 5 s, asked at 15 s, stopped by hand at 30 s: ended as Stop
    /// Watching ends it then, cut back to the loss plus grace. A tap on the
    /// withdrawn question afterwards changes nothing.
    func testAStopByHandDuringTheQuestionWithdrawsItAndCutsBack() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks()
        harness.nextRecorder = { _ in recorder }
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        harness.detector.call(teams)
        harness.onTick = { h, t in
            if t == 5 { h.detector.hangUp("Microsoft Teams") }
            if t == 30 { h.loop?.stopDetectedRecording() }
        }

        try await loop.handleMeeting(teams)

        XCTAssertEqual(harness.askedIDs.count, 1, "precondition: the question was asked")
        XCTAssertEqual(harness.notifier.questions.withdrawnMeetingEndQuestions, harness.askedIDs, "and is taken back")
        XCTAssertEqual(harness.elapsed, 30)
        XCTAssertEqual(try trackFrames(recorder), [240_000, 240_000, 240_000], "every track ends at the cut point")
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "recording_cut"), ["recording_cut kept_s=15"])
        XCTAssertTrue(harness.autoStopLines.isEmpty)

        harness.answerFirstQuestion(.keepRecording)

        XCTAssertNil(loop.meetingEndAnswer, "nothing is parked for a later recording")
        XCTAssertEqual(queue.jobs.count, 1)
    }

    /// The question is open from 15 s. Only an answer given before the stop
    /// counts: a Keep recording at 20 s, or tapped just before the stop within
    /// one poll, keeps everything; one tapped after the stop does not, and a
    /// repeated stop keeps the first request's time.
    func testOnlyAKeepRecordingTappedBeforeTheStopKeepsTheWholeRecording() async throws {
        let cases: [(name: String, taps: [TimeInterval: [Tap]], frames: AVAudioFramePosition)] = [
            ("Keep at 20 s, Stop at 30 s", [20: [.keepRecording], 30: [.stopRecording]], 480_000),
            ("Keep then Stop within one poll", [30: [.keepRecording, .stopRecording]], 480_000),
            ("Stop then Keep within one poll", [30: [.stopRecording, .keepRecording]], 240_000),
            ("Stop, Keep, Stop within one poll", [30: [.stopRecording, .keepRecording, .stopRecording]], 240_000),
        ]
        for (name, taps, frames) in cases {
            tmpDir = try makeTempDirectory(prefix: "stop-by-hand-order")
            let harness = Harness()
            let recorder = try makeRecorderWithTracks()
            harness.nextRecorder = { _ in recorder }
            let queue = PipelineQueue(logDir: tmpDir)
            let loop = harness.makeLoop(queue: queue)
            harness.detector.call(teams)
            harness.onTick = { h, t in
                if t == 5 { h.detector.hangUp("Microsoft Teams") }
                for (index, tap) in (taps[t] ?? []).enumerated() {
                    // Distinct times for taps between the same two polls, so
                    // their order is a strict comparison.
                    if index > 0 { await h.clock.sleep(for: 0.1) }
                    switch tap {
                    case .keepRecording:
                        h.answerFirstQuestion(.keepRecording)

                    case .stopRecording:
                        h.loop?.stopDetectedRecording()
                    }
                }
            }

            try await loop.handleMeeting(teams)

            XCTAssertEqual(try trackFrames(recorder), [frames, frames, frames], name)
            XCTAssertEqual(
                harness.diagnostics.lines(.notice, startingWith: "recording_cut").isEmpty, frames == 480_000,
                "\(name): a recording_cut line only for a cut",
            )
            XCTAssertEqual(queue.jobs.count, 1, name)
            XCTAssertEqual(harness.notifier.questions.withdrawnMeetingEndQuestions, harness.askedIDs, name)
        }
    }

    // MARK: - Failures and refusals

    /// The stop throws: reported as for any recording that fails to stop, no
    /// job, back to watching, and the hold placed before the stop keeps the
    /// still-signalling app from being recorded again.
    func testARecorderThatFailsToStopReportsTheErrorAndTheAppStaysHeld() async {
        let harness = Harness()
        harness.nextRecorder = { _ in MockRecorder() }
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        var phases: [WatchLoop.State] = []
        loop.onStateChange = { _, next in phases.append(next) }
        harness.detector.call(teams)
        loop.start()

        await stopByHand("Microsoft Teams", loop)
        let watchingAgainAt = harness.elapsed
        await waitFor(harness.elapsed >= watchingAgainAt + 6, timeout: .seconds(5))

        XCTAssertEqual(phases, [.watching, .recording, .error, .watching])
        XCTAssertNotNil(loop.lastError)
        XCTAssertTrue(queue.jobs.isEmpty, "no job for a recording that failed to stop")
        XCTAssertGreaterThanOrEqual(harness.elapsed, watchingAgainAt + 6, "precondition: at least five more polls")
        XCTAssertEqual(harness.recorderStarts, 1, "the still-active app is not recorded again")
        XCTAssertEqual(harness.noticeLines, ["recording_stopped_by_hand trigger=auto", "redetect_hold_set app=Microsoft Teams"])
        loop.stop()
    }

    func testAStopIsRefusedWhenNoDetectedMeetingRecords() async throws {
        let harness = Harness()
        let recorder = makeMockRecorder()
        harness.nextRecorder = { _ in recorder }
        let loop = harness.makeLoop()

        XCTAssertFalse(loop.stopDetectedRecording(), "idle")
        XCTAssertNil(loop.stopByHandRequestedAt)

        loop.start()
        XCTAssertEqual(loop.state, .watching)
        XCTAssertFalse(loop.stopDetectedRecording(), "watching without a recording")
        XCTAssertNil(loop.stopByHandRequestedAt)
        loop.stop()

        try await loop.startMicrophoneRecording()
        let recording = loop.snapshot
        XCTAssertFalse(loop.stopDetectedRecording(), "a manual microphone recording")
        XCTAssertNil(loop.stopByHandRequestedAt)
        XCTAssertEqual(loop.snapshot, recording, "it keeps running")
        XCTAssertFalse(recorder.stopCalled)
        loop.stopManualRecording()
        XCTAssertTrue(harness.diagnostics.lines.isEmpty)
    }

    /// Stop Recording chosen while capture is starting, and the start fails:
    /// the request goes with the failed recording and never ends the next one.
    func testARequestMadeWhileCaptureStartsDoesNotEndTheNextRecording() async throws {
        let harness = Harness()
        var acceptedWhileStarting = false
        harness.nextRecorder = { h in
            guard h.recorderStarts == 1, let loop = h.loop else { return makeMockRecorder() }
            acceptedWhileStarting = loop.stopDetectedRecording()
            return ThrowingRecorder()
        }
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        harness.onTick = { h, t in
            if t == 5 { h.loop?.stopDetectedRecording() }
        }

        var startFailed = false
        do { try await loop.handleMeeting(teams) } catch { startFailed = true }
        XCTAssertTrue(startFailed, "precondition: the recorder start throws")
        XCTAssertTrue(acceptedWhileStarting, "accepted while capture was starting")

        try await loop.handleMeeting(teams)

        XCTAssertEqual(harness.elapsed, 5, "the next recording ran until its own stop")
    }

    // MARK: - The re-detection hold

    /// Stopped by hand while its signal stays, the app is neither recorded
    /// nor asked about; one poll without the signal releases it, and its next
    /// call is recorded. Once for an app that records without asking, once
    /// for one that asks first.
    func testAStoppedAppIsHeldUntilItsSignalHasGoneOnce() async {
        for asksFirst in [false, true] {
            let harness = Harness()
            let loop = harness.makeLoop(recordWithoutAsking: asksFirst ? [] : ["Microsoft Teams"])
            let label = asksFirst ? "asks first" : "records without asking"
            harness.detector.call(teams)
            loop.start()

            await stopByHand("Microsoft Teams", loop)
            let promptsBefore = harness.notifier.prompts.count
            let heldAt = harness.elapsed
            await waitFor(harness.elapsed >= heldAt + 6, timeout: .seconds(5))
            XCTAssertGreaterThanOrEqual(harness.elapsed, heldAt + 6, "\(label): precondition: at least five more polls")
            XCTAssertEqual(harness.recorderStarts, 1, "\(label): not recorded again while the signal stays")
            XCTAssertEqual(harness.notifier.prompts.count, promptsBefore, "\(label): nor asked about")
            XCTAssertEqual(promptsBefore, asksFirst ? 1 : 0, "\(label): precondition: asked once before recording")

            harness.detector.hangUp("Microsoft Teams")
            await waitFor(loop.appsHeldFromDetection.isEmpty, timeout: .seconds(5))
            XCTAssertEqual(
                harness.diagnostics.lines(.notice, startingWith: "redetect_hold_released"),
                ["redetect_hold_released app=Microsoft Teams"], label,
            )

            harness.detector.call(teams)
            await waitFor(harness.recorderStarts == 2, timeout: .seconds(5))
            XCTAssertEqual(harness.recorderStarts, 2, "\(label): the next call is recorded")
            XCTAssertEqual(harness.notifier.prompts.count, asksFirst ? 2 : 0, "\(label): and asked about as usual")
            loop.stop()
        }
    }

    /// Other apps are recorded during a hold, each hold is released only by
    /// its own app's signal, and Stop Watching discards them all.
    func testHoldsArePerAppAndStopWatchingDiscardsThem() async {
        let harness = Harness()
        let loop = harness.makeLoop(recordWithoutAsking: ["Microsoft Teams", "Zoom"])
        harness.detector.call(teams)
        loop.start()
        await stopByHand("Microsoft Teams", loop)

        // Teams comes first in the detector's order and still signals.
        harness.detector.call(zoom)
        await waitFor(loop.state == .recording, timeout: .seconds(5))
        XCTAssertEqual(loop.currentMeeting?.pattern.appName, "Zoom", "Zoom is recorded while Teams is held")
        await stopByHand("Zoom", loop)
        XCTAssertEqual(loop.appsHeldFromDetection, ["Microsoft Teams", "Zoom"])

        harness.detector.hangUp("Zoom")
        await waitFor(loop.appsHeldFromDetection.count == 1, timeout: .seconds(5))
        XCTAssertEqual(loop.appsHeldFromDetection, ["Microsoft Teams"], "only Zoom's own signal releases Zoom")
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "redetect_hold_released"), ["redetect_hold_released app=Zoom"])
        XCTAssertEqual(harness.recorderStarts, 2)

        loop.stop()
        XCTAssertTrue(loop.appsHeldFromDetection.isEmpty, "Stop Watching discards every hold")
        loop.start()
        await waitFor(harness.recorderStarts == 3, timeout: .seconds(5))
        XCTAssertEqual(loop.currentMeeting?.pattern.appName, "Microsoft Teams", "Teams is recorded again")
        loop.stop()
    }

    // MARK: - Record-only

    /// Written out as a meeting end is, labelled `auto` because the detector
    /// started it.
    func testRecordOnlyWritesTheStoppedMeetingWithAnAutoTrigger() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks()
        harness.nextRecorder = { _ in recorder }
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue, recordOnlyTo: outputDir)
        harness.detector.call(teams)
        harness.onTick = { h, t in
            if t == 20 { h.loop?.stopDetectedRecording() }
        }

        try await loop.handleMeeting(teams)

        XCTAssertTrue(queue.jobs.isEmpty, "record-only enqueues no job")
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let file = try AVAudioFile(forReading: outputDir.appendingPathComponent("\(Self.basename)\(suffix)"))
            XCTAssertEqual(file.length, 480_000, "\(suffix) is written whole")
        }
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename))
        XCTAssertEqual(sidecar.trigger, .auto, "who started the recording, not who stopped it")
    }
}
