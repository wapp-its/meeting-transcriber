@testable import MeetingTranscriber
import XCTest

/// The warning before a recording reaches its maximum length, the notice that
/// the maximum ended it, and the notice that a manual recording ended because
/// its app quit, as both poll loops post them. Driven on `TestClock`, polling
/// every 10 virtual seconds with a 2-minute maximum and a 1-minute lead, so
/// every poll lands on a whole second and the warning window opens at exactly
/// 60 s. Detected meetings are driven through `waitForMeetingEnd` directly, so
/// no recorder or cut is involved.
@MainActor
final class WatchLoopStopNoticeTests: XCTestCase {
    /// A meeting signal the test switches on and off.
    private final class SwitchableSignal: MeetingDetecting {
        var active = true

        func checkOnce() -> DetectedMeeting? {
            nil
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            active
        }

        func reset(appName _: String?) {}
    }

    /// Everything a loop under test talks to. `onTick` runs after every
    /// virtual sleep, before the next poll, with the seconds since the clock
    /// started. It is handed the harness rather than capturing it, so no test
    /// builds a reference cycle.
    @MainActor
    private final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: start)
        let signal = SwitchableSignal()
        let notifier = RecordingNotifier()
        let diagnostics = RecordingDiagnostics()
        var appAlive = true
        /// The long-silence question's period; nil keeps it switched off.
        var silenceAfter: TimeInterval?
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        private(set) weak var loop: WatchLoop?

        func makeLoop() -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
                await self.onTick(self, self.elapsed)
            }
            // Nothing heard since the start, so a switched-on silence
            // question goes up `silenceAfter` into the recording.
            let speechActivity: () -> SpeechActivity? = {
                SpeechActivity(observedSince: Self.start, lastSpeechAt: nil)
            }
            let appAlive: (pid_t) -> Bool = { _ in self.appAlive }
            let loop = WatchLoop(
                detector: signal,
                recorderFactory: { makeMockRecorder() },
                pollInterval: 10,
                endGracePeriod: 10,
                maxDuration: 120,
                capWarningLead: 60,
                meetingEndCountdown: 20,
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

        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(Self.start)
        }

        /// The cap warnings posted, in order.
        var warnings: [(title: String, body: String, urgency: NotificationUrgency)] {
            notifier.calls.filter { $0.title.hasPrefix("Recording Ends in") }
        }

        /// The "Recording Ended" notices posted, in order.
        var endedNotices: [(title: String, body: String, urgency: NotificationUrgency)] {
            notifier.calls.filter { $0.title == "Recording Ended" }
        }

        var warningLines: [String] {
            diagnostics.lines(.notice, startingWith: "recording_cap_warning")
        }

        var autoStopLines: [String] {
            diagnostics.lines(.notice, startingWith: "recording_auto_stop")
        }

        /// Answer the latest question the way a tap on its action would.
        func answerLatestQuestion(_ answer: MeetingEndAnswer) {
            if let id = notifier.meetingEndQuestions.last?.id {
                notifier.answerMeetingEndQuestion(id, with: answer)
            }
        }
    }

    private let meeting = DetectedMeeting(
        pattern: .teams,
        windowTitle: "Quarterly Review | Microsoft Teams",
        ownerName: "Microsoft Teams",
        windowPID: 4242,
    )

    // MARK: - Helpers

    /// Wait until a manual recording has ended.
    private func waitUntilIdle(_ loop: WatchLoop) async {
        await waitFor(loop.snapshot.phase == .idle, timeout: .seconds(10))
        XCTAssertEqual(loop.snapshot.phase, .idle, "precondition: the recording ended")
    }

    /// One time-sensitive warning naming `title`, then nothing but the notice
    /// that the maximum ended the recording, and one diagnostic line without
    /// the title.
    private func assertWarnedOnceThenToldTheMaximumEndedIt(
        _ harness: Harness,
        title: String,
        trigger: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(harness.warnings.count, 1, "warned exactly once", file: file, line: line)
        XCTAssertEqual(harness.warnings.first?.title, "Recording Ends in 1 Minute", file: file, line: line)
        XCTAssertEqual(
            harness.warnings.first?.body, "\"\(title)\" reaches the maximum length of 2 minutes.", file: file, line: line,
        )
        XCTAssertEqual(harness.warnings.first?.urgency, .timeSensitive, file: file, line: line)

        XCTAssertEqual(harness.endedNotices.count, 1, "one ended notice, the maximum's", file: file, line: line)
        XCTAssertEqual(
            harness.endedNotices.first?.body, "\"\(title)\" reached the maximum length of 2 minutes.", file: file, line: line,
        )
        XCTAssertEqual(harness.endedNotices.first?.urgency, .standard, file: file, line: line)
        XCTAssertEqual(
            harness.notifier.calls.map(\.title).filter { $0.hasPrefix("Recording") },
            ["Recording Ends in 1 Minute", "Recording Ended"],
            "the warning comes before the stop",
            file: file,
            line: line,
        )

        XCTAssertEqual(
            harness.warningLines, ["recording_cap_warning trigger=\(trigger) remaining_s=60"], file: file, line: line,
        )
        XCTAssertEqual(
            harness.autoStopLines,
            ["recording_auto_stop trigger=\(trigger) reason=max_duration"],
            "the stop itself is logged as before",
            file: file,
            line: line,
        )
    }

    private func assertNoCapWarningAndNoEndedNotice(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(harness.warnings.isEmpty, "no warning", file: file, line: line)
        XCTAssertTrue(harness.endedNotices.isEmpty, "no ended notice", file: file, line: line)
        XCTAssertTrue(harness.warningLines.isEmpty, "no warning line", file: file, line: line)
    }

    // MARK: - Manual recordings

    func testManualAppRecordingIsWarnedOnceAndToldWhenTheMaximumEndsIt() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()

        try await loop.startManualRecording(pid: 42, appName: "Zoom", title: "Weekly sync")
        await waitUntilIdle(loop)

        XCTAssertEqual(harness.elapsed, 130, "stopped at the first poll past the maximum, as before")
        assertWarnedOnceThenToldTheMaximumEndedIt(harness, title: "Weekly sync", trigger: "manual")
    }

    func testMicrophoneOnlyRecordingIsWarnedOnceAndToldWhenTheMaximumEndsIt() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()

        try await loop.startMicrophoneRecording()
        await waitUntilIdle(loop)

        XCTAssertEqual(harness.elapsed, 130)
        assertWarnedOnceThenToldTheMaximumEndedIt(harness, title: ManualRecordingInfo.microphoneTitle, trigger: "manual")
    }

    /// The app quits at 30 s, before the window: the recording ends at that
    /// poll and the only notice names the app.
    func testManualRecordingWhoseAppQuitsBeforeTheWindowGetsOnlyTheAppQuitNotice() async throws {
        let harness = Harness()
        harness.onTick = { h, t in
            if t == 30 { h.appAlive = false }
        }
        let loop = harness.makeLoop()

        try await loop.startManualRecording(pid: 42, appName: "Zoom", title: "Weekly sync")
        await waitUntilIdle(loop)

        XCTAssertEqual(harness.elapsed, 30)
        XCTAssertTrue(harness.warnings.isEmpty, "not warned")
        XCTAssertTrue(harness.warningLines.isEmpty)
        XCTAssertEqual(harness.endedNotices.count, 1)
        XCTAssertEqual(harness.endedNotices.first?.body, "Zoom quit, so the recording \"Weekly sync\" ended.")
        XCTAssertEqual(harness.endedNotices.first?.urgency, .standard)
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=manual reason=app_exited pid=42"])
    }

    func testManualRecordingStoppedByHandBeforeTheWindowGetsNoNotice() async throws {
        let harness = Harness()
        harness.onTick = { h, t in
            if t == 30 { h.loop?.stopManualRecording() }
        }
        let loop = harness.makeLoop()

        try await loop.startManualRecording(pid: 42, appName: "Zoom", title: "Weekly sync")
        await waitUntilIdle(loop)

        XCTAssertEqual(harness.elapsed, 30)
        assertNoCapWarningAndNoEndedNotice(harness)
        XCTAssertTrue(harness.autoStopLines.isEmpty)
    }

    /// "Stop now" to the long-silence question, acted on at 60 s, the poll
    /// the window opens on: the recording ends there without being warned
    /// seconds before, and the silence stop gets no notice.
    func testASilenceStopOnThePollTheWindowOpensGetsNoNotice() async throws {
        let harness = Harness()
        harness.silenceAfter = 30
        harness.onTick = { h, t in
            if t == 60 { h.answerLatestQuestion(.stopNow) }
        }
        let loop = harness.makeLoop()

        try await loop.startManualRecording(pid: 42, appName: "Zoom", title: "Weekly sync")
        await waitUntilIdle(loop)

        XCTAssertEqual(harness.elapsed, 60)
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=manual reason=silence_stop silent_s=60"])
        assertNoCapWarningAndNoEndedNotice(harness)
    }

    // MARK: - Detected meetings

    func testDetectedMeetingHeldPastTheMaximumIsWarnedOnceAndToldWhenTheMaximumEndsIt() async throws {
        let harness = Harness()
        let loop = harness.makeLoop()

        let cutAt = try await loop.waitForMeetingEnd(meeting)

        XCTAssertNil(cutAt)
        XCTAssertEqual(harness.elapsed, 130)
        assertWarnedOnceThenToldTheMaximumEndedIt(harness, title: "Quarterly Review", trigger: "auto")
    }

    /// The signal is gone from the start: asked at 10 s, the countdown runs
    /// out at 30 s, before the window.
    func testDetectedMeetingEndedByTheCountdownBeforeTheWindowGetsNoNotice() async throws {
        let harness = Harness()
        harness.signal.active = false
        let loop = harness.makeLoop()

        try await loop.waitForMeetingEnd(meeting)

        XCTAssertEqual(harness.elapsed, 30)
        XCTAssertEqual(harness.autoStopLines, ["recording_auto_stop trigger=auto reason=countdown_expired signal_absent_s=30"])
        assertNoCapWarningAndNoEndedNotice(harness)
    }
}
