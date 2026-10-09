// swiftlint:disable file_length
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
    private func makeRecorderWithTracks(seconds: Int = 30) throws -> StoreOrderRecorder {
        let recorder = StoreOrderRecorder()
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

    /// Notes how many questions had gone out at each store of a cut, which
    /// says whether the cut was stored before its question was posted.
    private final class StoreOrderRecorder: MockRecorder {
        var questionsPosted: () -> Int = { 0 }
        private(set) var postedAtStore: [Int] = []

        override func storePendingCut(cutAt: Date, deadline: Date, startedAt: Date) throws {
            postedAtStore.append(questionsPosted())
            try super.storePendingCut(cutAt: cutAt, deadline: deadline, startedAt: startedAt)
        }
    }

    /// Reports how its mix was made, as `buildRecording` does.
    private final class MixReportingRecorder: MockRecorder {
        var levelBalanced = false

        override func stop() throws -> RecordingResult {
            var result = try super.stop()
            result.levelBalanced = levelBalanced
            return result
        }
    }

    /// The headset-gap meeting (24 s), then the 2-minute question countdown,
    /// in which someone still in the room talks loudly into the microphone,
    /// mixed the way `stop()` mixes it. With the signal gone from the first
    /// poll the cut keeps exactly the meeting: 144 s of audio stopped at
    /// 130 s and cut at 10 s keep 24 s.
    private func makeRecorderWithLoudTail(in dir: URL, balanced: Bool, withApp: Bool) throws -> MixReportingRecorder {
        typealias Signal = LevelBalanceSignal
        let farEnd = HeadsetGapFixture.farEnd + Signal.noise(dBFS: -70, seconds: 120, seed: 31)
        var ownVoice = HeadsetGapFixture.ownVoice + Signal.noise(dBFS: -70, seconds: 120, seed: 32)
        for k in 0 ..< 40 {
            Signal.place(Signal.tone(dBFS: -10, seconds: 1), in: &ownVoice, at: 24 + Double(3 * k) + 1.5)
        }
        let recorder = MixReportingRecorder()
        recorder.levelBalanced = balanced
        let stem = dir.appendingPathComponent("20261006_100000").path
        let mix = URL(fileURLWithPath: stem + RecordingFileSuffix.mix)
        let mic = URL(fileURLWithPath: stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: ownVoice, sampleRate: Signal.sampleRate, url: mic)
        if withApp {
            let app = URL(fileURLWithPath: stem + RecordingFileSuffix.app)
            try AudioMixer.saveWAV(samples: farEnd, sampleRate: Signal.sampleRate, url: app)
            try AudioMixer.mix(appAudioPath: app, micAudioPath: mic, outputPath: mix, levelBalance: balanced)
            recorder.appPath = app
        } else {
            try AudioMixer.saveWAV(samples: ownVoice, sampleRate: Signal.sampleRate, url: mix)
        }
        recorder.mixPath = mix
        recorder.micPath = mic
        return recorder
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
        XCTAssertEqual(recorder.calls.suffix(2), [resolved(keeping: 10, endedAt: 130), .clearPendingCut], "cleared all the same")
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
        // Settled although Stop Watching let go of the active recorder first.
        XCTAssertEqual(recorder.calls, [.start, stored(cutAt: 15), .stop, resolved(keeping: 15, endedAt: 30), .clearPendingCut])
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
        XCTAssertEqual(recorder.calls, [.start, stored(cutAt: 15), .clearPendingCut, .stop], "cleared before the stop")
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

    // MARK: - A balanced mix after the cut

    /// The stop balanced the mix over everything recorded, the loud tail
    /// included. The cut throws the tail away, so its gains must go with it:
    /// the mix is made again from the kept tracks, and the own voice and the
    /// far end sit within 6 dB.
    func testACutBalancedMixIsMadeAgainFromTheKeptTracks() async throws {
        let recorder = try makeRecorderWithLoudTail(in: tmpDir, balanced: true, withApp: true)
        let asRecorded = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(recorder.mixPath))
        XCTAssertGreaterThan(
            abs(HeadsetGapFixture.gap(in: asRecorded)), 6,
            "test premise: gains measured with the tail leave the meeting apart",
        )

        try await Harness().makeLoop(recorder: recorder).handleMeeting(meeting)

        let mix = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(recorder.mixPath))
        XCTAssertEqual(mix.count, 24 * 16000, "the mix ends where the meeting did")
        XCTAssertLessThanOrEqual(abs(HeadsetGapFixture.gap(in: mix)), 6)
    }

    /// A mix made without the balance, and a single-track one, are only cut:
    /// the meeting's frames as recorded.
    func testAnUnbalancedOrSingleTrackMixIsOnlyCut() async throws {
        for (balanced, withApp) in [(false, true), (true, false)] {
            let dir = try makeTempDirectory(prefix: "meeting-end-mix")
            let recorder = try makeRecorderWithLoudTail(in: dir, balanced: balanced, withApp: withApp)
            let asRecorded = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(recorder.mixPath))

            try await Harness().makeLoop(recorder: recorder).handleMeeting(meeting)

            XCTAssertEqual(
                try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(recorder.mixPath)),
                Array(asRecorded.prefix(24 * 16000)),
                "balanced \(balanced), app track \(withApp)",
            )
        }
    }
}

