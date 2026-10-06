import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// "The meeting seems to have ended": a detected meeting whose signal is gone
/// is asked about instead of stopped, and the recording runs on until the
/// person answers, the countdown runs out, the signal returns or watching
/// stops. Driven on `TestClock`, polling once a virtual second with a 10 s end
/// grace and the app's 2-minute countdown, so every timing below is exact and
/// no test waits in real time.
@MainActor
final class WatchLoopMeetingEndTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    /// A meeting signal the test switches on and off. `checkOnce` reports the
    /// meeting only when `detectable` is set, for the one test that goes
    /// through the real watch loop.
    private final class SwitchableSignal: MeetingDetecting {
        var active = false
        var detectable: DetectedMeeting?

        func checkOnce() -> DetectedMeeting? {
            detectable
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            active
        }

        func reset(appName _: String?) {}
    }

    /// Everything a loop under test talks to. `onTick` runs after every
    /// virtual second, before that second's poll, with the seconds since the
    /// clock started. It is handed the harness rather than capturing it, so
    /// no test builds a reference cycle.
    @MainActor
    private final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: start)
        let signal = SwitchableSignal()
        let notifier = RecordingNotifier()
        let diagnostics = RecordingDiagnostics()
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        private(set) var recorderStarts = 0

        func makeLoop(
            recorder: MockRecorder = makeMockRecorder(),
            queue: PipelineQueue? = nil,
            maxDuration: TimeInterval = 3600,
        ) -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
                await self.onTick(self, self.elapsed)
            }
            let loop = WatchLoop(
                detector: signal,
                recorderFactory: {
                    self.recorderStarts += 1
                    return recorder
                },
                pipelineQueue: queue,
                pollInterval: 1,
                endGracePeriod: 10,
                maxDuration: maxDuration,
                recordWithoutAskingApps: { ["Microsoft Teams"] },
                notifier: notifier,
                diagnostics: diagnostics,
                nowProvider: { self.clock.now },
                sleepProvider: sleepProvider,
            )
            loop.permissionChecker = { .allHealthy }
            return loop
        }

        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(Self.start)
        }

        var autoStopLines: [String] {
            diagnostics.lines(.notice, startingWith: "recording_auto_stop")
        }

        /// The ids of every question asked, and of every one taken back.
        var askedIDs: [String] {
            notifier.meetingEndQuestions.map(\.id)
        }

        /// Answer the first question the way a tap would.
        func answerFirstQuestion(_ answer: MeetingEndAnswer) {
            if let id = askedIDs.first {
                notifier.answerMeetingEndQuestion(id, with: answer)
            }
        }
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    private let meeting = DetectedMeeting(
        pattern: .teams,
        windowTitle: "Quarterly Review | Microsoft Teams",
        ownerName: "Microsoft Teams",
        windowPID: 4242,
    )

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "meeting-end")
    }

    // MARK: - Helpers

    /// Three 16 kHz tracks shaped like a dual-source recording, 30 s unless
    /// a test needs them to outlast the virtual clock.
    private func makeRecorderWithTracks(seconds: Int = 30) throws -> MockRecorder {
        let recorder = MockRecorder()
        let samples = (0 ..< seconds * 16000).map { Float($0 % 1000) / 2000 }
        var urls: [URL] = []
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let url = tmpDir.appendingPathComponent("20261006_100000\(suffix)")
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

    private func seconds(_ date: Date?) -> TimeInterval? {
        date?.timeIntervalSince(Harness.start)
    }

    // MARK: - R1 / R2 / R5 / R7: nobody answers

    /// The signal is gone from the first poll. At 10 s the person is asked and
    /// the recording keeps running; nobody answers (the question was never
    /// seen, or could not be shown), so at 130 s it ends, processed as before
    /// but cut back to the loss plus grace: 10 s of each track.
    func testAnUnansweredQuestionEndsTheRecordingCutBackToTheLossPlusGrace() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks()
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(recorder: recorder, queue: queue)
        var whileAsked: (phase: WatchLoop.State, stopped: Bool)?
        harness.onTick = { [weak loop] _, t in
            if t == 11, let loop { whileAsked = (loop.state, recorder.stopCalled) }
        }

        try await loop.handleMeeting(meeting)

        let question = try XCTUnwrap(harness.notifier.meetingEndQuestions.first)
        XCTAssertEqual(harness.askedIDs.count, 1, "asked once")
        XCTAssertEqual(question.title, "Meeting seems to have ended")
        XCTAssertEqual(question.body, "No sign of the Microsoft Teams call. The recording ends in 2 minutes.")
        XCTAssertEqual(whileAsked?.phase, .recording, "R1: the recording keeps running while asked")
        XCTAssertEqual(whileAsked?.stopped, false)
        XCTAssertEqual(harness.elapsed, 130, "ends at the deadline")

        XCTAssertEqual(queue.jobs.count, 1, "processed as before")
        XCTAssertEqual(queue.jobs.first?.mixPath, recorder.mixPath)
        XCTAssertEqual(try trackFrames(recorder), [160_000, 160_000, 160_000], "every track ends at the cut point")
        XCTAssertEqual(harness.notifier.withdrawnMeetingEndQuestions, [question.id], "the question is taken back")
        // Exact lines, so nothing else, a title least of all, rides along.
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=auto reason=countdown_expired signal_absent_s=130"])
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "recording_cut"), ["recording_cut kept_s=10"])
    }

    /// The audio began 10 s before capture reported running (the microphone
    /// opens before the app tap): the tracks run 140 s to the virtual clock's
    /// 130. The cut follows the audio, keeping 20 s, not the 10 s the clock
    /// alone would say, which would have cut into the meeting.
    func testTheCutFollowsTheAudioWhenItBeganBeforeCaptureReportedRunning() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks(seconds: 140)

        try await harness.makeLoop(recorder: recorder).handleMeeting(meeting)

        XCTAssertEqual(try trackFrames(recorder), [320_000, 320_000, 320_000])
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "recording_cut"), ["recording_cut kept_s=20"])
    }

    /// R2 error: a cut that fails leaves every track as recorded, the recording
    /// is processed uncut, and the failure is logged.
    func testAFailedCutProcessesTheRecordingUncutAndLogsIt() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks()
        try Data("not audio".utf8).write(to: XCTUnwrap(recorder.micPath))
        let paths = [recorder.mixPath, recorder.appPath, recorder.micPath]
        let originals = try paths.map { try Data(contentsOf: XCTUnwrap($0)) }
        let queue = PipelineQueue(logDir: tmpDir)

        try await harness.makeLoop(recorder: recorder, queue: queue).handleMeeting(meeting)

        XCTAssertEqual(try paths.map { try Data(contentsOf: XCTUnwrap($0)) }, originals, "every track as recorded")
        XCTAssertEqual(queue.jobs.count, 1, "never discarded")
        XCTAssertEqual(harness.diagnostics.lines(.warning, startingWith: "recording_cut_failed").count, 1)
    }

    // MARK: - R2: Stop now

    func testStopNowEndsAtTheNextPollCutBack() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 15 { h.answerFirstQuestion(.stopNow) }
        }

        let cutAt = try await loop.waitForMeetingEnd(meeting)

        XCTAssertEqual(seconds(cutAt), 10)
        XCTAssertEqual(harness.elapsed, 15, "ends at the poll after the answer")
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=auto reason=stop_now signal_absent_s=15"])
    }

    // MARK: - R3: the signal returns

    /// Back at 20 s: the question is taken back and the recording runs on as
    /// one. Lost again at 30 s: a fresh grace, a fresh question at 40 s. A tap
    /// on the first, withdrawn question then changes nothing, and the second
    /// one runs out at 160 s, cut back to 40 s.
    func testAReturningSignalWithdrawsTheQuestionAndALaterLossAsksAfresh() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 20 { h.signal.active = true }
            if t == 30 { h.signal.active = false }
            if t == 45 { h.answerFirstQuestion(.stopNow) }
        }

        let cutAt = try await loop.waitForMeetingEnd(meeting)

        let ids = harness.askedIDs
        XCTAssertEqual(ids.count, 2, "a fresh question after the second loss")
        XCTAssertEqual(Set(ids).count, 2, "under a fresh id")
        XCTAssertEqual(harness.notifier.withdrawnMeetingEndQuestions, ids, "the first when the signal came back, the second at the end")
        XCTAssertEqual(harness.elapsed, 160, "the stale Stop now did not end it at 46 s")
        XCTAssertEqual(seconds(cutAt), 40)
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=auto reason=countdown_expired signal_absent_s=130"])
    }

    // MARK: - R4: Keep recording

    /// Kept at 15 s: no cut, and nothing more is asked while the signal stays
    /// away; the cap ends the recording, uncut.
    func testKeepRecordingKeepsTheWholeRecordingUntilTheCap() async throws {
        let harness = Harness()
        let loop = harness.makeLoop(maxDuration: 600)
        harness.onTick = { h, t in
            if t == 15 { h.answerFirstQuestion(.keepRecording) }
        }

        let cutAt = try await loop.waitForMeetingEnd(meeting)

        XCTAssertNil(cutAt, "a kept recording is not cut")
        XCTAssertEqual(harness.askedIDs.count, 1, "no second question while the signal stays away")
        XCTAssertEqual(harness.elapsed, 601)
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=auto reason=max_duration signal_absent_s=601"])
    }

    /// After a Keep, a returning signal re-arms the question for the next loss.
    func testAfterKeepRecordingTheNextLossIsAskedAboutAgain() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.onTick = { h, t in
            if t == 15 { h.answerFirstQuestion(.keepRecording) }
            if t == 50 { h.signal.active = true }
            if t == 60 { h.signal.active = false }
        }

        let cutAt = try await loop.waitForMeetingEnd(meeting)

        XCTAssertEqual(harness.askedIDs.count, 2)
        XCTAssertEqual(harness.elapsed, 190, "asked again at 70 s, ended unanswered at 190 s")
        XCTAssertEqual(seconds(cutAt), 70)
    }

    /// R4 error: an answer arriving after the recording ended changes nothing.
    func testAnAnswerAfterTheRecordingEndedChangesNothing() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()
        try await loop.waitForMeetingEnd(meeting)

        harness.answerFirstQuestion(.stopNow)

        XCTAssertNil(loop.meetingEndAnswer, "nothing is parked for a later poll")
        XCTAssertNil(loop.meetingEndQuestionID)
    }

    // MARK: - R6: Stop Watching

    /// Stop Watching while the question is open ends the recording cut back
    /// and takes the question back. Before that, a manual start is refused
    /// while the question is open, as during any recording.
    func testStopWatchingDuringTheQuestionEndsCutBackAndWithdraws() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks()
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(recorder: recorder, queue: queue)
        harness.signal.detectable = meeting
        harness.signal.active = true
        var openWhenManualStartTried: Int?
        // Lost at 5 s, asked at 15 s, watching stopped at 30 s.
        harness.onTick = { [weak loop] h, t in
            guard let loop else { return }
            if t == 5 { h.signal.active = false }
            if t == 20 {
                openWhenManualStartTried = h.askedIDs.count - h.notifier.withdrawnMeetingEndQuestions.count
                try? await loop.startManualRecording(pid: 99, appName: "Zoom", title: "Other")
            }
            if t == 30 { loop.stop() }
        }

        loop.start()
        await waitFor(recorder.stopCalled, timeout: .seconds(5))

        XCTAssertEqual(openWhenManualStartTried, 1, "precondition: the question was open")
        XCTAssertEqual(harness.recorderStarts, 1, "the manual start was refused")
        XCTAssertNil(loop.manualRecordingInfo)
        XCTAssertEqual(queue.jobs.count, 1)
        // The meeting recorded from the first poll, so the cut keeps 15 s.
        XCTAssertEqual(try trackFrames(recorder), [240_000, 240_000, 240_000], "every track ends at the cut point")
        XCTAssertEqual(harness.notifier.withdrawnMeetingEndQuestions, harness.askedIDs, "the question is taken back")
        XCTAssertTrue(harness.autoStopLines.isEmpty, "stopping by hand is not an automatic stop")
    }

    /// R4: a Keep recording that arrived in time stands even when watching
    /// stops before the next poll could act on it, so the recording is kept
    /// whole rather than cut as an unanswered question would be.
    func testKeepRecordingAnsweredJustBeforeStopWatchingKeepsTheRecordingUncut() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks()
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(recorder: recorder, queue: queue)
        harness.signal.detectable = meeting
        harness.signal.active = true
        // Lost at 5 s, asked at 15 s; at 20 s Keep is tapped and watching stops
        // before any poll sees the answer.
        harness.onTick = { [weak loop] h, t in
            if t == 5 { h.signal.active = false }
            if t == 20 {
                h.answerFirstQuestion(.keepRecording)
                loop?.stop()
            }
        }

        loop.start()
        await waitFor(recorder.stopCalled, timeout: .seconds(5))

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(try trackFrames(recorder), [480_000, 480_000, 480_000], "kept whole, as the person chose")
        XCTAssertTrue(harness.diagnostics.lines(.notice, startingWith: "recording_cut").isEmpty, "nothing was cut")
    }

    // MARK: - The cap during the question

    func testTheCapReachedDuringTheQuestionEndsCutBack() async throws {
        let harness = Harness()
        let loop = harness.makeLoop(maxDuration: 50)

        let cutAt = try await loop.waitForMeetingEnd(meeting)

        XCTAssertEqual(seconds(cutAt), 10)
        XCTAssertEqual(harness.elapsed, 51)
        XCTAssertEqual(harness.notifier.withdrawnMeetingEndQuestions, harness.askedIDs)
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=auto reason=max_duration signal_absent_s=51"])
    }
}
