@testable import MeetingTranscriber
import os
import XCTest

/// Unit tests for `PermissionsController` — the first concern-specific
/// controller extracted from the `AppState` god-class.
///
/// These construct a bare `PermissionsController(notifier:)` rather than a full
/// `AppState`, so they don't pay the AppState init cost (pipeline queue,
/// channel-health monitors, live-transcription prewarm, and — in non-AppStore
/// builds — the persistent-log-streamer subprocess). The injected `probe` seam
/// also lets the debounce logic be tested without the real ~500 ms `runLive()`
/// TCC probe, which was impossible while the call was hard-wired into AppState.
@MainActor
final class PermissionsControllerTests: XCTestCase {
    // MARK: - handle: notification behaviour (moved from AppStateTests)

    func testHandleBrokenSendsNotification() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(screenRecording: .broken, microphone: .healthy))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls.first?.title.contains("Permission") ?? false)
    }

    func testHandleHealthyNoNotification() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(screenRecording: .healthy, microphone: .healthy))
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testHandleStoresResult() {
        let controller = PermissionsController(notifier: RecordingNotifier())
        let result = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        controller.handle(result)
        XCTAssertEqual(controller.health, result)
    }

    func testHandleDedupsRepeatedProblem() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        let broken = HealthCheckResult(screenRecording: .healthy, microphone: .broken)
        controller.handle(broken)
        controller.handle(broken)
        controller.handle(broken)
        XCTAssertEqual(notifier.calls.count, 1, "Identical problem set should only notify once")
    }

    func testHandleReNotifiesAfterRecovery() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        let broken = HealthCheckResult(screenRecording: .healthy, microphone: .broken)
        let healthy = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        controller.handle(broken) // notify #1
        controller.handle(healthy) // clears dedup memory
        controller.handle(broken) // notify #2
        XCTAssertEqual(notifier.calls.count, 2)
    }

    func testHandleNotifiesWhenProblemChanges() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(screenRecording: .healthy, microphone: .broken))
        controller.handle(HealthCheckResult(screenRecording: .broken, microphone: .healthy))
        XCTAssertEqual(notifier.calls.count, 2, "Different problem sets should each trigger a notification")
    }

    func testHandleAccessibilityBrokenNotifies() {
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier)
        controller.handle(HealthCheckResult(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        ))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls.first?.body.contains("Accessibility") ?? false)
    }

    // MARK: - check: probe + debounce (impossible before extraction)

    func testCheckRunsProbeAndStoresHealth() async {
        let probed = HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        let controller = PermissionsController(notifier: RecordingNotifier()) { _ in probed }
        await controller.check()
        XCTAssertEqual(controller.health, probed)
        XCTAssertNotNil(controller.lastCheckAt)
    }

    func testRepeatedCheckWithinMinimumIntervalSkipsProbe() async {
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier()) { _ in counter.probe() }
        // First call: no prior timestamp → always runs.
        await controller.check(minimumInterval: 9999)
        // Second call: last check was milliseconds ago, well within 9999 s → skipped.
        await controller.check(minimumInterval: 9999)
        XCTAssertEqual(counter.count, 1, "Second check within the minimum interval should be debounced")
    }

    func testCheckWithNilIntervalAlwaysRunsProbe() async {
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier()) { _ in counter.probe() }
        await controller.check()
        await controller.check()
        XCTAssertEqual(counter.count, 2, "A nil minimum interval must never debounce")
    }

    // MARK: - check: one probe at a time (issue #778)

    /// A probe that parks on `gate` and counts on exit, so a test can hold one
    /// check open while a second one arrives.
    private func gatedProbe(_ gate: MainActorGate, _ counter: ProbeCounter) -> PermissionsController.Probe {
        { _ in await gate.wait(); return counter.probe() }
    }

    func testCheckDuringARunningCheckJoinsItInsteadOfProbingBesideIt() async {
        // The debounce only knows about checks that have finished (`lastCheckAt`
        // is written after the probe returns), so a check arriving while one is
        // out used to open a second engine on the same microphone. It joins the
        // running check instead, as the one follow-up that starts after it.
        // The second check is asked for only once the first probe is out: one
        // asked for before that probe starts is answered by it, with no
        // follow-up, so issuing both at once would leave the count to the
        // scheduler.
        let gate = MainActorGate()
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier(), probe: gatedProbe(gate, counter))

        async let first: Void = controller.check()
        await waitFor(gate.hasWaiter)
        async let second: Void = controller.check(minimumInterval: 3)
        // Both callers are inside `check()` now; only one probe may be out.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.waiterCount, 1, "the second check must join the running check, not probe beside it")

        gate.open()
        _ = await (first, second)
        XCTAssertEqual(counter.count, 2, "the joined request runs as one follow-up after the first probe")
        XCTAssertNotNil(controller.health, "the joined check reports a result")
        XCTAssertNotNil(controller.lastCheckAt)
    }

    func testCheckAfterAJoinedCheckProbesAgain() async {
        // Joining is per run, not forever: once the running check and its
        // follow-up have answered, the next undebounced check runs its own.
        let gate = MainActorGate()
        let counter = ProbeCounter()
        let controller = PermissionsController(notifier: RecordingNotifier(), probe: gatedProbe(gate, counter))
        async let first: Void = controller.check()
        await waitFor(gate.hasWaiter)
        async let second: Void = controller.check()
        try? await Task.sleep(for: .milliseconds(50))
        gate.open()
        _ = await (first, second)
        XCTAssertEqual(counter.count, 2, "precondition: the first probe and its one follow-up")
        await controller.check()
        XCTAssertEqual(counter.count, 3)
    }

    // MARK: - check: microphone probe retry

    /// The audio system can refuse the probe's engine start right after launch
    /// ("try again") while the microphone works; a refusal that clears on the
    /// retry, whichever way the first attempt failed, must post nothing.
    func testMicProbeRecoveringOnRetryIsHealthyAndPostsNothing() async {
        for failure in PermissionHealthCheck.MicProbeFailure.allCases {
            let script = ScriptedMicProbe([.failed(failure), .answered(bufferCount: 1)])
            let notifier = RecordingNotifier()
            let controller = makeMicrophoneController(script, notifier: notifier)
            await controller.check()
            XCTAssertEqual(controller.health?.microphone, .healthy, "\(failure)")
            XCTAssertTrue(notifier.calls.isEmpty, "\(failure): \(notifier.calls)")
            XCTAssertEqual(script.probeCount, 2, "\(failure)")
            XCTAssertEqual(script.pauses, [PermissionHealthCheck.micProbeRetryPause], "\(failure)")
        }
    }

    func testMicProbeFailingOnRetryTooIsBrokenAndNotifiesOnce() async {
        let script = ScriptedMicProbe([.failed(.engineStartFailed), .failed(.engineStartFailed)])
        let notifier = RecordingNotifier()
        let controller = makeMicrophoneController(script, notifier: notifier)
        await controller.check()
        XCTAssertEqual(controller.health?.microphone, .broken)
        XCTAssertEqual(script.probeCount, 2)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls.first?.title, "Permission Problem")
        XCTAssertEqual(notifier.calls.first?.body, PermissionProblem.microphoneBroken.description)
    }

    func testMicProbeDeliveringFirstTimeIsNotRetried() async {
        let script = ScriptedMicProbe([.answered(bufferCount: 1)])
        let controller = makeMicrophoneController(script, notifier: RecordingNotifier())
        await controller.check()
        XCTAssertEqual(controller.health?.microphone, .healthy)
        XCTAssertEqual(script.probeCount, 1)
        XCTAssertTrue(script.pauses.isEmpty)
    }

    /// Each failed attempt is logged with its own kind, so a refusal that cleared
    /// (one line) reads apart from one that did not (two lines).
    func testEachFailedMicProbeAttemptIsLoggedWithItsKind() async {
        let kinds = PermissionHealthCheck.MicProbeFailure.allCases
        for (index, first) in kinds.enumerated() {
            let second = kinds[(index + 1) % kinds.count]

            let transient = ScriptedMicProbe([.failed(first), .answered(bufferCount: 1)])
            await makeMicrophoneController(transient, notifier: RecordingNotifier()).check()
            XCTAssertEqual(transient.loggedFailures, [LoggedMicProbeFailure(attempt: 1, failure: first)])

            let persistent = ScriptedMicProbe([.failed(first), .failed(second)])
            await makeMicrophoneController(persistent, notifier: RecordingNotifier()).check()
            XCTAssertEqual(persistent.loggedFailures, [
                LoggedMicProbeFailure(attempt: 1, failure: first),
                LoggedMicProbeFailure(attempt: 2, failure: second),
            ])
        }
        XCTAssertEqual(Set(kinds.map(\.logToken)).count, kinds.count, "log tokens must tell the kinds apart")
    }

    // MARK: - check: a microphone that is not ready

    /// A missing input device, or one that reports no usable format yet (0 Hz or
    /// 0 channels, seen for minutes after a wake from sleep), says nothing about
    /// the grant: no broken verdict and no notification, while each attempt's
    /// reason is still logged. No buffer before the timeout on both attempts
    /// stays the signature of a broken grant, and when the two attempts fail
    /// differently the retry's failure decides.
    func testAMicrophoneThatIsNotReadyIsNotReportedAsABrokenGrant() async {
        let cases: [(failures: [PermissionHealthCheck.MicProbeFailure], verdict: PermissionStatus)] = [
            ([.invalidFormat, .invalidFormat], .healthy),
            ([.noInputDevice, .noInputDevice], .healthy),
            ([.noBufferBeforeTimeout, .invalidFormat], .healthy),
            ([.invalidFormat, .noBufferBeforeTimeout], .broken),
            ([.noBufferBeforeTimeout, .noBufferBeforeTimeout], .broken),
        ]
        for (failures, verdict) in cases {
            let script = ScriptedMicProbe(failures.map { .failed($0) })
            let notifier = RecordingNotifier()
            let controller = makeMicrophoneController(script, notifier: notifier)
            await controller.check()
            XCTAssertEqual(controller.health?.microphone, verdict, "\(failures)")
            XCTAssertEqual(notifier.calls.map(\.title), verdict == .broken ? ["Permission Problem"] : [], "\(failures)")
            XCTAssertEqual(script.loggedFailures, [
                LoggedMicProbeFailure(attempt: 1, failure: failures[0]),
                LoggedMicProbeFailure(attempt: 2, failure: failures[1]),
            ], "\(failures)")
        }
    }

    /// A controller whose check runs the real microphone check against `script`,
    /// with the other two permissions healthy.
    private func makeMicrophoneController(
        _ script: ScriptedMicProbe,
        notifier: RecordingNotifier,
    ) -> PermissionsController {
        // Its own memory of the last verdict, so no other test's check leaks in.
        let lastAnswered = OSAllocatedUnfairLock<PermissionStatus?>(initialState: nil)
        return PermissionsController(notifier: notifier) { mayRetry in
            let microphone = await PermissionHealthCheck.checkMicrophoneLive(
                authStatus: .authorized,
                probe: { script.probe() },
                sleep: { script.pause($0) },
                logFailure: { script.log(attempt: $0, failure: $1) },
                mayRetry: mayRetry,
                lastAnswered: lastAnswered,
            )
            return microphone.map { HealthCheckResult(screenRecording: .healthy, microphone: $0, accessibility: .healthy) }
        }
    }
}

