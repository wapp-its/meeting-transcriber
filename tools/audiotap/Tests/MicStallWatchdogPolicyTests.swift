@testable import AudioTapLib
import XCTest

/// The judgement behind the microphone stall watchdog, without an engine.
///
/// The incident it comes from: a pinned USB headset delivered buffers for about
/// ninety seconds of a call and then none at all, and nothing restarted the
/// capture because neither restart trigger (default input change, engine
/// configuration change) fired. These pin when a restart is due, which inputs
/// must never cause one, and where the watchdog stops.
final class MicStallWatchdogPolicyTests: XCTestCase {
    private typealias Policy = MicStallWatchdogPolicy

    /// A policy whose capture started at `start`, on the production limits.
    private func started(at start: TimeInterval = 100) -> Policy {
        var policy = Policy(limits: .production)
        policy.captureStarted(at: start)
        return policy
    }

    /// The silence a `.restart` decision reports, or nil for anything else.
    private func silence(of decision: Policy.Decision?) -> TimeInterval? {
        guard case let .restart(silentSeconds) = decision else { return nil }
        return silentSeconds
    }

    /// Launch, adopt and leave fruitless one stall restart at `now`. Returns
    /// the time of the adoption.
    @discardableResult
    private func runFruitlessStallRestart(
        _ policy: inout Policy, at now: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
    ) -> TimeInterval {
        XCTAssertNotNil(silence(of: policy.tick(now: now, capturing: true)), "a restart was due", file: file, line: line)
        let number = policy.restartLaunched(byStall: true)
        let adoptedAt = now + 0.5
        policy.restartAdopted(at: adoptedAt, stallRestart: number)
        return adoptedAt
    }

    func testTheProductionLimitsAreTheDocumentedOnes() {
        XCTAssertEqual(Policy.Limits.production, Policy.Limits(
            pollIntervalSeconds: 2,
            stallSeconds: 10,
            graceAfterAdoptionSeconds: 15,
            maxConsecutiveFruitlessRestarts: 3,
            maxRestartsPerRecording: 6,
        ))
    }

    // MARK: - When a stall is due

    func testNinePointNineSecondsWithoutABufferIsNotAStall() {
        var policy = started(at: 100)
        policy.bufferArrived(at: 100)
        XCTAssertNil(policy.tick(now: 109.9, capturing: true))
    }

    func testTenSecondsWithoutABufferIsAStall() {
        var policy = started(at: 100)
        policy.bufferArrived(at: 100)
        XCTAssertEqual(policy.tick(now: 110, capturing: true), .restart(silentSeconds: 10))
    }

    func testAnInputThatNeverDeliveredIsMeasuredFromTheCaptureStart() {
        // The capture started and not a single buffer ever came. There is no
        // last buffer to measure from, and "never" must not read as "fine".
        var policy = started(at: 100)
        XCTAssertNil(policy.tick(now: 109.9, capturing: true))
        XCTAssertEqual(policy.tick(now: 110, capturing: true), .restart(silentSeconds: 10))
    }

    func testBuffersThatKeepArrivingNeverCauseARestart() {
        // A headset muted in hardware or by the call app delivers buffers of
        // exact zeros. The policy never sees samples, so this is the contract
        // the handler relies on: every buffer counts, whatever it carries.
        // `MicCaptureHandlerStallWatchdogTests` proves zero buffers reach it.
        var policy = started(at: 100)
        var now: TimeInterval = 100
        while now < 100 + 600 {
            now += 0.1
            policy.bufferArrived(at: now)
            if Int((now * 10).rounded()).isMultiple(of: 20) {
                XCTAssertNil(policy.tick(now: now, capturing: true), "no restart at \(now)")
            }
        }
        XCTAssertEqual(policy.restartsLaunched, 0)
    }

    func testABufferBetweenTwoPollsResetsTheStallClock() {
        var policy = started(at: 100)
        XCTAssertNil(policy.tick(now: 108, capturing: true))
        policy.bufferArrived(at: 109)
        XCTAssertNil(policy.tick(now: 110, capturing: true), "a buffer one second ago is not a stall")
        XCTAssertNil(policy.tick(now: 118.9, capturing: true))
        XCTAssertEqual(policy.tick(now: 119, capturing: true), .restart(silentSeconds: 10))
    }

    func testNothingIsDueWhileTheArbiterIsNotCapturing() {
        // During an attempt, its backoff, or after a give-up the arbiter is not
        // capturing, and a second restart must not be stacked on the first.
        var policy = started(at: 100)
        XCTAssertNil(policy.tick(now: 200, capturing: false))
        XCTAssertEqual(policy.tick(now: 200, capturing: true), .restart(silentSeconds: 100))
    }

