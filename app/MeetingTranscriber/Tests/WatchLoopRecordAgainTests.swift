@testable import MeetingTranscriber
import XCTest

/// "Record Again" after a detected meeting's recording was ended while its
/// call went on: the offer, the click's recording at the next poll, and what
/// is left afterwards. Driven on `TestClock`, polling once a virtual second
/// with a 10 s end grace and a 5 s meeting-end countdown, so no test waits in
/// real time. The refusals and failures are in
/// `WatchLoopRecordAgainTests+Refusals.swift`, the new-call split with the real
/// assertion detector in `WatchLoopRecordAgainSplitTests`.
@MainActor
final class WatchLoopRecordAgainTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // The doubles, the harness and the helpers down to `stopByHand` are not
    // private: WatchLoopRecordAgainTests+Refusals.swift shares them.
    // swiftlint:disable test_case_accessibility

    /// A call per app: a poll confirms the first meeting in `confirmed` whose
    /// signal is there and whose app is not excluded, and a meeting counts as
    /// active while its app's signal is there. No cooldown after a reset, so
    /// a still-signalling app would be detected again at the very next poll.
    final class ScriptedDetector: MeetingDetecting {
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

        /// What the resume snapshot holds.
        func signallingMeetings() -> [DetectedMeeting] {
            confirmed.filter { signalling.contains($0.pattern.appName) }
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

    /// The meeting-end and silence questions go to a `RecordingNotifier`.
    /// Consent prompts are counted and answered Record at once, or, with
    /// `parksPrompts`, held until the test answers them.
    final class Notifier: AppNotifying {
        let questions = RecordingNotifier()
        private(set) var prompts: [String] = []
        var parksPrompts = false
        private var parked: CheckedContinuation<ConsentAnswer, Never>?

        var isParked: Bool {
            parked != nil
        }

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        @MainActor
        func askToRecord(title: String, body _: String) async -> ConsentAnswer {
            prompts.append(title)
            guard parksPrompts else { return .granted }
            return await withCheckedContinuation { parked = $0 }
        }

        func answerPrompt(_ answer: ConsentAnswer) {
            let continuation = parked
            parked = nil
            continuation?.resume(returning: answer)
        }

        func resolveBrowserConsent(granted: Bool) -> Bool {
            guard isParked else { return false }
            answerPrompt(granted ? .granted : .declined)
            return true
        }

        func answerConsentPrompt(id _: UUID, granted: Bool) -> Bool {
            resolveBrowserConsent(granted: granted)
        }

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
    final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: start)
        let detector = ScriptedDetector()
        let notifier = Notifier()
        let diagnostics = RecordingDiagnostics()
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        /// The recorder for each start, which can stop it only with a mix path.
        var nextRecorder: @MainActor (Harness) -> any RecordingProvider = { _ in Harness.recorder() }
        /// The long-silence question's delay; nil switches it off.
        var silenceAfter: TimeInterval?
        private(set) var recorderStarts = 0
        private(set) var phases: [WatchLoop.State] = []
        /// When each move into `.recording` happened, and why.
        private(set) var recordingStartTimes: [TimeInterval] = []
        private(set) var recordingStartCauses: [PhaseChangeCause] = []
        private var answeredFirstQuestion = false
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
                meetingEndCountdown: 5,
                recordOnly: { outputDir != nil },
                recordOnlyDestination: { .unscoped(outputDir ?? FileManager.default.temporaryDirectory) },
                recordWithoutAskingApps: { recordWithoutAsking },
                speechActivity: { SpeechActivity(observedSince: Self.start, lastSpeechAt: nil) },
                silencePromptAfter: { self.silenceAfter },
                notifier: notifier,
                diagnostics: diagnostics,
                nowProvider: { self.clock.now },
                sleepProvider: sleepProvider,
            )
            loop.permissionChecker = { .allHealthy }
            loop.onStateChange = { [weak self] _, next, cause in
                guard let self else { return }
                phases.append(next)
                if next == .recording {
                    recordingStartTimes.append(elapsed)
                    recordingStartCauses.append(cause)
                }
            }
            self.loop = loop
            return loop
        }

        /// A recorder whose mix path has no file, so a recording cut back at
        /// the end of a call finds nothing to cut.
        static func recorder() -> MockRecorder {
            let recorder = MockRecorder()
            recorder.mixPath = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_mix.wav")
            return recorder
        }

        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(Self.start)
        }

        var noticeLines: [String] {
            diagnostics.lines.filter { $0.level == .notice }.map(\.line)
        }

        var recordAgainLines: [String] {
            diagnostics.lines.map(\.line).filter { $0.hasPrefix("record_again") }
        }

        /// "Stop now" on the first question asked, once.
        func stopNowOnTheFirstQuestion() {
            guard !answeredFirstQuestion, let id = notifier.questions.meetingEndQuestions.first?.id else { return }
            answeredFirstQuestion = true
            notifier.questions.answerMeetingEndQuestion(id, with: .stopNow)
        }
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    var tmpDir: URL!

    // Stored, so the meeting a loop records is equal to these: each one
    // built anew would carry its own `detectedAt`.
    let teams = DetectedMeeting(pattern: .teams, windowTitle: "Quarterly Review", ownerName: "Microsoft Teams", windowPID: 4242)
    let zoom = DetectedMeeting(pattern: .zoom, windowTitle: "Quarterly Review", ownerName: "zoom.us", windowPID: 4242)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "record-again")
    }

    /// Wait for `app`'s recording, stop it by hand, and wait until the loop
    /// watches again with the app held.
    func stopByHand(_ app: String, _ loop: WatchLoop) async {
        await waitFor(loop.state == .recording && loop.currentMeeting?.pattern.appName == app, timeout: .seconds(5))
        XCTAssertTrue(loop.stopDetectedRecording(), "\(app) is recording")
        await waitFor(loop.state == .watching && loop.appsHeldFromDetection.contains(app), timeout: .seconds(5))
    }

    // swiftlint:enable test_case_accessibility

    private enum Stop: CaseIterable {
        case byHand
        case silence
    }

    private func offer(_ app: String) -> RecordAgainOffer {
        RecordAgainOffer(identityKey: app, appName: app)
    }

    // MARK: - R1: the offer

    /// Offered after either stop while the signal stays, and gone with the
    /// hold at the first poll that finds the signal gone.
    func testRecordAgainIsOfferedAfterEitherStopUntilTheHoldIsReleased() async {
        for stop in Stop.allCases {
            let harness = Harness()
            harness.silenceAfter = stop == .silence ? 20 : nil
            let loop = harness.makeLoop()
            harness.detector.call(teams)
            harness.onTick = { h, t in
                switch stop {
                case .byHand: if t == 5 { h.loop?.stopDetectedRecording() }
                case .silence: h.stopNowOnTheFirstQuestion()
                }
            }
            loop.start()

            await waitFor(loop.state == .watching && !loop.appsHeldFromDetection.isEmpty, timeout: .seconds(5))
            XCTAssertEqual(loop.recordAgainOffers, [offer("Microsoft Teams")], "\(stop)")
            XCTAssertEqual(harness.recorderStarts, 1, "\(stop): precondition: one recording")

            harness.detector.hangUp("Microsoft Teams")
            await waitFor(loop.appsHeldFromDetection.isEmpty, timeout: .seconds(5))
            XCTAssertTrue(loop.recordAgainOffers.isEmpty, "\(stop): gone with the hold")
            XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "\(stop): a click from the menu shown before")
            loop.stop()
        }
    }

    /// A call held because watching resumed after a manual recording (A1).
    func testNoOfferForACallHeldWhenWatchingResumesAfterAManualRecording() async {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        loop.holdSignallingMeetings()
        loop.start()

        await waitFor(harness.elapsed >= 3, timeout: .seconds(5))
        XCTAssertEqual(loop.appsHeldFromDetection, ["Microsoft Teams"], "precondition: held")
        XCTAssertTrue(loop.recordAgainOffers.isEmpty)
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"))
        await waitFor(harness.elapsed >= 6, timeout: .seconds(5))
        XCTAssertEqual(harness.recorderStarts, 0)
        loop.stop()
    }

    /// Several held apps: one offer each, by name, none while any recording
    /// runs; a click lifts only its own app's hold, and a recording stopped
    /// again is offered again. Stop Watching discards them all.
    func testEachHeldAppHasItsOwnOfferAndAClickLiftsOnlyItsOwn() async {
        let harness = Harness()
        let loop = harness.makeLoop(recordWithoutAsking: ["Microsoft Teams", "Zoom"])
        harness.detector.call(teams)
        loop.start()
        await stopByHand("Microsoft Teams", loop)

        harness.detector.call(zoom)
        await waitFor(loop.state == .recording, timeout: .seconds(5))
        XCTAssertTrue(loop.recordAgainOffers.isEmpty, "none while a recording runs")
        await stopByHand("Zoom", loop)
        XCTAssertEqual(loop.recordAgainOffers, [offer("Microsoft Teams"), offer("Zoom")])

        XCTAssertTrue(loop.recordAgain(identityKey: "Zoom"))
        await waitFor(harness.recorderStarts == 3 && loop.state == .recording, timeout: .seconds(5))
        XCTAssertEqual(loop.currentMeeting, zoom)
        XCTAssertEqual(loop.appsHeldFromDetection, ["Microsoft Teams"], "Teams stays held")

        await stopByHand("Zoom", loop)
        XCTAssertEqual(loop.recordAgainOffers, [offer("Microsoft Teams"), offer("Zoom")], "stopped again, offered again")

        loop.stop()
        XCTAssertTrue(loop.recordAgainOffers.isEmpty, "Stop Watching")
        XCTAssertTrue(loop.appsHeldFromDetection.isEmpty)
    }

    // MARK: - R2: the click

    /// Clicked between two polls, the recording starts at the next one with
    /// the held meeting, no consent question and no confirmation polls, and
    /// the loop marks it as the click's. Once for an app that records without
    /// asking, once for one that asks first.
    func testAClickRecordsTheHeldMeetingAtTheNextPollWithoutAsking() async {
        for asksFirst in [false, true] {
            let label = asksFirst ? "asks first" : "records without asking"
            let harness = Harness()
            let loop = harness.makeLoop(recordWithoutAsking: asksFirst ? [] : ["Microsoft Teams"])
            harness.detector.call(teams)
            var accepted = false
            harness.onTick = { h, t in
                guard let loop = h.loop else { return }
                if t == 5 { loop.stopDetectedRecording() }
                if t == 9 { accepted = loop.recordAgain(identityKey: "Microsoft Teams") }
            }
            loop.start()

            await waitFor(harness.recorderStarts == 2 && loop.state == .recording, timeout: .seconds(5))
            XCTAssertTrue(accepted, label)
            XCTAssertEqual(harness.recordingStartTimes.last, 9, "\(label): at the poll after the click")
            XCTAssertEqual(harness.recordingStartCauses, [.regular, .recordAgain], label)
            XCTAssertEqual(loop.currentMeeting, teams, "\(label): the same meeting, process and title")
            XCTAssertEqual(harness.notifier.prompts.count, asksFirst ? 1 : 0, "\(label): not asked again")
            XCTAssertTrue(loop.appsHeldFromDetection.isEmpty, "\(label): the hold is lifted")
            XCTAssertTrue(loop.recordAgainOffers.isEmpty, label)
            // Exact lines, so no title rides along and no release follows the lift.
            XCTAssertEqual(
                harness.noticeLines,
                ["recording_stopped_by_hand trigger=auto", "redetect_hold_set app=Microsoft Teams", "record_again app=Microsoft Teams"],
                label,
            )
            loop.stop()
        }
    }

    // MARK: - R3, R4: the new recording ends like a detected one

    /// The issue's condition: the new recording ends with the call, leaves
    /// no hold, and the app's next call is detected and handled by its
    /// setting. Once for an app that records without asking, once for one
    /// that asks first.
    func testTheNextCallIsDetectedAfterARecordAgainRecordingEndsWithTheCall() async {
        for asksFirst in [false, true] {
            let label = asksFirst ? "asks first" : "records without asking"
            let harness = Harness()
            let queue = PipelineQueue(logDir: tmpDir)
            let loop = harness.makeLoop(queue: queue, recordWithoutAsking: asksFirst ? [] : ["Microsoft Teams"])
            harness.detector.call(teams)
            loop.start()
            await stopByHand("Microsoft Teams", loop)
            XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"), label)
            await waitFor(harness.recorderStarts == 2 && loop.state == .recording, timeout: .seconds(5))

            harness.detector.hangUp("Microsoft Teams")
            await waitFor(loop.state == .watching && queue.jobs.count == 2, timeout: .seconds(5))
            XCTAssertEqual(queue.jobs.count, 2, "\(label): the new recording is a job of its own")
            XCTAssertTrue(loop.appsHeldFromDetection.isEmpty, "\(label): no hold is left")
            XCTAssertTrue(loop.recordAgainOffers.isEmpty, label)
            XCTAssertEqual(
                harness.diagnostics.lines(.notice, startingWith: "recording_auto_stop").count, 1,
                "\(label): ended by the end grace and its question",
            )
            XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "redetect_hold_set").count, 1, label)

            harness.detector.call(teams)
            await waitFor(harness.recorderStarts == 3, timeout: .seconds(5))
            XCTAssertEqual(harness.recorderStarts, 3, "\(label): the next call is detected")
            XCTAssertEqual(harness.notifier.prompts.count, asksFirst ? 2 : 0, "\(label): and asked about as usual")
            XCTAssertEqual(harness.recordingStartCauses, [.regular, .recordAgain, .regular], label)
            loop.stop()
        }
    }

    /// The first part's job keeps the options it was recorded with; the new
    /// recording is its own job, named after the held meeting, with default
    /// options (A4).
    func testTheNewRecordingIsItsOwnJobWithDefaultOptions() async throws {
        let harness = Harness()
        harness.notifier.parksPrompts = true
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue, recordWithoutAsking: [])
        harness.detector.call(teams)
        loop.start()
        await waitFor(harness.notifier.isParked, timeout: .seconds(5))
        let question = try XCTUnwrap(loop.pendingConsentQuestion, "precondition: Teams is asked about")
        let options = MeetingProtocolOptions(template: .file(name: "Retro"), rawBackground: "Sprint 12")
        XCTAssertTrue(loop.answerParkedConsent(question, granted: true, protocolOptions: options))
        await stopByHand("Microsoft Teams", loop)

        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        await waitFor(harness.recorderStarts == 2 && loop.state == .recording, timeout: .seconds(5))
        XCTAssertTrue(loop.stopDetectedRecording())
        await waitFor(queue.jobs.count == 2, timeout: .seconds(5))

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Quarterly Review", "Quarterly Review"])
        XCTAssertEqual(queue.jobs.first?.protocolTemplate, .file(name: "Retro"), "the first part's job is unchanged")
        XCTAssertEqual(queue.jobs.first?.protocolBackground, "Sprint 12")
        XCTAssertEqual(queue.jobs.last?.protocolTemplate, .builtIn, "the default, as for a job without options")
        XCTAssertNil(queue.jobs.last?.protocolBackground)
        XCTAssertEqual(harness.notifier.prompts.count, 1)
        loop.stop()
    }

    /// Record-only: the new recording's WAVs and sidecar are written as a
    /// detected meeting's, labelled `auto` (A5).
    func testRecordOnlyWritesTheNewRecordingWithAnAutoTrigger() async throws {
        let harness = Harness()
        let first = try makeRecorderWithTracks(basename: "20261006_100000")
        let second = try makeRecorderWithTracks(basename: "20261006_101000")
        harness.nextRecorder = { h in h.recorderStarts == 1 ? first : second }
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue, recordOnlyTo: outputDir)
        harness.detector.call(teams)
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            if t == 2 { loop.stopDetectedRecording() }
            if t == 4 { loop.recordAgain(identityKey: "Microsoft Teams") }
            if t == 6 { loop.stopDetectedRecording() }
        }
        loop.start()

        await waitFor(loop.state == .watching && harness.recorderStarts == 2 && second.stopCalled, timeout: .seconds(5))
        loop.stop()

        XCTAssertTrue(queue.jobs.isEmpty, "record-only enqueues no job")
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: "20261006_101000"))
        XCTAssertEqual(sidecar.trigger, .auto)
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("20261006_101000\(suffix)").path))
        }
    }

    /// Three 5 s, 16 kHz tracks under `basename`, shaped like a dual-source
    /// recording, so record-only has files to write out.
    private func makeRecorderWithTracks(basename: String) throws -> MockRecorder {
        let recorder = MockRecorder()
        let samples = (0 ..< 5 * 16000).map { Float($0 % 1000) / 2000 }
        var urls: [URL] = []
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let url = tmpDir.appendingPathComponent("\(basename)\(suffix)")
            try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
            urls.append(url)
        }
        recorder.mixPath = urls[0]
        recorder.appPath = urls[1]
        recorder.micPath = urls[2]
        return recorder
    }
}