private struct LoggedMicProbeFailure: Equatable {
    let attempt: Int
    let failure: PermissionHealthCheck.MicProbeFailure
}

/// Plays back scripted microphone probe outcomes (the last one repeats) and
/// records each pause and logged failure, so the retry runs on a virtual clock.
/// Lock-guarded because the live check calls it off the main actor.
private final class ScriptedMicProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let outcomes: [MicProbeOutcome]
    private var probes = 0
    private var recordedPauses: [TimeInterval] = []
    private var recordedFailures: [LoggedMicProbeFailure] = []

    init(_ outcomes: [MicProbeOutcome]) {
        self.outcomes = outcomes
    }

    var probeCount: Int {
        lock.withLock { probes }
    }

    var pauses: [TimeInterval] {
        lock.withLock { recordedPauses }
    }

    var loggedFailures: [LoggedMicProbeFailure] {
        lock.withLock { recordedFailures }
    }

    func probe() -> MicProbeOutcome {
        lock.withLock {
            defer { probes += 1 }
            return outcomes[min(probes, outcomes.count - 1)]
        }
    }

    func pause(_ duration: TimeInterval) {
        lock.withLock { recordedPauses.append(duration) }
    }

    func log(attempt: Int, failure: PermissionHealthCheck.MicProbeFailure) {
        lock.withLock { recordedFailures.append(LoggedMicProbeFailure(attempt: attempt, failure: failure)) }
    }
}

/// Counts how many times the injected probe ran. `@MainActor` to match the
/// controller's isolation; `probe` is synchronous and is called from the
/// controller's async `Probe` seam.
@MainActor
private final class ProbeCounter {
    private(set) var count = 0
    func probe() -> HealthCheckResult {
        count += 1
        return HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
    }
}