    func testNothingIsDueBeforeTheCaptureStarted() {
        var policy = Policy(limits: .production)
        XCTAssertNil(policy.tick(now: 1000, capturing: true))
    }

    // MARK: - Grace after an adoption

    func testAStallRestartAdoptionGetsFifteenSecondsOfGrace() {
        var policy = started(at: 100)
        let adoptedAt = runFruitlessStallRestart(&policy, at: 110)
        XCTAssertNil(
            policy.tick(now: adoptedAt + 10, capturing: true),
            "ten seconds after an adoption is a stall by the clock, but still inside the grace",
        )
        XCTAssertNil(policy.tick(now: adoptedAt + 14.9, capturing: true))
        XCTAssertEqual(policy.tick(now: adoptedAt + 15, capturing: true), .restart(silentSeconds: 15))
    }

    func testADeviceChangeAdoptionGetsTheSameGrace() {
        var policy = started(at: 100)
        policy.bufferArrived(at: 140)
        XCTAssertNil(policy.restartLaunched(byStall: false), "a device change has no stall restart number")
        policy.restartAdopted(at: 141, stallRestart: nil)
        XCTAssertNil(policy.tick(now: 155.9, capturing: true))
        XCTAssertEqual(policy.tick(now: 156, capturing: true), .restart(silentSeconds: 15))
        XCTAssertEqual(policy.restartsLaunched, 0, "a device-change restart is not the watchdog's budget")
    }

    // MARK: - Budgets

    func testThreeFruitlessStallRestartsInARowStopTheWatchdog() {
        var policy = started(at: 100)
        var now: TimeInterval = 110
        for expected in 1 ... 3 {
            XCTAssertNotNil(silence(of: policy.tick(now: now, capturing: true)))
            XCTAssertEqual(policy.restartLaunched(byStall: true), expected)
            policy.restartAdopted(at: now + 0.5, stallRestart: expected)
            now += 15.5
        }
        XCTAssertEqual(policy.consecutiveFruitless, 3)

        XCTAssertEqual(
            policy.tick(now: now, capturing: true), .exhausted(.fruitlessStreak, silentSeconds: 15),
            "a fourth stall after three fruitless restarts must exhaust the watchdog",
        )
        XCTAssertTrue(policy.isExhausted)
        XCTAssertNil(policy.tick(now: now + 2, capturing: true), "exhaustion is reported once")
        XCTAssertNil(policy.tick(now: now + 600, capturing: true), "and nothing is restarted after it")
        XCTAssertEqual(policy.restartsLaunched, 3)
    }

    func testOnlyABufferResetsTheFruitlessStreak() {
        var policy = started(at: 100)
        runFruitlessStallRestart(&policy, at: 110)
        runFruitlessStallRestart(&policy, at: 125.5)
        XCTAssertEqual(policy.consecutiveFruitless, 2)

        // A device change in between brings an engine up that also delivers
        // nothing. Starting is not recovering.
        policy.restartLaunched(byStall: false)
        policy.restartAdopted(at: 145, stallRestart: nil)
        XCTAssertEqual(policy.consecutiveFruitless, 2, "a successful start must not reset the streak")

        // A buffer does.
        policy.bufferArrived(at: 146)
        XCTAssertEqual(policy.consecutiveFruitless, 0)
        XCTAssertNotNil(
            silence(of: policy.tick(now: 160, capturing: true)),
            "after a buffer, a new stall gets a fresh streak",
        )
    }

    func testAtMostSixStallRestartsPerRecording() {
        // Every restart works (a buffer follows its adoption), and the device
        // stalls again each time. The streak keeps resetting; the total cap is
        // what ends it.
        var policy = started(at: 100)
        var now: TimeInterval = 110
        for expected in 1 ... 6 {
            XCTAssertNotNil(silence(of: policy.tick(now: now, capturing: true)), "restart \(expected) is due")
            XCTAssertEqual(policy.restartLaunched(byStall: true), expected)
            policy.restartAdopted(at: now + 0.5, stallRestart: expected)
            policy.bufferArrived(at: now + 1)
            XCTAssertEqual(
                policy.tick(now: now + 2, capturing: true),
                .resumed(restart: expected, secondsAfterAdoption: 0.5),
            )
            now += 20
        }
        // Last adoption at 210.5, last buffer at 211.
        XCTAssertEqual(
            policy.tick(now: now, capturing: true), .exhausted(.perRecordingCap, silentSeconds: 19),
            "a seventh stall must hit the per-recording cap",
        )
        XCTAssertEqual(policy.restartsLaunched, 6)
        XCTAssertNil(policy.tick(now: now + 60, capturing: true))
    }

