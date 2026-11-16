@testable import MeetingTranscriber
import XCTest

/// Teams' new-call split during a "Record (<App>)" recording, with the real
/// `PowerAssertionDetector` on injected assertions, as
/// `WatchLoopRecordAgainSplitTests` drives it. The Ignore before the click
/// reset the detector, which starts a wall-clock cooldown that lasts the whole
/// virtual timeline, so the split finds the next call only if the click marked
/// the app confirmed; and the decline started the app's quiet time, so the next
/// call is asked about only if the click ended it.
@MainActor
final class WatchLoopRecordIgnoredSplitTests: XCTestCase {
    private struct Run {
        var clickedAt: TimeInterval?
        var starts: [TimeInterval] = []
        var causes: [PhaseChangeCause] = []
        /// When the loop went back to watching with a question about Teams open.
        var askedAt: [TimeInterval] = []
        var prompts = 0
    }

    /// Ignore the first question, click "Record (Microsoft Teams)" as soon as
    /// it shows, and switch Teams' call IDs at 2 s. `switchToRecordWithoutAsking`
    /// puts Teams on Record Without Asking together with the click.
    private func run(switchToRecordWithoutAsking: Bool) async -> Run {
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
        let notifier = ConsentLoopDoubles.ParkingNotifier()
        var recordWithoutAsking: [String] = []
        var result = Run()
        weak var weakLoop: WatchLoop?
        let loop = WatchLoop(
            detector: detector, recorderFactory: { makeMockRecorder() },
            pollInterval: 0.05, endGracePeriod: 0.5, maxDuration: 30, meetingEndCountdown: 0.3,
            recordWithoutAskingApps: { recordWithoutAsking },
            notifier: notifier,
            nowProvider: { clock.now },
            sleepProvider: { interval in
                await clock.sleep(for: interval)
                guard let loop = weakLoop else { return }
                // Ignore the first question; any later one stays open.
                if notifier.isParked, notifier.prompts.count == 1 { notifier.answer(.declined) }
                if result.clickedAt == nil, loop.recordAgain(identityKey: "Microsoft Teams") {
                    result.clickedAt = elapsed
                    if switchToRecordWithoutAsking { recordWithoutAsking = ["Microsoft Teams"] }
                }
            },
        )
        weakLoop = loop
        loop.permissionChecker = { .allHealthy }
        loop.onStateChange = { _, next, cause in
            if next == .recording {
                result.starts.append(elapsed)
                result.causes.append(cause)
            }
            if next == .watching, weakLoop?.pendingConsentQuestion?.identityKey == "Microsoft Teams", !result.starts.isEmpty {
                result.askedAt.append(elapsed)
            }
        }

        loop.start()
        // Wall-clock bail-out, as in `WatchLoopTimingTests`.
        let deadline = Date().addingTimeInterval(10)
        while elapsed < 5, Date() < deadline {
            await Task.yield()
        }
        result.prompts = notifier.prompts.count
        loop.stop()
        return result
    }

    /// Teams asks before recording: the split poll asks about the next call,
    /// since the click ended the quiet time, and nothing records until it is
    /// answered.
    func testASplitAsksAboutTheNextCallAtTheSplitPollAlsoRightAfterTheIgnore() async {
        let result = await run(switchToRecordWithoutAsking: false)

        XCTAssertLessThan(result.clickedAt ?? .infinity, 1, "precondition: clicked right after the Ignore")
        XCTAssertEqual(result.causes, [.recordAgain], "no second recording")
        XCTAssertEqual(result.prompts, 2, "the next call is asked about")
        XCTAssertEqual(result.askedAt.count, 1, "got \(result.askedAt)")
        if let askedAt = result.askedAt.first {
            XCTAssertGreaterThanOrEqual(askedAt, 2)
            XCTAssertLessThan(askedAt, 2.1, "the question opens at the split poll")
        }
    }

    /// Teams switched to Record Without Asking after the Ignore: the next
    /// call's recording starts at the split poll.
    func testASplitRecordsTheNextCallAtOnceForAnAppSwitchedToRecordWithoutAsking() async {
        let result = await run(switchToRecordWithoutAsking: true)

        XCTAssertLessThan(result.clickedAt ?? .infinity, 1, "precondition: clicked right after the Ignore")
        XCTAssertEqual(result.causes, [.recordAgain, .regular], "the split's recording is a detected one")
        XCTAssertEqual(result.prompts, 1, "not asked")
        XCTAssertEqual(result.starts.count, 2, "got \(result.starts)")
        if result.starts.count == 2 {
            XCTAssertGreaterThanOrEqual(result.starts[1], 2)
            XCTAssertLessThan(result.starts[1], 2.1, "the next call's recording starts at the split poll")
        }
    }
}
