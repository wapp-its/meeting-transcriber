import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// A paused recording at its end. A cut back from the meeting-end question or
/// the long-silence question lands on the saved tracks' timeline, which leaves
/// the paused time out, and the job and the record-only sidecar carry the
/// pauses clipped at the cut time; a failed cut keeps them as recorded. Driven
/// on `TestClock`, polling once a virtual second with a 10 s end grace and a
/// 40 s countdown, so every timing below is exact, with tracks as long as the
/// audio the capture would have saved.
@MainActor
final class WatchLoopPauseEndTests: XCTestCase {
    private static let basename = "20261014_100000"

    private let meeting = DetectedMeeting(
        pattern: .teams,
        windowTitle: "Quarterly Review | Microsoft Teams",
        ownerName: "Microsoft Teams",
        windowPID: 4242,
    )

    /// Pause and resume times in seconds from the start; a pause without a
    /// resume runs to the stop.
    private typealias Spans = [(pause: TimeInterval, resume: TimeInterval?)]

    // MARK: - Helpers

    private func pause(_ start: TimeInterval, _ end: TimeInterval, offset: TimeInterval) -> RecordingPause {
        RecordingPause(startedAt: EndHarness.at(start), endedAt: EndHarness.at(end), offsetSeconds: offset)
    }

    /// Mix, app and microphone tracks of `seconds` at 16 kHz in a directory of
    /// their own, handed to the harness's recorder.
    private func giveTracks(to harness: EndHarness, seconds: Int) throws {
        let dir = try makeTempDirectory(prefix: "pause-end")
        let samples = (0 ..< seconds * 16000).map { Float($0 % 1000) / 2000 }
        let urls = try [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic].map { suffix in
            let url = dir.appendingPathComponent("\(Self.basename)\(suffix)")
            try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
            return url
        }
        harness.recorder.mixPath = urls[0]
        harness.recorder.appPath = urls[1]
        harness.recorder.micPath = urls[2]
    }

    private func trackFrames(_ recorder: MockRecorder) throws -> [AVAudioFramePosition] {
        try [recorder.mixPath, recorder.appPath, recorder.micPath].map { url in
            try AVAudioFile(forReading: XCTUnwrap(url)).length
        }
    }

    private func makeQueue() throws -> PipelineQueue {
        try PipelineQueue(logDir: makeTempDirectory(prefix: "pause-end-queue"))
    }

    /// Pause and resume at `spans` on each tick, as the menu would.
    private func act(on spans: Spans, _ harness: EndHarness, _ t: TimeInterval) {
        for span in spans {
            if t == span.pause { _ = harness.loop?.pauseRecording() }
            if t == span.resume { _ = harness.loop?.resumeRecording() }
        }
    }

    /// Record the meeting through `handleMeeting`. Its signal goes at 20 s, so
    /// the question goes up at 30 s with its cut there, and nobody answers:
    /// the recording ends at the 70 s deadline.
    private func endUnanswered(
        _ harness: EndHarness, pausing spans: Spans, queue: PipelineQueue?, recordOnlyTo outputDir: URL? = nil,
    ) async throws {
        harness.onTick = { h, t in
            if t == 20 { h.signal.active = false }
            self.act(on: spans, h, t)
        }
        try await harness.makeLoop(queue: queue, recordOnlyTo: outputDir).handleMeeting(meeting)
        XCTAssertEqual(harness.elapsed, 70, "precondition: ended unanswered at the deadline")
    }

    /// Start a manual recording of a running app and wait until it has ended.
    private func recordManually(_ loop: WatchLoop) async throws {
        try await loop.startManualRecording(pid: 42, appName: "Zoom", title: "Weekly sync")
        await waitFor(loop.state == .idle, timeout: .seconds(10))
        XCTAssertEqual(loop.state, .idle, "precondition: the recording ended")
    }

    // MARK: - The meeting-end question's cut

