@testable import MeetingTranscriber
import XCTest

/// A watch loop given `holdSignallingMeetings()` before `start()`, the way
/// watching resumes after a manual recording: the calls running at that
/// moment are neither recorded nor asked about until their signal has gone
/// once, and every other call is detected as usual. Driven on `TestClock`,
/// polling once a virtual second, so no test waits in real time.
@MainActor
final class WatchLoopResumeHoldTests: XCTestCase {
    /// A call per app: a poll confirms the first call whose app is not
    /// excluded, a meeting is active while its app is in a call, and every
    /// call signals, the way the real detectors list unconfirmed calls too.
    private final class ScriptedDetector: MeetingDetecting {
        private var calls: [DetectedMeeting] = []

        func checkOnce() -> DetectedMeeting? {
            checkOnce(excluding: [])
        }

        func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
            calls.first { !excludedApps.contains($0.pattern.identityKey) }
        }

        func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
            calls.contains { $0.pattern.identityKey == meeting.pattern.identityKey }
        }

        func signallingMeetings() -> [DetectedMeeting] {
            calls
        }

        func reset(appName _: String?) {}

        func call(_ meeting: DetectedMeeting) {
            if !isMeetingActive(meeting) { calls.append(meeting) }
        }

        func hangUp(_ app: String) {
            calls.removeAll { $0.pattern.identityKey == app }
        }
    }

    /// The loop's clock, prompts, diagnostics and recorder starts.
    @MainActor
    private final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: start)
        let notifier = ConsentLoopDoubles.AnsweringNotifier(.granted)
        let diagnostics = RecordingDiagnostics()
        private(set) var recorderStarts = 0

        func makeLoop(detector: any MeetingDetecting, recordWithoutAsking: [String]) -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
            }
            let loop = WatchLoop(
                detector: detector,
                recorderFactory: {
                    self.recorderStarts += 1
                    return makeMockRecorder()
                },
                pollInterval: 1,
                endGracePeriod: 10,
                // Far beyond any test, so only what a test does ends a recording.
                maxDuration: 1_000_000,
                recordWithoutAskingApps: { recordWithoutAsking },
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
    }

    private func meeting(_ pattern: AppMeetingPattern) -> DetectedMeeting {
        DetectedMeeting(pattern: pattern, windowTitle: "Quarterly Review", ownerName: pattern.appName, windowPID: 4242)
    }

    /// Held while its signal stays; one poll without it releases the hold, and
    /// the app's next call is recorded. Once for an app that records without
    /// asking, once for one that asks first.
    func testACallSignallingAtTheResumeIsHeldUntilItsSignalHasGoneOnce() async {
        for asksFirst in [false, true] {
            let label = asksFirst ? "asks first" : "records without asking"
            let harness = Harness()
            let detector = ScriptedDetector()
            detector.call(meeting(.teams))
            let loop = harness.makeLoop(detector: detector, recordWithoutAsking: asksFirst ? [] : ["Microsoft Teams"])

            loop.holdSignallingMeetings()
            loop.start()
            await waitFor(harness.elapsed >= 6, timeout: .seconds(5))
            XCTAssertGreaterThanOrEqual(harness.elapsed, 6, "\(label): precondition: at least five polls")
            XCTAssertEqual(harness.recorderStarts, 0, "\(label): not recorded while its signal stays")
            XCTAssertTrue(harness.notifier.prompts.isEmpty, "\(label): nor asked about")

            detector.hangUp("Microsoft Teams")
            await waitFor(loop.appsHeldFromDetection.isEmpty, timeout: .seconds(5))
            XCTAssertTrue(loop.appsHeldFromDetection.isEmpty, "\(label): one poll without the signal releases it")

            detector.call(meeting(.teams))
            await waitFor(harness.recorderStarts == 1, timeout: .seconds(5))
            XCTAssertEqual(harness.recorderStarts, 1, "\(label): the next call is recorded")
            XCTAssertEqual(harness.notifier.prompts.count, asksFirst ? 1 : 0, "\(label): and asked about as usual")
            loop.stop()
        }
    }

    /// Every signalling call is held and named in its own line, one line
    /// counts them, and a call starting after the resume is asked about and
    /// recorded while the held ones still signal.
    func testEveryCallSignallingIsHeldAndACallStartingLaterIsRecorded() async {
        let harness = Harness()
        let detector = ScriptedDetector()
        detector.call(meeting(.teams))
        detector.call(meeting(.zoom))
        let loop = harness.makeLoop(detector: detector, recordWithoutAsking: [])

        loop.holdSignallingMeetings()
        XCTAssertEqual(
            Set(harness.diagnostics.lines(.notice, startingWith: "redetect_hold_set")),
            ["redetect_hold_set app=Microsoft Teams", "redetect_hold_set app=Zoom"],
        )
        XCTAssertEqual(
            harness.diagnostics.lines(.notice, startingWith: "watch_resumed_after_manual_recording"),
            ["watch_resumed_after_manual_recording held=2"],
        )

        loop.start()
        await waitFor(harness.elapsed >= 3, timeout: .seconds(5))
        // Teams and Zoom come first in the detector's order and still signal.
        detector.call(meeting(.webex))
        await waitFor(harness.recorderStarts == 1, timeout: .seconds(5))
        XCTAssertEqual(harness.recorderStarts, 1)
        XCTAssertEqual(loop.currentMeeting?.pattern.identityKey, "Webex", "the new call is recorded")
        XCTAssertEqual(harness.notifier.prompts.count, 1, "asked about as usual; the held calls are not")
        loop.stop()
    }

    /// A detector that cannot list signalling meetings holds nothing, and its
    /// call is recorded as usual.
    func testADetectorThatCannotListHoldsNothing() async {
        let harness = Harness()
        let loop = harness.makeLoop(detector: FixedMeetingDetector(), recordWithoutAsking: [testMeetingApp])

        loop.holdSignallingMeetings()
        XCTAssertTrue(loop.appsHeldFromDetection.isEmpty)
        XCTAssertTrue(harness.diagnostics.lines(.notice, startingWith: "redetect_hold_set").isEmpty)
        XCTAssertEqual(
            harness.diagnostics.lines(.notice, startingWith: "watch_resumed_after_manual_recording"),
            ["watch_resumed_after_manual_recording held=0"],
        )

        loop.start()
        await waitFor(harness.recorderStarts == 1, timeout: .seconds(5))
        XCTAssertEqual(harness.recorderStarts, 1, "recorded as usual")
        loop.stop()
    }
}
