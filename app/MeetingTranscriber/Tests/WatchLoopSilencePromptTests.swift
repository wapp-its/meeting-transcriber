import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// "Nothing heard for 5 minutes. Stop the recording?" on a manual recording.
/// The question goes up once no recorded track has carried speech for the
/// configured time, an answer arrives out of band and is acted on at the next
/// poll, and every way the recording ends takes an open question back. Driven
/// on `TestClock`, polling once a virtual second, with the silence clock
/// injected in that clock's terms, so every timing below is exact and no test
/// waits in real time.
@MainActor
final class WatchLoopSilencePromptTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    /// Reports the microphone's offset against the app track, as
    /// `buildRecording` does.
    private final class DelayedMicRecorder: MockRecorder {
        var micDelay: TimeInterval = 0

        override func stop() throws -> RecordingResult {
            let result = try super.stop()
            return RecordingResult(
                mixPath: result.mixPath,
                appPath: result.appPath,
                micPath: result.micPath,
                micDelay: micDelay,
                recordingStartDate: result.recordingStartDate,
            )
        }
    }

    /// Everything a loop under test talks to. `onTick` runs after every
    /// virtual second, before that second's poll, with the seconds since the
    /// recording started. It is handed the harness rather than capturing it,
    /// so no test builds a reference cycle.
    @MainActor
    private final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: start)
        let notifier = RecordingNotifier()
        let diagnostics = RecordingDiagnostics()
        /// The configured silence; nil is switched off.
        var after: TimeInterval? = 300
        /// When speech was last heard, in seconds from the start; nil is never.
        var lastSpeech: TimeInterval?
        var appAlive = true
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        /// How many questions had been asked and taken back before the poll
        /// at each second.
        private(set) var beforePoll: [Int: (asked: Int, withdrawn: Int)] = [:]
        private(set) weak var loop: WatchLoop?

        func makeLoop(
            recorder: MockRecorder = makeMockRecorder(),
            queue: PipelineQueue? = nil,
            maxDuration: TimeInterval = 1_000_000,
            recordOnlyTo outputDir: URL? = nil,
        ) -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
                self.beforePoll[Int(self.elapsed)] = (self.askedIDs.count, self.withdrawnIDs.count)
                await self.onTick(self, self.elapsed)
            }
            let speechActivity: () -> SpeechActivity? = {
                SpeechActivity(observedSince: Self.start, lastSpeechAt: self.lastSpeech.map { Self.start.addingTimeInterval($0) })
            }
            let appAlive: (pid_t) -> Bool = { _ in self.appAlive }
            let loop = WatchLoop(
                recorderFactory: { recorder },
                pipelineQueue: queue,
                pollInterval: 1,
                maxDuration: maxDuration,
                recordOnly: { outputDir != nil },
                recordOnlyDestination: { .unscoped(outputDir ?? FileManager.default.temporaryDirectory) },
                speechActivity: speechActivity,
                silencePromptAfter: { self.after },
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

        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(Self.start)
        }

        var askedIDs: [String] {
            notifier.meetingEndQuestions.map(\.id)
        }

        var withdrawnIDs: [String] {
            notifier.withdrawnMeetingEndQuestions
        }

        /// The silence question's lines and the stop line, in the order written.
        var promptLines: [String] {
            diagnostics.lines.map(\.line).filter { $0.hasPrefix("silence_question") || $0.hasPrefix("recording_auto_stop") }
        }

        /// Answer the latest question the way a tap on its action would.
        func answerLatest(_ answer: MeetingEndAnswer) {
            if let id = askedIDs.last {
                notifier.answerMeetingEndQuestion(id, with: answer)
            }
        }
    }

    private static let basename = "20261014_100000"

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "silence-prompt")
    }

    // MARK: - Helpers

    /// Start a manual recording of a running app and wait until it has ended.
    private func record(_ loop: WatchLoop, title: String = "Weekly sync") async throws {
        try await loop.startManualRecording(pid: 42, appName: "Test", title: title)
        await waitFor(loop.snapshot.phase == .idle, timeout: .seconds(10))
        XCTAssertEqual(loop.snapshot.phase, .idle, "precondition: the recording ended")
    }

    /// Mix, app and microphone tracks of `seconds` at 16 kHz.
    private func makeRecorderWithTracks(seconds: Int, micDelay: TimeInterval = 0, in dir: URL? = nil) throws -> DelayedMicRecorder {
        let recorder = DelayedMicRecorder()
        recorder.micDelay = micDelay
        let samples = (0 ..< seconds * 16000).map { Float($0 % 1000) / 2000 }
        let urls = try [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic].map { suffix in
            let url = (dir ?? tmpDir).appendingPathComponent("\(Self.basename)\(suffix)")
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

    // MARK: - R1: the question

    /// Nothing before the configured five minutes, one question at them,
    /// worded as the spec has it.
    func testNoQuestionBeforeTheConfiguredSilenceAndOneAtIt() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 305 { h.loop?.stopManualRecording() }
        }

        try await record(loop)

        XCTAssertEqual(harness.beforePoll[300]?.asked, 0, "nothing at 299 s")
        XCTAssertEqual(harness.beforePoll[301]?.asked, 1, "one at 300 s")
        XCTAssertEqual(harness.askedIDs.count, 1, "asked once")
        let question = try XCTUnwrap(harness.notifier.meetingEndQuestions.first)
        XCTAssertEqual(question.title, "Nothing heard for 5 minutes")
        XCTAssertEqual(question.body, "Stop the recording? Without an answer, it keeps recording.")
    }

    // MARK: - R2: Stop now

    /// Speech last heard at 5 s, asked at 25 s, "Stop now" at 27 s. The
    /// recording ends at that poll and is processed like the menu's Stop
    /// Recording, every track cut to 15 s of the recording's timeline: the
    /// microphone, placed 2 s into it, keeps 13 s of its own.
    func testStopNowEndsTheRecordingCutTenSecondsAfterTheLastSpeech() async throws {
        let harness = Harness()
        harness.after = 20
        harness.lastSpeech = 5
        let recorder = try makeRecorderWithTracks(seconds: 27, micDelay: 2)
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(recorder: recorder, queue: queue)
        harness.onTick = { h, t in
            if t == 27 { h.answerLatest(.stopNow) }
        }

        try await record(loop)

        XCTAssertEqual(harness.elapsed, 27, "ends at the poll after the answer")
        XCTAssertNil(loop.manualRecordingInfo)
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1, "processed like the menu's Stop Recording")
        XCTAssertEqual(queue.jobs.first?.mixPath, recorder.mixPath)
        XCTAssertEqual(try trackFrames(recorder), [240_000, 240_000, 208_000], "every track ends at 15 s of the timeline")
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "recording_cut"), ["recording_cut kept_s=15"])
    }

    /// Record-only: the sidecar stops where the tracks were cut.
    func testStopNowInRecordOnlyModeStopsTheSidecarAtTheCut() async throws {
        let harness = Harness()
        harness.after = 20
        harness.lastSpeech = 5
        let recorder = try makeRecorderWithTracks(seconds: 27)
        recorder.recordingStartDate = Harness.start
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let loop = harness.makeLoop(recorder: recorder, recordOnlyTo: outputDir)
        harness.onTick = { h, t in
            if t == 27 { h.answerLatest(.stopNow) }
        }

        try await record(loop)

        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename))
        XCTAssertEqual(sidecar.stoppedAt, Harness.start.addingTimeInterval(15), "the cut point, not the stop")
        XCTAssertEqual(sidecar.trigger, .manual)
        let mix = try AVAudioFile(forReading: outputDir.appendingPathComponent("\(Self.basename)\(RecordingFileSuffix.mix)"))
        XCTAssertEqual(mix.length, 240_000)
    }

    /// Error: with no speech heard at all there is nothing to trim towards,
    /// and the recording is processed whole.
    func testARecordingWithNoSpeechIsStoppedUncut() async throws {
        let harness = Harness()
        harness.after = 20
        let recorder = try makeRecorderWithTracks(seconds: 22)
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(recorder: recorder, queue: queue)
        harness.onTick = { h, t in
            if t == 22 { h.answerLatest(.stopNow) }
        }

        try await record(loop)

        XCTAssertEqual(harness.elapsed, 22, "stopped by the answer")
        XCTAssertEqual(try trackFrames(recorder), [352_000, 352_000, 352_000], "every track as recorded")
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertTrue(harness.diagnostics.lines(.notice, startingWith: "recording_cut").isEmpty)
    }

    /// Error: speech heard at 26 s, just before the "Stop now" that the 27 s
    /// poll acts on. Last speech plus ten seconds lies past the stop, so every
    /// track is kept whole and the record-only sidecar stops at the real stop,
    /// not at a point the files do not reach.
    func testSpeechJustBeforeStopNowLeavesTheRecordingUncut() async throws {
        let harness = Harness()
        harness.after = 20
        harness.lastSpeech = 5
        let recorder = try makeRecorderWithTracks(seconds: 27)
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let loop = harness.makeLoop(recorder: recorder, recordOnlyTo: outputDir)
        harness.onTick = { h, t in
            if t == 27 {
                h.lastSpeech = 26
                h.answerLatest(.stopNow)
            }
        }
        // The sidecar keeps whole seconds.
        let before = Date().addingTimeInterval(-1)

        try await record(loop)

        let realStop = Date()
        XCTAssertEqual(harness.elapsed, 27, "the answer still stops it")
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let file = try AVAudioFile(forReading: outputDir.appendingPathComponent("\(Self.basename)\(suffix)"))
            XCTAssertEqual(file.length, 432_000, "\(suffix) is kept whole")
        }
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename))
        XCTAssertLessThanOrEqual(sidecar.stoppedAt, realStop, "never later than the real stop")
        XCTAssertGreaterThanOrEqual(sidecar.stoppedAt, before)
    }

    /// Error: a cut that fails leaves every track as recorded, and the
    /// recording is still processed.
    func testAFailedCutProcessesTheRecordingUncut() async throws {
        let harness = Harness()
        harness.after = 20
        harness.lastSpeech = 5
        let recorder = try makeRecorderWithTracks(seconds: 27)
        try Data("not audio".utf8).write(to: XCTUnwrap(recorder.micPath))
        let paths = [recorder.mixPath, recorder.appPath, recorder.micPath]
        let originals = try paths.map { try Data(contentsOf: XCTUnwrap($0)) }
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(recorder: recorder, queue: queue)
        harness.onTick = { h, t in
            if t == 27 { h.answerLatest(.stopNow) }
        }

        try await record(loop)

        XCTAssertEqual(try paths.map { try Data(contentsOf: XCTUnwrap($0)) }, originals, "every track as recorded")
        XCTAssertEqual(queue.jobs.count, 1, "never discarded")
        XCTAssertEqual(harness.diagnostics.lines(.warning, startingWith: "recording_cut_failed").count, 1)
    }

    // MARK: - R3 / R4: speech, Keep recording, no answer

    /// "Keep recording" at 310 s takes the question back, and the next one
    /// comes five minutes after the answer, at 610 s, stating the whole
    /// silence.
    func testKeepRecordingWithdrawsAndTheNextQuestionComesAFullPeriodAfterTheAnswer() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 310 { h.answerLatest(.keepRecording) }
            if t == 615 { h.loop?.stopManualRecording() }
        }

        try await record(loop)

        let ids = harness.askedIDs
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(harness.beforePoll[310]?.withdrawn, 0)
        XCTAssertEqual(harness.beforePoll[311]?.withdrawn, 1, "taken back at the answer's poll")
        XCTAssertEqual(harness.beforePoll[610]?.asked, 1, "nothing until a full period after the answer")
        XCTAssertEqual(harness.beforePoll[611]?.asked, 2)
        XCTAssertEqual(harness.notifier.meetingEndQuestions.last?.title, "Nothing heard for 10 minutes")
        XCTAssertEqual(harness.withdrawnIDs, ids, "the first at the answer, the second when the recording ended")
    }

    /// A question nobody answers stays until a fresh one replaces it after
    /// another five minutes, stating the longer silence.
    func testAnUnansweredQuestionIsReplacedAfterAnotherPeriod() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 605 { h.loop?.stopManualRecording() }
        }

        try await record(loop)

        let ids = harness.askedIDs
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "under a fresh id")
        XCTAssertEqual(harness.beforePoll[600]?.withdrawn, 0, "open until it is replaced")
        XCTAssertEqual(harness.beforePoll[601]?.withdrawn, 1, "taken back as the fresh one goes up")
        XCTAssertEqual(harness.beforePoll[601]?.asked, 2)
        XCTAssertEqual(harness.notifier.meetingEndQuestions.last?.title, "Nothing heard for 10 minutes")
        XCTAssertEqual(harness.withdrawnIDs, ids)
    }

    /// Speech heard at 319 s takes the question back at the next poll, and the
    /// next one comes only after another five minutes without speech.
    func testSpeechWithdrawsTheQuestion() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 320 { h.lastSpeech = 319 }
            if t == 625 { h.loop?.stopManualRecording() }
        }

        try await record(loop)

        XCTAssertEqual(harness.beforePoll[320]?.withdrawn, 0)
        XCTAssertEqual(harness.beforePoll[321]?.withdrawn, 1, "taken back at the first poll that heard it")
        XCTAssertEqual(harness.beforePoll[619]?.asked, 1)
        XCTAssertEqual(harness.beforePoll[620]?.asked, 2, "five minutes after the speech")
        XCTAssertEqual(harness.notifier.meetingEndQuestions.last?.title, "Nothing heard for 5 minutes")
    }

    /// Errors: a tap on a question that was replaced, on one speech took back,
    /// or on one whose recording has ended changes nothing.
    func testAnAnswerToAQuestionNoLongerOpenChangesNothing() async throws {
        let harness = Harness()
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            if t == 605, let replaced = h.askedIDs.first {
                h.notifier.answerMeetingEndQuestion(replaced, with: .stopNow)
            }
            if t == 620 { h.lastSpeech = 619 }
            if t == 625 { h.answerLatest(.stopNow) }
            if t == 630 { h.loop?.stopManualRecording() }
        }

        try await record(loop)
        harness.answerLatest(.stopNow)
        await Task.yield()

        XCTAssertEqual(harness.elapsed, 630, "no stale Stop now ended it")
        XCTAssertEqual(harness.askedIDs.count, 2)
        XCTAssertTrue(harness.diagnostics.lines(.notice, startingWith: "recording_auto_stop").isEmpty)
        XCTAssertEqual(queue.jobs.count, 1, "one recording, processed once")
        XCTAssertEqual(loop.snapshot.phase, .idle)
    }

    // MARK: - R6 / R7: the setting, and every other end

    /// The setting is read at every poll. Lowered from ten minutes to five at
    /// 300 s, it asks at that poll; switched off at 310 s, it takes the
    /// question back at that poll and asks nothing more.
    func testTheSettingIsReadAtEveryPoll() async throws {
        let harness = Harness()
        harness.after = 600
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 300 { h.after = 300 }
            if t == 310 { h.after = nil }
            if t == 1000 { h.loop?.stopManualRecording() }
        }

        try await record(loop)

        XCTAssertEqual(harness.beforePoll[300]?.asked, 0)
        XCTAssertEqual(harness.beforePoll[301]?.asked, 1, "the lower value applies at the next poll")
        XCTAssertEqual(harness.beforePoll[310]?.withdrawn, 0)
        XCTAssertEqual(harness.beforePoll[311]?.withdrawn, 1, "switched off: taken back at the next poll")
        XCTAssertEqual(harness.askedIDs.count, 1, "nothing asked while off")
        XCTAssertEqual(harness.withdrawnIDs, harness.askedIDs)
    }

    /// Every other way a manual recording ends (the menu's Stop Recording, the
    /// recorded app quitting, the duration cap, quitting the app) ends it as
    /// before, uncut, and takes the open question back, even with a "Stop now"
    /// waiting for the poll that the end comes first at.
    func testEveryOtherEndWithdrawsTheQuestionAndKeepsTheRecordingUncut() async throws {
        let ends: [(name: String, maxDuration: TimeInterval, end: @MainActor (Harness) -> Void)] = [
            ("menu Stop Recording", 1_000_000, { $0.loop?.stopManualRecording() }),
            ("recorded app quits", 1_000_000, { $0.appAlive = false }),
            ("duration cap", 26, { _ in }),
            ("app quits", 1_000_000, { $0.loop?.stop() }),
        ]
        for (name, maxDuration, end) in ends {
            let harness = Harness()
            harness.after = 20
            harness.lastSpeech = 5
            let recorder = try makeRecorderWithTracks(seconds: 27, in: makeTempDirectory(prefix: "silence-end"))
            let loop = harness.makeLoop(recorder: recorder, maxDuration: maxDuration)
            harness.onTick = { h, t in
                if t == 27 {
                    h.answerLatest(.stopNow)
                    end(h)
                }
            }

            try await record(loop)

            XCTAssertEqual(harness.askedIDs.count, 1, "\(name): precondition, a question was open")
            XCTAssertEqual(harness.withdrawnIDs, harness.askedIDs, "\(name): taken back")
            XCTAssertEqual(harness.promptLines.last, "silence_question_withdrawn trigger=manual reason=ended", name)
            XCTAssertEqual(try trackFrames(recorder), [432_000, 432_000, 432_000], "\(name): uncut")
            XCTAssertTrue(harness.diagnostics.lines(.notice, startingWith: "recording_cut").isEmpty, name)
        }
    }

    // MARK: - R8: the log

    /// One line per question posted, per withdrawal with its reason, and for
    /// the stop, with the silence in whole seconds where it applies, and none
    /// naming the recording.
    func testTheLogLinesNameReasonsAndSilenceButNeverTheTitle() async throws {
        let harness = Harness()
        harness.after = 20
        let loop = try harness.makeLoop(recorder: makeRecorderWithTracks(seconds: 40))
        harness.onTick = { h, t in
            if t == 25 { h.lastSpeech = 24 }
            if t == 45 { h.answerLatest(.keepRecording) }
            if t == 87 { h.answerLatest(.stopNow) }
        }

        try await record(loop, title: "Zanzibar Merger Review")

        XCTAssertEqual(harness.promptLines, [
            "silence_question_posted trigger=manual silent_s=20",
            "silence_question_withdrawn trigger=manual reason=speech",
            "silence_question_posted trigger=manual silent_s=20",
            "silence_question_withdrawn trigger=manual reason=kept",
            "silence_question_posted trigger=manual silent_s=41",
            "silence_question_withdrawn trigger=manual reason=replaced",
            "silence_question_posted trigger=manual silent_s=61",
            "recording_auto_stop trigger=manual reason=silence_stop silent_s=63",
        ])
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "recording_cut"), ["recording_cut kept_s=34"])
        let lines = harness.diagnostics.lines.map(\.line)
        XCTAssertFalse(lines.contains { $0.contains("Zanzibar") }, "\(lines)")
    }

    // MARK: - WatchingController wiring

    /// The manual loop the controller builds reads the silence clock from
    /// channel health and the setting at every call. A microphone at -20 dBFS
    /// is speech.
    func testTheManualLoopReadsChannelHealthAndTheSetting() async throws {
        let recorder = makeMockRecorder()
        recorder.micLevelDBFS = -20
        let controller = makeWatchingController(
            // Labelled: a trailing closure would bind to `makeDetector`.
            // swiftlint:disable:next trailing_closure
            logDir: tmpDir, permissionHealth: .allHealthy, makeRecorder: { recorder },
        )
        addTeardownBlock { await controller.stopManualRecording() }

        controller.startMicrophoneRecording()

        try await assertReadsChannelHealthAndTheSetting(controller)
    }

    /// The same for the loop that watches for meetings.
    func testTheWatchingLoopReadsChannelHealthAndTheSetting() async throws {
        let recorder = makeMockRecorder()
        recorder.micLevelDBFS = -20
        let controller = makeWatchingController(
            logDir: tmpDir, permissionHealth: .allHealthy,
            makeDetector: { FixedMeetingDetector() }, makeRecorder: { recorder },
        )
        controller.settings.recordWithoutAskingApps = [testMeetingApp]
        addTeardownBlock { _ = await controller.stopWatching() }

        let started = await controller.startWatching()

        XCTAssertEqual(started, .changed, "precondition")
        try await assertReadsChannelHealthAndTheSetting(controller)
    }

    private func assertReadsChannelHealthAndTheSetting(_ controller: WatchingController) async throws {
        await waitFor(controller.watchLoop?.silencePrompt.speechActivity()?.lastSpeechAt != nil, timeout: .seconds(5))
        let prompt = try XCTUnwrap(controller.watchLoop?.silencePrompt)
        XCTAssertNotNil(prompt.speechActivity()?.lastSpeechAt, "the channel-health clock heard the microphone")
        XCTAssertEqual(prompt.after(), 300)
        controller.settings.silencePromptMinutes = 7
        XCTAssertEqual(prompt.after(), 420, "read at every call")
        controller.settings.silencePromptEnabled = false
        XCTAssertNil(prompt.after())
    }
}
