@testable import AudioTapLib
import XCTest

/// The judgement behind configuration-change restarts, without an engine.
///
/// The incident it comes from: with a headset pinned, every engine start made
/// AVAudioEngine post a configuration change about 50 to 100 ms later, the
/// handler restarted on each one, and the next start posted the next change:
/// 233 engine starts in 35 seconds, not one buffer, and a stall watchdog that
/// never got to judge. These pin the pacing, the cap, what charges the budget
/// and how often a restart that is not launched is logged.
final class MicConfigChangePolicyTests: XCTestCase {
    private typealias Policy = MicConfigChangePolicy

    /// Ask, and launch what the policy asks for, at `now`. Fails the test when
    /// the policy declined.
    private func launch(
        _ policy: inout Policy, at now: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
    ) {
        guard case .restart = policy.decide(at: now, restartPending: false) else {
            XCTFail("a restart was expected at \(now)", file: file, line: line)
            return
        }
        policy.restartLaunched(at: now)
    }

    func testTheProductionLimitsAreTheDocumentedOnes() {
        XCTAssertEqual(
            Policy.Limits.production,
            Policy.Limits(windowSeconds: 60, maxRestartsPerWindow: 3, backoffSeconds: [0, 1, 2]),
        )
    }

    // MARK: - Pacing

    func testTheFirstChangeRestartsAtOnce() {
        var policy = Policy(limits: .production)
        XCTAssertEqual(policy.decide(at: 100, restartPending: false), .restart(afterSeconds: 0))
    }

    func testTheSecondAndThirdRestartWaitOneAndTwoSeconds() {
        var policy = Policy(limits: .production)
        launch(&policy, at: 100)
        XCTAssertEqual(policy.decide(at: 100.2, restartPending: false), .restart(afterSeconds: 1))
        policy.restartLaunched(at: 101.2)
        XCTAssertEqual(policy.decide(at: 101.4, restartPending: false), .restart(afterSeconds: 2))
    }

    func testABackoffPastTheScheduleKeepsItsLastDelay() {
        // A cap above the schedule's length repeats its last entry rather than
        // running off its end.
        var policy = Policy(limits: Policy.Limits(windowSeconds: 60, maxRestartsPerWindow: 5, backoffSeconds: [0, 1]))
        for now in [100.0, 101, 102] {
            launch(&policy, at: now)
        }
        XCTAssertEqual(policy.decide(at: 103, restartPending: false), .restart(afterSeconds: 1))
    }

    // MARK: - The cap

    func testAFourthChangeInsideTheWindowLaunchesNothingAndIsLoggedOnce() {
        var policy = Policy(limits: .production)
        for now in [100.0, 101, 103] {
            launch(&policy, at: now)
        }
        XCTAssertEqual(policy.decide(at: 103.1, restartPending: false), .ignore(.capReached, log: true))
        XCTAssertEqual(
            policy.decide(at: 103.2, restartPending: false), .ignore(.capReached, log: false),
            "the cap is said once per window, not once per notification",
        )
    }

    func testTheWindowFreesASlotExactlyWindowSecondsAfterTheFirstLaunch() {
        var policy = Policy(limits: .production)
        for now in [100.0, 101, 103] {
            launch(&policy, at: now)
        }
        XCTAssertEqual(policy.decide(at: 159.9, restartPending: false), .ignore(.capReached, log: true))
        XCTAssertEqual(
            policy.decide(at: 160, restartPending: false), .restart(afterSeconds: 2),
            "the launch at 100 dropped out; the two at 101 and 103 still count",
        )
        XCTAssertEqual(policy.launchedInWindow(at: 160), 2)
    }

    // MARK: - What charges the budget

    func testADecisionThatIsNotLaunchedChargesNothing() {
        // The arbiter may decline the attempt (another one is in flight), and
        // only the caller knows. A decision on its own must cost nothing.
        var policy = Policy(limits: .production)
        for now in [100.0, 100.1, 100.2, 100.3] {
            XCTAssertEqual(policy.decide(at: now, restartPending: false), .restart(afterSeconds: 0))
        }
        XCTAssertEqual(policy.launchedInWindow(at: 100.3), 0)
    }

    func testAChangeWhileARestartIsPendingAddsNothing() {
        var policy = Policy(limits: .production)
        launch(&policy, at: 100)
        XCTAssertEqual(policy.decide(at: 100.5, restartPending: true), .ignore(.restartPending, log: true))
        XCTAssertEqual(policy.decide(at: 100.6, restartPending: true), .ignore(.restartPending, log: false))
        XCTAssertEqual(policy.launchedInWindow(at: 100.6), 1, "coalescing must not charge the budget")
        XCTAssertEqual(
            policy.decide(at: 100.7, restartPending: false), .restart(afterSeconds: 1),
            "the pending ignores did not count as launches",
        )
    }

    func testAPendingRestartIsReportedBeforeTheCap() {
        var policy = Policy(limits: .production)
        for now in [100.0, 101, 103] {
            launch(&policy, at: now)
        }
        XCTAssertEqual(policy.decide(at: 104, restartPending: true), .ignore(.restartPending, log: true))
    }

    // MARK: - Logging of decisions that launch nothing

