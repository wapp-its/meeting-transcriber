@testable import MeetingTranscriber
import XCTest

/// The menu's "Stop Recording" at the controller: `stopRecording()` ends
/// whatever is recording, and `AppState.canStopRecording` decides whether the
/// menu offers it. The menu button itself is covered by `MenuBarViewTests`.
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

    // MARK: - Helpers

    /// A started loop that records `FixedMeetingDetector`'s meeting within a
    /// couple of polls (its consent prompt is answered Record), owned by
    /// `controller`. `recordings` counts every entry into `.recording`; nothing
    /// else sets `onStateChange` on an injected loop.
    private func detectedMeetingRecording(
        on controller: WatchingController,
        queue: PipelineQueue?,
        counting recordings: ManagedCounter,
    ) -> (WatchLoop, MockRecorder) {
        let (loop, recorder) = makeTestWatchLoop(
            detector: FixedMeetingDetector(),
            pipelineQueue: queue,
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
