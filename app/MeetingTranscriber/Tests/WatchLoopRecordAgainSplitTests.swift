@testable import MeetingTranscriber
import XCTest

/// Teams' new-call split during a "Record Again" recording, with the real
/// `PowerAssertionDetector` on injected assertions, as `WatchLoopTimingTests`
/// drives it. The stop before the click reset the detector, which starts a
/// wall-clock cooldown that lasts the whole virtual timeline, so the split
/// finds the next call only if the click marked the app confirmed.
@MainActor
final class WatchLoopRecordAgainSplitTests: XCTestCase {
    func testASplitStartsTheNextCallsRecordingAtOnceAlsoRightAfterTheStop() async {
        let clock = TestClock()
        let virtualStart = clock.now
        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(virtualStart)
        }
        let detector = PowerAssertionDetector()
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            switch elapsed {
            case ..<2: PowerAssertionFixture.teamsCall(1, 2, pid: 1234)
            case ..<3: PowerAssertionFixture.teamsCall(3, 4, pid: 1234)
            default: [:]
            }
        }
        weak var weakLoop: WatchLoop?
        var stopped = false
        var clicked = false
        let loop = WatchLoop(
            detector: detector, recorderFactory: { makeMockRecorder() },
            pollInterval: 0.05, endGracePeriod: 0.5, maxDuration: 30, meetingEndCountdown: 0.3,
            recordWithoutAskingApps: { ["Microsoft Teams"] },
            nowProvider: { clock.now },
            sleepProvider: { interval in
                await clock.sleep(for: interval)
                guard let loop = weakLoop else { return }
                // Stop by hand half a second in, and click as soon as the
                // loop watches again: well inside the detector's cooldown.
                if !stopped, elapsed >= 0.5, loop.state == .recording { stopped = loop.stopDetectedRecording() }
                if stopped, !clicked, loop.state == .watching { clicked = loop.recordAgain(identityKey: "Microsoft Teams") }
            },
        )
        weakLoop = loop
        loop.permissionChecker = { .allHealthy }
        var starts: [TimeInterval] = []
        var causes: [PhaseChangeCause] = []
        loop.onStateChange = { _, next, cause in
            guard next == .recording else { return }
            starts.append(elapsed)
            causes.append(cause)
        }

        loop.start()
        // Wall-clock bail-out, as in `WatchLoopTimingTests`.
        let deadline = Date().addingTimeInterval(10)
        while elapsed < 5, Date() < deadline {
            await Task.yield()
        }
        loop.stop()

        XCTAssertTrue(clicked, "precondition: Record Again was clicked")
        XCTAssertEqual(causes, [.regular, .recordAgain, .regular], "the split's recording is a detected one")
        XCTAssertEqual(starts.count, 3, "got \(starts)")
        if starts.count == 3 {
            XCTAssertLessThan(starts[1], 1, "precondition: clicked right after the stop")
            XCTAssertGreaterThanOrEqual(starts[2], 2)
            XCTAssertLessThan(starts[2], 2.1, "the next call's recording starts at the split poll")
        }
    }
}