    func testARestartTheArbiterDidNotLaunchIsNotCounted() {
        // The decision is only a request. A config change that got there first
        // owns the attempt, and the watchdog's budget must not be charged.
        var policy = started(at: 100)
        XCTAssertEqual(policy.tick(now: 110, capturing: true), .restart(silentSeconds: 10))
        XCTAssertEqual(policy.restartsLaunched, 0)
        XCTAssertEqual(policy.consecutiveFruitless, 0)
        XCTAssertEqual(
            policy.tick(now: 112, capturing: true), .restart(silentSeconds: 12),
            "still due, since nothing was launched for it",
        )
    }

    // MARK: - Resumption

    func testTheFirstBufferAfterAStallRestartIsReportedOnce() {
        var policy = started(at: 100)
        XCTAssertNotNil(silence(of: policy.tick(now: 110, capturing: true)))
        let number = policy.restartLaunched(byStall: true)
        XCTAssertEqual(number, 1)
        policy.restartAdopted(at: 111, stallRestart: number)
        policy.bufferArrived(at: 112.5)
        policy.bufferArrived(at: 112.6)
        XCTAssertEqual(policy.tick(now: 113, capturing: true), .resumed(restart: 1, secondsAfterAdoption: 1.5))
        XCTAssertNil(policy.tick(now: 115, capturing: true), "reported once, not per buffer")
        XCTAssertEqual(policy.consecutiveFruitless, 0)
    }

    func testABufferAfterADeviceChangeAdoptionIsNotAResume() {
        var policy = started(at: 100)
        runFruitlessStallRestart(&policy, at: 110)
        // A device change supersedes the fruitless stall restart; the buffers
        // that follow it are the device change's, not the stall restart's.
        policy.restartLaunched(byStall: false)
        policy.restartAdopted(at: 120, stallRestart: nil)
        policy.bufferArrived(at: 121)
        XCTAssertNil(policy.tick(now: 122, capturing: true))
    }

    func testABufferThatBeatsTheAdoptionCallIsCreditedToTheRestart() {
        // The arbiter starts capturing a moment before the handler tells the
        // policy about the adoption, and the render thread can deliver in that
        // moment. The time passed is taken before the arbiter flips.
        var policy = started(at: 100)
        XCTAssertNotNil(silence(of: policy.tick(now: 110, capturing: true)))
        let number = policy.restartLaunched(byStall: true)
        policy.bufferArrived(at: 111.25)
        policy.restartAdopted(at: 111, stallRestart: number)
        XCTAssertEqual(policy.tick(now: 112, capturing: true), .resumed(restart: 1, secondsAfterAdoption: 0.25))
        XCTAssertEqual(policy.consecutiveFruitless, 0)
    }

    func testARecoveryAfterExhaustionIsStillReported() {
        // Exhaustion stops restarting, not watching: a capture that comes back
        // on its own is evidence worth a line.
        var policy = started(at: 100)
        var now: TimeInterval = 110
        var lastAdoption: TimeInterval = 0
        for _ in 1 ... 3 {
            lastAdoption = runFruitlessStallRestart(&policy, at: now)
            now += 15.5
        }
        XCTAssertEqual(policy.tick(now: now, capturing: true), .exhausted(.fruitlessStreak, silentSeconds: 15))
        policy.bufferArrived(at: now + 30)
        XCTAssertEqual(
            policy.tick(now: now + 31, capturing: true),
            .resumed(restart: 3, secondsAfterAdoption: now + 30 - lastAdoption),
        )
    }

    // MARK: - Stop

    func testAStopEndsTheWatchdog() {
        var policy = started(at: 100)
        policy.stop()
        XCTAssertTrue(policy.isStopped)
        XCTAssertNil(policy.tick(now: 1000, capturing: true))
        XCTAssertNil(policy.restartLaunched(byStall: true))
        XCTAssertEqual(policy.restartsLaunched, 0)
    }

    func testAStopDropsAResumeNotYetReported() {
        var policy = started(at: 100)
        XCTAssertNotNil(silence(of: policy.tick(now: 110, capturing: true)))
        let number = policy.restartLaunched(byStall: true)
        policy.restartAdopted(at: 111, stallRestart: number)
        policy.bufferArrived(at: 112)
        policy.stop()
        XCTAssertNil(policy.tick(now: 113, capturing: true), "nothing is logged behind a stop")
    }
}