    /// The cut at 30 s lands where 30 s falls on the saved tracks, which leave
    /// out the paused time, and the job keeps only the pauses that began
    /// before the cut, one spanning it ending there. Placed without the pauses
    /// the cut would keep 30 s, room audio recorded after the cut among it.
    func testTheQuestionsCutLandsOnThePauseFreeTimelineAndClipsThePauses() async throws {
        let rows: [(name: String, spans: Spans, captured: [TimeInterval], cut: (kept: TimeInterval, pauses: [RecordingPause]))] = [
            ("a pause before the cut, one after it", [(5, 15), (40, 50)], [5, 30], (20, [pause(5, 15, offset: 5)])),
            ("the cut inside a pause", [(25, 45)], [25], (25, [pause(25, 30, offset: 25)])),
        ]
        for row in rows {
            let harness = EndHarness()
            // 70 s on the clock, 20 of them paused.
            try giveTracks(to: harness, seconds: 50)
            harness.recorder.pauseOffsets = row.captured
            let queue = try makeQueue()

            try await endUnanswered(harness, pausing: row.spans, queue: queue)

            let frames = AVAudioFramePosition(row.cut.kept * 16000)
            XCTAssertEqual(try trackFrames(harness.recorder), [frames, frames, frames], row.name)
            XCTAssertEqual(
                harness.diagnostics.lines(.notice, startingWith: "recording_cut"), ["recording_cut kept_s=\(Int(row.cut.kept))"], row.name,
            )
            XCTAssertTrue(
                harness.recorder.calls.contains(.recordPendingCutResolution(keptSeconds: row.cut.kept, captureEndedAt: EndHarness.at(70))),
                "\(row.name): a recovery applies the same cut",
            )
            XCTAssertEqual(queue.jobs.count, 1, row.name)
            XCTAssertEqual(queue.jobs.first?.pauses, row.cut.pauses, row.name)
        }
    }

    /// A cut that fails processes the recording uncut, with every pause as
    /// recorded, the one after the cut time included.
    func testAFailedCutKeepsThePausesAsRecorded() async throws {
        let harness = EndHarness()
        try giveTracks(to: harness, seconds: 50)
        try Data("not audio".utf8).write(to: XCTUnwrap(harness.recorder.micPath))
        harness.recorder.pauseOffsets = [5, 30]
        let queue = try makeQueue()

        try await endUnanswered(harness, pausing: [(5, 15), (40, 50)], queue: queue)

        XCTAssertEqual(harness.diagnostics.lines(.warning, startingWith: "recording_cut_failed").count, 1, "precondition: the cut failed")
        XCTAssertEqual(queue.jobs.first?.pauses, [pause(5, 15, offset: 5), pause(40, 50, offset: 30)])
    }

    // MARK: - The long-silence question's cut

    /// Speech last heard at 5 s, so "Stop now" cuts at 15 s. Paused 8 s to
    /// 12 s and 20 s to 22 s, the question is held while paused and comes
    /// 20 s after the last resume, at 42 s; "Stop now" at 44 s. The tracks
    /// keep 11 s, the job the pause before the cut.
    func testASilenceStopOfAPausedManualRecordingCutsOnThePauseFreeTimeline() async throws {
        let harness = EndHarness()
        harness.silenceAfter = 20
        harness.lastSpeech = 5
        // 44 s on the clock, 6 of them paused.
        try giveTracks(to: harness, seconds: 38)
        harness.recorder.pauseOffsets = [8, 16]
        let queue = try makeQueue()
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            self.act(on: [(8, 12), (20, 22)], h, t)
            if t == 44, let id = h.notifier.meetingEndQuestions.last?.id {
                h.notifier.answerMeetingEndQuestion(id, with: .stopNow)
            }
        }

        try await recordManually(loop)