    func testEachIgnoreReasonIsLoggedAgainOnceAWindowPassed() {
        for (reason, pending) in [(Policy.IgnoreReason.restartPending, true), (.capReached, false)] {
            var policy = Policy(limits: .production)
            for now in [100.0, 101, 103] {
                policy.restartLaunched(at: now)
            }
            XCTAssertEqual(policy.decide(at: 104, restartPending: pending), .ignore(reason, log: true), "\(reason)")
            // The window slides on, and three new launches keep the cap in force.
            for now in [160.0, 161, 163] {
                policy.restartLaunched(at: now)
            }
            XCTAssertEqual(policy.decide(at: 163.9, restartPending: pending), .ignore(reason, log: false), "\(reason)")
            XCTAssertEqual(policy.decide(at: 164, restartPending: pending), .ignore(reason, log: true), "\(reason)")
        }
    }

    func testTheTwoIgnoreReasonsAreLoggedIndependently() {
        var policy = Policy(limits: .production)
        for now in [100.0, 101, 103] {
            launch(&policy, at: now)
        }
        XCTAssertEqual(policy.decide(at: 104, restartPending: true), .ignore(.restartPending, log: true))
        XCTAssertEqual(
            policy.decide(at: 105, restartPending: false), .ignore(.capReached, log: true),
            "a pending line said nothing about the cap",
        )
    }

    // MARK: - Engine start

    func testTheEngineStartIsUnknownUntilRecorded() {
        var policy = Policy(limits: .production)
        XCTAssertNil(policy.secondsSinceEngineStart(at: 100))
        policy.engineStarted(at: 100)
        policy.engineStarted(at: 130)
        XCTAssertEqual(policy.secondsSinceEngineStart(at: 130.25), 0.25, "measured from the latest start")
    }

    // MARK: - Log lines

    func testTheLogLinesSayWhatWasDecided() {
        let prefix = "Mic: engine configuration changed"
        let cases: [(name: String, setUp: (inout Policy) -> Void, decision: Policy.Decision, line: String?)] = [
            (
                "first restart, no start recorded",
                { _ in },
                .restart(afterSeconds: 0),
                "\(prefix) ? s after the engine started; restarting now (0 of at most 3 configuration-change restarts already launched in the last 60 s)",
            ),
            (
                "delayed restart",
                { policy in
                    policy.engineStarted(at: 199.92)
                    policy.restartLaunched(at: 150)
                },
                .restart(afterSeconds: 1),
                "\(prefix) 0.08 s after the engine started; restarting in 1 s (1 of at most 3 configuration-change restarts already launched in the last 60 s)",
            ),
            (
                "pending",
                { policy in policy.engineStarted(at: 198.5) },
                .ignore(.restartPending, log: true),
                "\(prefix) 1.50 s after the engine started; a configuration-change restart is already pending, not scheduling another",
            ),
            (
                "cap",
                { policy in
                    policy.engineStarted(at: 199.9)
                    for now in [150.0, 151, 153] {
                        policy.restartLaunched(at: now)
                    }
                },
                .ignore(.capReached, log: true),
                "\(prefix) 0.10 s after the engine started; 3 of at most 3 configuration-change restarts already launched in the last 60 s; not restarting on configuration changes until the window frees a slot, the stall watchdog stays armed",
            ),
            ("pending, not logged", { _ in }, .ignore(.restartPending, log: false), nil),
            ("cap, not logged", { _ in }, .ignore(.capReached, log: false), nil),
        ]
        for testCase in cases {
            var policy = Policy(limits: .production)
            testCase.setUp(&policy)
            XCTAssertEqual(policy.logLine(for: testCase.decision, at: 200), testCase.line, testCase.name)
        }
    }

    func testTheRestartLineCountsOnlyLaunchesInsideTheWindow() {
        var policy = Policy(limits: .production)
        policy.restartLaunched(at: 100)
        policy.restartLaunched(at: 150)
        XCTAssertEqual(
            policy.logLine(for: .restart(afterSeconds: 1), at: 160),
            "Mic: engine configuration changed ? s after the engine started; restarting in 1 s "
                + "(1 of at most 3 configuration-change restarts already launched in the last 60 s)",
            "the launch at 100 left the window at 160",
        )
    }

    /// The lines are unconditional and public, and `PersistentDiagnosticLog`
    /// writes them into the file Settings exports as redacted, so nothing in
    /// them may name or identify the device. The policy never sees one; this
    /// pins that no line grows a slot for one: a macOS audio device UID is
    /// colon-separated, and the only colon a line carries is its prefix's.
    func testNoLineCarriesDeviceIdentifyingText() {
        var policy = Policy(limits: .production)
        policy.engineStarted(at: 199)
        for now in [150.0, 151, 153] {
            policy.restartLaunched(at: now)
        }
        let decisions: [Policy.Decision] = [
            .restart(afterSeconds: 0), .restart(afterSeconds: 2),
            .ignore(.restartPending, log: true), .ignore(.capReached, log: true),
        ]
        for decision in decisions {
            let line = policy.logLine(for: decision, at: 200) ?? ""
            XCTAssertEqual(line.filter { $0 == ":" }.count, 1, line)
            XCTAssertNil(line.range(of: "uid", options: .caseInsensitive), line)
            XCTAssertNil(line.range(of: "name", options: .caseInsensitive), line)
        }
    }
}
