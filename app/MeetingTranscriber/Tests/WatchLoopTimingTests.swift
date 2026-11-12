@testable import MeetingTranscriber
import XCTest

/// Tests for `WatchLoop.waitForMeetingEnd`'s async timing paths. Driven
/// by `TestClock` (in `TestHelpers.swift`) so each `sleep` resolves
/// instantly while advancing the virtual clock — no wall-clock waits,
/// no `Task.sleep`-jitter sensitivity on loaded CI runners.
@MainActor
final class WatchLoopTimingTests: XCTestCase {
    private func makeMeeting() -> DetectedMeeting {
        DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 1234,
        )
    }

    // MARK: - Grace period and question countdown

    /// A lost signal waits out the grace period and then the unanswered
    /// question's countdown, and the end it returns is cut back to the loss
    /// plus the grace period.
    func testWaitForMeetingEndWaitsGraceAndCountdownAndCutsBackToGrace() async throws {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = { [:] }

        let clock = TestClock()
        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
            meetingEndCountdown: 0.3,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        let virtualStart = clock.now
        let cutAt = try await loop.waitForMeetingEnd(makeMeeting()).cutAt
        let elapsed = clock.now.timeIntervalSince(virtualStart)

        XCTAssertGreaterThanOrEqual(
            elapsed, 0.4, "Should wait the grace period and then the countdown (virtual time)",
        )
        let cut = try XCTUnwrap(cutAt, "an unanswered question ends the recording cut back")
        XCTAssertEqual(cut.timeIntervalSince(virtualStart), 0.1, accuracy: 1e-6, "signal lost at the first poll, plus grace")
    }

    // MARK: - Max duration

    func testWaitForMeetingEndMaxDuration() async throws {
        let detector = PowerAssertionDetector()
        detector.assertionProvider = {
            [1234: [["Process Name": "MSTeams", "AssertName": "Microsoft Teams Call in progress"]]]
        }

        let clock = TestClock()
        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            maxDuration: 0.15,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        let virtualStart = clock.now
        try await loop.waitForMeetingEnd(makeMeeting())
        let elapsed = clock.now.timeIntervalSince(virtualStart)

        XCTAssertGreaterThan(
            elapsed, 0.15, "Should wait at least maxDuration (virtual time)",
        )
    }

    // MARK: - Grace reset on meeting resume

    /// Characterization test pinning the grace-reset behaviour: when the
    /// meeting becomes inactive, then resumes, then ends again, the
    /// grace-period timer must restart from scratch — i.e. the second
    /// grace window has to run its full duration independent of the
    /// first, partially elapsed one.
    ///
    /// Driven by `TestClock` so the assertion is deterministic — wall-clock
    /// `Task.sleep` jitter cannot expire the grace window prematurely.
    func testWaitForMeetingEndResetsGraceWhenMeetingResumes() async throws {
        let detector = PowerAssertionDetector()
        let activeAssertions: [Int32: [[String: Any]]] = [
            1234: [["Process Name": "MSTeams", "AssertName": "Microsoft Teams Call in progress"]],
        ]
        // Sequence: inactive, ACTIVE, inactive, inactive, …
        // Without grace-reset the loop asks at poll 3 (graceStart from poll 1
        // would have ≥ grace elapsed by virtual t=0.10) and returns at poll 4.
        // With reset it asks no earlier than poll 5 because poll 2 clears
        // graceStart and the fresh grace started at poll 3 only expires once
        // virtual time advances by another full grace window.
        let callCount = ManagedCounter()
        detector.assertionProvider = {
            let n = callCount.increment()
            return n == 2 ? activeAssertions : [:]
        }

        // No countdown, so the loop returns one poll after the grace expires
        // and the poll count still tells the two behaviours apart.
        let clock = TestClock()
        let loop = WatchLoop(
            detector: detector,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 30,
            meetingEndCountdown: 0,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        try await loop.waitForMeetingEnd(makeMeeting())

        XCTAssertGreaterThanOrEqual(
            callCount.value, 5,
            "Grace must reset on resume; observed only \(callCount.value) polls — "
                + "without reset the loop would ask at poll 3 once the original "
                + "grace window had elapsed, and return at poll 4.",
        )
    }

    // MARK: - Back-to-back calls (issue #765)

    private static let teamsCall = PowerAssertionFixture.teamsCall

    /// A detector whose assertions follow `timeline` on the virtual clock:
    /// each entry holds from its offset until the next entry's.
    private func timelineDetector(
        _ clock: TestClock,
        _ timeline: [(from: TimeInterval, assertions: [Int32: [[String: Any]]])],
    ) -> PowerAssertionDetector {
        let start = clock.now
        let detector = PowerAssertionDetector()
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            let elapsed = clock.now.timeIntervalSince(start)
            return timeline.last { $0.from <= elapsed }?.assertions ?? [:]
        }
        return detector
    }

    /// Teams records without asking here, as the back-to-back test needs both
    /// recordings to start on their own, and the end question's countdown is
    /// short so an end that comes out of it does not run two virtual minutes.
    private func timedLoop(
        _ detector: PowerAssertionDetector,
        _ clock: TestClock,
        notifier: any AppNotifying = SilentNotifier(),
        recorderFactory: @escaping @MainActor () async -> any RecordingProvider = { makeMockRecorder() },
    ) -> WatchLoop {
        WatchLoop(
            detector: detector, recorderFactory: recorderFactory,
            pollInterval: 0.05, endGracePeriod: 0.5, maxDuration: 30,
            meetingEndCountdown: 0.3,
            recordWithoutAskingApps: { ["Microsoft Teams"] },
            notifier: notifier,
            nowProvider: { clock.now }, sleepProvider: { await clock.sleep(for: $0) },
        )
    }

    func testWaitForMeetingEndStopsWhenTheAppMovesToANewCallWithinGrace() async throws {
        let clock = TestClock()
        let loop = timedLoop(timelineDetector(clock, [
            (0, Self.teamsCall(1, 2, 1234)),
            (1.0, [:]), // gap shorter than the grace
            (1.2, Self.teamsCall(3, 4, 1234)),
        ]), clock)
        let virtualStart = clock.now

        let reason = try await loop.waitForMeetingEnd(makeMeeting()).reason

        XCTAssertEqual(reason, .replacedByNewCall)
        XCTAssertLessThan(clock.now.timeIntervalSince(virtualStart), 1.5, "must stop when the new call appears")
    }

    func testWaitForMeetingEndKeepsRecordingWhenTheSameCallComesBack() async throws {
        let clock = TestClock()
        let loop = timedLoop(timelineDetector(clock, [
            (0, Self.teamsCall(1, 2, 1234)),
            (1.0, [:]),
            (1.2, Self.teamsCall(1, 2, 1234)),
            (2.0, [:]),
        ]), clock)
        let virtualStart = clock.now

        let reason = try await loop.waitForMeetingEnd(makeMeeting()).reason

        XCTAssertEqual(reason, .ended)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(virtualStart), 2.5)
    }

    /// A new call while "the meeting seems to have ended" is open ends the
    /// recording at once instead of waiting for the countdown, takes the
    /// question back, and cuts the audio back to where the question's own end
    /// would have, so the room between the calls is not kept.
    func testANewCallWhileTheEndQuestionIsOpenEndsTheRecordingAtOnce() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let loop = timedLoop(timelineDetector(clock, [
            (0, Self.teamsCall(1, 2, 1234)),
            (1.0, [:]), // grace 0.5: the question goes up at about 1.5, its countdown runs to 1.8
            (1.6, Self.teamsCall(3, 4, 1234)),
        ]), clock, notifier: notifier)
        let virtualStart = clock.now

        let end = try await loop.waitForMeetingEnd(makeMeeting())

        XCTAssertEqual(end.reason, .replacedByNewCall)
        XCTAssertLessThan(clock.now.timeIntervalSince(virtualStart), 1.75, "must not wait for the countdown")
        let cut = try XCTUnwrap(end.cutAt, "an end out of the open question is cut back")
        XCTAssertEqual(cut.timeIntervalSince(virtualStart), 1.5, accuracy: 0.06, "signal loss plus grace")
        let question = try XCTUnwrap(notifier.meetingEndQuestions.first)
        XCTAssertEqual(notifier.meetingEndQuestions.count, 1)
        XCTAssertEqual(notifier.withdrawnMeetingEndQuestions, [question.id], "the open question is taken back")
    }

    /// The whole loop: two back-to-back calls become two recordings, and the
    /// second starts while its call is still running. The detector's cooldown
    /// runs on wall-clock time, so if it were applied after the split the
    /// virtual timeline would race past the second call before detection
    /// resumed, and only one recording would start.
    func testBackToBackCallsBecomeTwoRecordings() async {
        let clock = TestClock()
        let virtualStart = clock.now
        var recorders: [MockRecorder] = []
        var recordingStarts: [TimeInterval] = []
        let loop = timedLoop(timelineDetector(clock, [
            (0, Self.teamsCall(1, 2, 1234)),
            (1.0, [:]),
            (1.2, Self.teamsCall(3, 4, 1234)),
            (3.0, [:]),
        ]), clock) {
            recordingStarts.append(clock.now.timeIntervalSince(virtualStart))
            let recorder = makeMockRecorder()
            recorders.append(recorder)
            return recorder
        }
        loop.permissionChecker = { .allHealthy }
        var transitions: [WatchLoop.State] = []
        var splitTransitions: [WatchLoop.State] = []
        loop.onStateChange = { _, new, cause in
            transitions.append(new)
            if cause == .callSplit { splitTransitions.append(new) }
        }

        loop.start()
        // Wall-clock bail-out: a watch task that exits or parks outside
        // clock.sleep would otherwise leave this loop spinning forever.
        let deadline = Date().addingTimeInterval(10)
        while clock.now.timeIntervalSince(virtualStart) < 5, Date() < deadline {
            await Task.yield()
        }
        loop.stop()

        XCTAssertEqual(recorders.count, 2, "each call must get its own recording")
        XCTAssertTrue(recorders.allSatisfy(\.stopCalled))
        // Channel health, the live-caption flush and the "Meeting Detected"
        // notification all hang on entering `.recording`, so the second call
        // must enter it too rather than inherit the first call's phase.
        XCTAssertEqual(
            transitions.count { $0 == .recording }, 2,
            "each recording must be entered by its own transition, got \(transitions)",
        )
        // Only the step out of the first call is the split; the final stop is not.
        XCTAssertEqual(splitTransitions, [.watching], "got \(transitions)")
        if recordingStarts.count == 2 {
            XCTAssertGreaterThan(recordingStarts[1], 1.2)
            // The end poll sees the switch within one poll; re-confirming the
            // call from scratch would add two more.
            XCTAssertLessThan(recordingStarts[1], 1.3, "the second recording must start right after the switch")
        }
    }
}
