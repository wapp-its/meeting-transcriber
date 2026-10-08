@testable import MeetingTranscriber
import XCTest

/// The menu's "Stop Recording" at the controller: `stopRecording()` ends
/// whatever is recording, and `AppState.canStopRecording` decides whether the
/// menu offers it. The menu button itself is covered by `MenuBarViewTests`.
/// `applyRecordStopAny()` is the same stop for the automation API, which
/// answers with the outcome of it.
///
/// Every loop here is injected over a `MockRecorder`, as in
/// `WatchingControllerRecordControlTests`, so nothing touches audio hardware.
/// A detected meeting comes from `FixedMeetingDetector`, which reports its
/// meeting forever: exactly the call signal that lingers after the person
/// stopped the recording.
@MainActor
final class WatchingControllerStopRecordingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerStopRecordingTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    // MARK: - stopRecording()

    /// The point of the change: a detected meeting ends at the loop's next
    /// poll and is processed, while watching carries on, and the meeting whose
    /// signal is still there is not picked up again a poll later.
    func testStoppingADetectedMeetingEndsItsRecordingAndWatchingCarriesOn() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        let queue = PipelineQueue(logDir: tmpDir)
        let recordings = ManagedCounter()
        let (loop, recorder) = detectedMeetingRecording(on: controller, queue: queue, counting: recordings)
        await waitFor(loop.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(loop.state, .recording, "precondition: the meeting is recording")

        controller.stopRecording()
        await waitFor(loop.state != .recording, timeout: .seconds(1))

        XCTAssertNotEqual(loop.state, .recording, "the recording ends at the loop's next poll")
        XCTAssertIdentical(controller.watchLoop, loop, "the watching loop stays")
        XCTAssertTrue(controller.isWatching, "watching stays on")
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1, "processed as a meeting end is")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recordings.value, 1, "the still-signalling meeting must not be recorded again")
        XCTAssertNotEqual(loop.state, .recording)
    }

    func testStoppingAManualMicrophoneRecordingEndsItAsAManualStopDoes() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        let queue = PipelineQueue(logDir: tmpDir)
        let (loop, recorder) = makeTestWatchLoop(pipelineQueue: queue)
        controller.watchLoop = loop
        addTeardownBlock { await loop.stop() }
        try await loop.startMicrophoneRecording()

        controller.stopRecording()

        XCTAssertNil(controller.watchLoop, "a manual recording's loop goes with it")
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1, "the recording is enqueued")
    }

    /// `stopManualRecording()` drops the loop whatever it is doing, so a stop
    /// that fell through to it here would switch meeting watching off.
    func testWithTheLoopOnlyWatchingNothingChanges() {
        let controller = makeWatchingController(logDir: tmpDir)
        let (loop, recorder) = makeTestWatchLoop()
        controller.watchLoop = loop
        addTeardownBlock { await loop.stop() }
        loop.start()

        controller.stopRecording()

        XCTAssertIdentical(controller.watchLoop, loop)
        XCTAssertTrue(controller.isWatching, "watching stays on")
        XCTAssertEqual(loop.state, .watching)
        XCTAssertFalse(recorder.stopCalled)
    }

    // MARK: - AppState.canStopRecording

    func testTheMenuOffersAStopForEveryRecordingAndNotWhileOnlyWatching() async throws {
        let state = makeRPCTestState()

        let (watchingLoop, _) = makeTestWatchLoop()
        state.watching.watchLoop = watchingLoop
        addTeardownBlock { await watchingLoop.stop() }
        watchingLoop.start()
        XCTAssertFalse(state.canStopRecording, "only watching: nothing to stop")
        watchingLoop.stop()

        let (meetingLoop, _) = makeTestWatchLoop(
            detector: FixedMeetingDetector(),
            notifier: RecordingNotifier(consentAnswer: .granted),
        )
        state.watching.watchLoop = meetingLoop
        addTeardownBlock { await meetingLoop.stop() }
        meetingLoop.start()
        await waitFor(meetingLoop.state == .recording, timeout: .seconds(2))
        XCTAssertTrue(state.canStopRecording, "a detected meeting is recording")
        meetingLoop.stop()

        let (manualLoop, _) = makeTestWatchLoop()
        state.watching.watchLoop = manualLoop
        addTeardownBlock { await manualLoop.stop() }
        try await manualLoop.startMicrophoneRecording()
        XCTAssertTrue(state.canStopRecording, "a manual recording is recording")
    }

    // MARK: - The automation API keeps its meaning

    /// `/v1/record` `stop` still ends only the microphone-only recording it
    /// could have started. Asserted after several polls, because a stop that
    /// reached the meeting would take effect only at the loop's next poll.
    func testAPlainRecordStopLeavesADetectedMeetingRecording() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        let (loop, recorder) = detectedMeetingRecording(on: controller, queue: nil, counting: ManagedCounter())
        await waitFor(loop.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(loop.state, .recording, "precondition: the meeting is recording")

        let outcome = await controller.applyRecordAction(.stop)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertIdentical(controller.watchLoop, loop)
        XCTAssertEqual(loop.state, .recording, "the meeting must keep recording")
        XCTAssertFalse(recorder.stopCalled)
    }

    // MARK: - applyRecordStopAny(): a stop with scope "any"

    func testStopAnyWithNothingRecordingIsUnchanged() async {
        let controller = makeWatchingController(logDir: tmpDir)
        let (loop, recorder) = makeTestWatchLoop()
        controller.watchLoop = loop
        addTeardownBlock { await loop.stop() }
        loop.start()

        let outcome = await controller.applyRecordStopAny()

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertIdentical(controller.watchLoop, loop, "watching is not a recording this stop ends")
        XCTAssertTrue(controller.isWatching)
        XCTAssertFalse(recorder.stopCalled)
    }

    /// A manual recording ends as a plain stop of it does, the app recording
    /// included, which a plain `stop` leaves alone.
    func testStopAnyEndsAManualRecordingOfEitherKind() async throws {
        let starts: [(kind: String, start: (WatchLoop) async throws -> Void)] = [
            ("microphone only", { try await $0.startMicrophoneRecording() }),
            ("app", { try await $0.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting") }),
        ]
        for (kind, start) in starts {
            let dir = try makeTempDirectory(prefix: "WatchingControllerStopAny")
            let controller = makeWatchingController(logDir: dir)
            let queue = PipelineQueue(logDir: dir)
            let (loop, recorder) = makeTestWatchLoop(pipelineQueue: queue)
            controller.watchLoop = loop
            addTeardownBlock { await loop.stop() }
            try await start(loop)

            let outcome = await controller.applyRecordStopAny()

            XCTAssertEqual(outcome, .changed, kind)
            XCTAssertNil(controller.watchLoop, "\(kind): a manual recording's loop goes with it")
            XCTAssertTrue(recorder.stopCalled, kind)
            XCTAssertEqual(queue.jobs.count, 1, "\(kind): the recording is enqueued")
        }
    }

    /// A detected meeting ends as "Stop Recording" in the menu ends it, and the
    /// answer waits for that: the stop takes effect at the loop's next poll, so
    /// a verdict read straight after the request would still see it recording.
    func testStopAnyEndsADetectedMeetingAndAnswersOnceItHasEnded() async throws {
        let controller = makeWatchingController(logDir: tmpDir)
        let queue = PipelineQueue(logDir: tmpDir)
        let recordings = ManagedCounter()
        let (loop, recorder) = detectedMeetingRecording(on: controller, queue: queue, counting: recordings)
        await waitFor(loop.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(loop.state, .recording, "precondition: the meeting is recording")

        let outcome = await controller.applyRecordStopAny()

        XCTAssertEqual(outcome, .changed)
        XCTAssertNotEqual(loop.state, .recording, "answered only once the recording has ended")
        XCTAssertIdentical(controller.watchLoop, loop, "the watching loop stays")
        XCTAssertTrue(controller.isWatching, "watching stays on")
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1, "processed as a meeting end is")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recordings.value, 1, "the still-signalling meeting must not be recorded again")
    }

    func testStopAnyFailsWhenTheDetectedMeetingsRecorderThrowsOnStop() async {
        let controller = makeWatchingController(logDir: tmpDir)
        let queue = PipelineQueue(logDir: tmpDir)
        let (loop, recorder) = detectedMeetingRecording(on: controller, queue: queue, counting: ManagedCounter())
        recorder.mixPath = nil // its `stop()` throws: the recording is lost
        await waitFor(loop.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(loop.state, .recording, "precondition: the meeting is recording")

        let outcome = await controller.applyRecordStopAny()

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertTrue(queue.jobs.isEmpty, "nothing was handed on")
    }

    /// The loop outlives its recordings, so each failure is judged on its own
    /// recording. Both meetings here lose their record-only output with the
    /// same message, so an error left over from the first would read as "no
    /// new error" on the second and answer success for lost output.
    func testStopAnyFailsForEachDetectedMeetingWhoseRecordOnlyOutputIsLost() async {
        let controller = makeWatchingController(logDir: tmpDir)
        let recordings = ManagedCounter()
        let (loop, recorder) = detectedMeetingRecording(
            on: controller, queue: nil, counting: recordings,
            detector: TwoCallsDetector(), recordOnlyTo: tmpDir,
        )
        recorder.mixPath = tmpDir.appendingPathComponent("missing_mix.wav")

        await waitFor(recordings.value == 1 && loop.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(recordings.value, 1, "precondition: the first meeting is recording")
        let first = await controller.applyRecordStopAny()
        let firstError = loop.lastError
        await waitFor(recordings.value == 2 && loop.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(recordings.value, 2, "precondition: the second meeting is recording")
        let second = await controller.applyRecordStopAny()

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(second, .failed)
        XCTAssertNotNil(firstError)
        XCTAssertEqual(loop.lastError, firstError, "precondition: both failures read the same")
    }

    /// Bounded like every record action: a detected meeting whose stop has not
    /// taken effect in time answers `.failed` (a 503) rather than holding the
    /// request open. A poll interval far past the bound keeps the meeting-end
    /// wait asleep through it.
    func testStopAnyFailsWhenADetectedStopDoesNotTakeEffectInTime() async throws {
        let controller = makeWatchingController(logDir: tmpDir, startJoinTimeout: .milliseconds(200))
        let recorder = makeMockRecorder()
        let loop = WatchLoop(
            detector: FixedMeetingDetector(),
            recorderFactory: { recorder },
            pollInterval: 30,
            // swiftlint:disable:next trailing_closure - a bare trailing closure would hide which setting it is
            recordWithoutAskingApps: { [testMeetingApp] },
        )
        loop.permissionChecker = { .allHealthy }
        controller.watchLoop = loop
        addTeardownBlock { await loop.stop() }
        loop.start()
        await waitFor(recorder.startCalled, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(100)) // past the wait's first poll
        XCTAssertEqual(loop.state, .recording, "precondition: the meeting is recording")

        let outcome = await controller.applyRecordStopAny()

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(loop.state, .recording, "the stop has not taken effect yet")
    }

    // MARK: - Helpers

    /// A started loop that records `detector`'s meeting within a couple of polls
    /// (its consent prompt is answered Record), owned by `controller`, writing
    /// record-only output to `outputDir` when one is given. `recordings` counts
    /// every entry into `.recording`; nothing else sets `onStateChange` on an
    /// injected loop.
    private func detectedMeetingRecording(
        on controller: WatchingController,
        queue: PipelineQueue?,
        counting recordings: ManagedCounter,
        detector: any MeetingDetecting = FixedMeetingDetector(),
        recordOnlyTo outputDir: URL? = nil,
    ) -> (WatchLoop, MockRecorder) {
        let (loop, recorder) = makeTestWatchLoop(
            detector: detector,
            pipelineQueue: queue,
            recordOnly: { outputDir != nil },
            recordOnlyOutputDir: { outputDir ?? AppPaths.recordingsDir },
            notifier: RecordingNotifier(consentAnswer: .granted),
        )
        loop.onStateChange = { _, newState in
            if newState == .recording { _ = recordings.increment() }
        }
        controller.watchLoop = loop
        addTeardownBlock { await loop.stop() }
        loop.start()
        return (loop, recorder)
    }
}

/// A call in Zoom and one in Webex, both reported forever. A poll returns the
/// first one detection does not exclude, so once the first app is held after
/// its stop, the second call is the next recording on the same loop.
private final class TwoCallsDetector: MeetingDetecting {
    private let meetings = [
        makeTestMeeting(),
        DetectedMeeting(pattern: .webex, windowTitle: "Meeting: Sprint", ownerName: "TestApp", windowPID: 4243),
    ]

    func checkOnce() -> DetectedMeeting? {
        meetings.first
    }

    func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
        meetings.first { !excludedApps.contains($0.pattern.appName) }
    }

    func isMeetingActive(_: DetectedMeeting) -> Bool {
        true
    }

    func reset(appName _: String?) {}
}