        XCTAssertEqual(harness.elapsed, 44, "precondition: ended at the poll after the answer")
        XCTAssertEqual(try trackFrames(harness.recorder), [176_000, 176_000, 176_000])
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "recording_cut"), ["recording_cut kept_s=11"])
        XCTAssertEqual(queue.jobs.first?.pauses, [pause(8, 12, offset: 8)])
    }

    // MARK: - Record-only

    /// A paused recording's sidecar lists each pause with its wall-clock times
    /// and position, under the version that added them; an unpaused one has
    /// no `pauses` key.
    func testARecordOnlySidecarCarriesThePausesUnderTheNewVersion() async throws {
        let rows: [(name: String, spans: Spans, pauses: [RecordingPause])] = [
            ("paused", [(10, 20)], [pause(10, 20, offset: 10)]),
            ("never paused", [], []),
        ]
        for row in rows {
            let harness = EndHarness()
            let dir = try makeTempDirectory(prefix: "pause-end-record-only")
            harness.recorder.mixPath = dir.appendingPathComponent("\(Self.basename)\(RecordingFileSuffix.mix)")
            try Data().write(to: XCTUnwrap(harness.recorder.mixPath))
            harness.recorder.pauseOffsets = row.pauses.map(\.offsetSeconds)
            let outputDir = dir.appendingPathComponent("output", isDirectory: true)
            let loop = harness.makeLoop(queue: nil, recordOnlyTo: outputDir)
            harness.onTick = { h, t in
                self.act(on: row.spans, h, t)
                if t == 30 { h.loop?.stopManualRecording() }
            }

            try await recordManually(loop)

            let url = outputDir.appendingPathComponent("\(Self.basename)\(RecordingSidecar.filenameSuffix)")
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], row.name)
            XCTAssertEqual(raw["version"] as? Int, 3, row.name)
            XCTAssertEqual(raw["pauses"] != nil, !row.pauses.isEmpty, "\(row.name): a pauses key only when paused")
            let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename), row.name)
            XCTAssertEqual(sidecar.pauses ?? [], row.pauses, row.name)
        }
    }

    /// Cut back by the meeting-end question, the sidecar stops at the cut time
    /// on the wall clock, which the pauses do not shorten, and carries the
    /// pauses clipped there.
    func testARecordOnlyCutRecordingsSidecarCarriesTheClippedPausesAndStopsAtTheCut() async throws {
        let harness = EndHarness()
        try giveTracks(to: harness, seconds: 50)
        harness.recorder.pauseOffsets = [25]
        let outputDir = try makeTempDirectory(prefix: "pause-end-output")

        try await endUnanswered(harness, pausing: [(25, 45)], queue: nil, recordOnlyTo: outputDir)

        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename))
        XCTAssertEqual(sidecar.stoppedAt, EndHarness.at(30), "the cut time, not the stop")
        XCTAssertEqual(sidecar.pauses, [pause(25, 30, offset: 25)])
        let mix = try AVAudioFile(forReading: outputDir.appendingPathComponent("\(Self.basename)\(RecordingFileSuffix.mix)"))
        XCTAssertEqual(mix.length, 400_000, "the tracks keep the audio before the pause")
    }
}

/// Everything a loop under test talks to. `onTick` runs after every virtual
/// second, before that second's poll, with the seconds since the clock
/// started; it is handed the harness rather than capturing it, so no test
/// builds a reference cycle. The recorder starts on the clock's start, so a
/// cut reports its end on the same clock.
@MainActor
private final class EndHarness {
    /// The meeting's signal, switched by the test.
    final class Signal: MeetingDetecting {
        var active = true

        func checkOnce() -> DetectedMeeting? {
            nil
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
    let recorder = MockRecorder()
    /// The long-silence question's setting, nil switched off, and when speech
    /// was last heard, in seconds from the start, nil never.
    var silenceAfter: TimeInterval?
    var lastSpeech: TimeInterval?
    var onTick: @MainActor (EndHarness, TimeInterval) -> Void = { _, _ in }
    private(set) weak var loop: WatchLoop?

    init() {
        recorder.recordingStartDate = Self.start
    }

    static func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    var elapsed: TimeInterval {
        clock.now.timeIntervalSince(Self.start)
    }

    func makeLoop(queue: PipelineQueue?, recordOnlyTo outputDir: URL? = nil) -> WatchLoop {
        let sleepProvider: (TimeInterval) async -> Void = { interval in
            await self.clock.sleep(for: interval)
            self.onTick(self, self.elapsed)
        }
        let speechActivity = {
            SpeechActivity(observedSince: Self.start, lastSpeechAt: self.lastSpeech.map { Self.at($0) })
        }
        let appAlive: (pid_t) -> Bool = { _ in true }
        let loop = WatchLoop(
            detector: signal,
            recorderFactory: { self.recorder },
            pipelineQueue: queue,
            pollInterval: 1,
            endGracePeriod: 10,
            meetingEndCountdown: 40,
            recordOnly: { outputDir != nil },
            recordOnlyDestination: { .unscoped(outputDir ?? FileManager.default.temporaryDirectory) },
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