// MARK: - The stored cut

/// While the question is open its cut is stored with the recording, so a crash
/// while asking still ends the recording there, and every end settles it. Read
/// from the recorder's call log.
extension WatchLoopMeetingEndTests {
    private typealias Tick = @MainActor (Harness, WatchLoop?, TimeInterval) -> Void

    private static let ioError = NSError(domain: NSPOSIXErrorDomain, code: 5)

    private func at(_ seconds: TimeInterval) -> Date {
        Harness.start.addingTimeInterval(seconds)
    }

    /// The cut stored by a question asked at `cutAt`, which is the loss plus
    /// grace, in a recording started at 0 s.
    private func stored(cutAt: TimeInterval = 10) -> MockRecorder.Call {
        .storePendingCut(cutAt: at(cutAt), deadline: at(cutAt + 120), startedAt: Harness.start)
    }

    private func resolved(keeping seconds: TimeInterval, endedAt: TimeInterval) -> MockRecorder.Call {
        .recordPendingCutResolution(keptSeconds: seconds, captureEndedAt: at(endedAt))
    }

    /// One meeting through `handleMeeting`, its signal gone from the first
    /// poll. Returns whether it threw: a failing stop is under test here.
    @discardableResult
    private func record(
        _ recorder: MockRecorder,
        on harness: Harness = Harness(),
        maxDuration: TimeInterval = 3600,
        onTick: @escaping Tick = { _, _, _ in },
    ) async -> Bool {
        let loop = harness.makeLoop(recorder: recorder, maxDuration: maxDuration)
        harness.onTick = { [weak loop] h, t in onTick(h, loop, t) }
        do {
            try await loop.handleMeeting(meeting)
            return false
        } catch {
            return true
        }
    }

    /// The cut is stored before the question goes out; after the stop, with
    /// every track still whole, the stored cut learns where the cut lands and
    /// when capture ended; after the cut it is cleared once. Stop now keeps
    /// 25 s, not 10: the 30 s tracks outlast the clock's 15 s.
    func testAnEndOutOfTheQuestionResolvesTheStoredCutBeforeCuttingAndClearsItAfter() async throws {
        let ends: [(name: String, maxDuration: TimeInterval, kept: TimeInterval, act: Tick)] = [
            ("countdown expiry", 3600, 10, { _, _, _ in }),
            ("Stop now", 3600, 25, { h, _, t in if t == 15 { h.answerFirstQuestion(.stopNow) } }),
            ("the cap", 50, 10, { _, _, _ in }),
            ("a stop by hand", 3600, 10, { _, loop, t in if t == 30 { loop?.stopDetectedRecording() } }),
        ]
        for (name, maxDuration, kept, act) in ends {
            tmpDir = try makeTempDirectory(prefix: "meeting-end-stored")
            let harness = Harness()
            let recorder = try makeRecorderWithTracks()
            recorder.questionsPosted = { harness.askedIDs.count }
            var framesAtResolution: [AVAudioFramePosition] = []
            recorder.duringPendingCutResolution = { [weak recorder] in
                framesAtResolution = recorder.flatMap { try? self.trackFrames($0) } ?? []
            }

            await record(recorder, on: harness, maxDuration: maxDuration, onTick: act)

            let stoppedAt = harness.elapsed
            XCTAssertEqual(recorder.postedAtStore, [0], "\(name): stored before the question is posted")
            XCTAssertEqual(recorder.calls, [.start, stored(), .stop, resolved(keeping: kept, endedAt: stoppedAt), .clearPendingCut], name)
            XCTAssertEqual(framesAtResolution, [480_000, 480_000, 480_000], "\(name): resolved before any track is cut")
            let frames = AVAudioFramePosition(kept * 16000)
            XCTAssertEqual(try trackFrames(recorder), [frames, frames, frames], "\(name): cut to the resolved seconds")
        }
    }

    /// Each failure of the stored cut is logged with domain and code and no
    /// path, and the countdown still ends the recording cut back as before.
    func testAFailedWriteOrRemovalOfTheStoredCutIsLoggedAndTheRecordingStillCut() async throws {
        let unlink = NSError(domain: NSCocoaErrorDomain, code: 513)
        let write = { (published: Bool) in PendingCutWriteError(published: published, underlying: Self.ioError) }
        let (io, denied) = ("domain=NSPOSIXErrorDomain code=5", "domain=NSCocoaErrorDomain code=513")
        let failures: [(fail: @MainActor (MockRecorder) -> Void, line: String)] = [
            ({ $0.storePendingCutError = write(false) }, "pending_cut_write_failed \(io) published=false"),
            ({ $0.recordPendingCutResolutionError = write(true) }, "pending_cut_write_failed \(io) published=true"),
            ({ $0.clearPendingCutOutcome = .removedNotSynced(Self.ioError) }, "pending_cut_remove_failed \(io) emptied=false"),
            ({ $0.clearPendingCutOutcome = .emptied(unlinkError: unlink) }, "pending_cut_remove_failed \(denied) emptied=true"),
            ({ $0.clearPendingCutOutcome = .failed(unlinkError: unlink, emptyError: Self.ioError) }, "pending_cut_remove_failed \(denied) emptied=false"),
        ]
        for (fail, line) in failures {
            tmpDir = try makeTempDirectory(prefix: "meeting-end-stored-failure")
            let harness = Harness()
            let recorder = try makeRecorderWithTracks()
            fail(recorder)

            await record(recorder, on: harness)

            XCTAssertEqual(harness.diagnostics.lines(.warning, startingWith: "pending_cut"), [line])
            XCTAssertEqual(harness.elapsed, 130, line)
            XCTAssertEqual(try trackFrames(recorder), [160_000, 160_000, 160_000], "\(line): cut back as before")
            XCTAssertEqual(recorder.calls.last, .clearPendingCut, line)
        }
    }

    /// Keep recording and a returning signal clear the stored cut at once,
    /// also after a store that failed with its record published. The cap then
    /// ends the recording uncut and clears again, before the stop.
    func testASettledQuestionClearsItsStoredCutAtOnceEvenAfterAFailedStore() async {
        let settles: [(name: String, act: Tick)] = [
            ("Keep recording", { h, _, t in if t == 15 { h.answerFirstQuestion(.keepRecording) } }),
            ("a returning signal", { h, _, t in if t == 20 { h.signal.active = true } }),
        ]
        for (name, act) in settles {
            for storeFails in [false, true] {
                let recorder = makeMockRecorder()
                if storeFails { recorder.storePendingCutError = PendingCutWriteError(published: true, underlying: Self.ioError) }

                await record(recorder, maxDuration: 30, onTick: act)

                XCTAssertEqual(recorder.calls, [.start, stored(), .clearPendingCut, .clearPendingCut, .stop], "\(name), store failed: \(storeFails)")
            }
        }
    }

    /// The signal returns at 20 s and the stored cut goes with the question;
    /// lost again at 30 s, the fresh question stores the new cut point.
    func testALaterLossStoresAFreshCutAfterAReturningSignalClearedTheFirst() async throws {
        let recorder = try makeRecorderWithTracks()

        await record(recorder) { h, _, t in
            if t == 20 { h.signal.active = true }
            if t == 30 { h.signal.active = false }
        }

        XCTAssertEqual(recorder.calls, [
            .start, stored(), .clearPendingCut, stored(cutAt: 40), .stop, resolved(keeping: 40, endedAt: 160), .clearPendingCut,
        ])
    }

    /// A stop that carries no cut clears the stored cut before the recorder
    /// stops, so it is cleared even when the stop throws.
    func testAStopWithoutACutClearsTheStoredCutBeforeTheRecorderStops() async {
        let stops: [(name: String, maxDuration: TimeInterval, act: Tick, calls: [MockRecorder.Call])] = [
            (
                "the cap on the poll that sees a Keep",
                50,
                { h, _, t in if t == 51 { h.answerFirstQuestion(.keepRecording) } },
                [.start, stored(), .clearPendingCut, .stop],
            ),
            (
                "a stop by hand before any question",
                3600,
                { _, loop, t in if t == 5 { loop?.stopDetectedRecording() } },
                [.start, .clearPendingCut, .stop],
            ),
        ]
        for (name, maxDuration, act, calls) in stops {
            for stopThrows in [false, true] {
                let recorder = makeMockRecorder()
                if stopThrows { recorder.mixPath = nil }

                let threw = await record(recorder, maxDuration: maxDuration, onTick: act)

                XCTAssertEqual(threw, stopThrows, name)
                XCTAssertEqual(recorder.calls, calls, "\(name), stop throws: \(stopThrows)")
            }
        }
    }

    /// A stop that carries a cut and throws clears nothing: the stored cut
    /// goes to recovery with the recording.
    func testACutCarryingStopThatThrowsClearsNothing() async {
        let recorder = makeMockRecorder()
        recorder.mixPath = nil

        let threw = await record(recorder)

        XCTAssertTrue(threw)
        XCTAssertEqual(recorder.calls, [.start, stored(), .stop])
    }

    func testAManualRecordingStoresNoCut() async throws {
        let recorder = makeMockRecorder()
        let loop = Harness().makeLoop(recorder: recorder)

        try await loop.startMicrophoneRecording()
        loop.stopManualRecording()

        XCTAssertEqual(recorder.calls, [.start, .stop])
    }
}
