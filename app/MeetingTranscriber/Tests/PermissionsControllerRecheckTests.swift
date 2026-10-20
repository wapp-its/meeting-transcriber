import AppKit
@testable import MeetingTranscriber
import XCTest

/// When the permission check runs again without a click: after a wake from
/// sleep and after a change of the default input device, one check at a time,
/// and never while a recording captures, since the probe opens the microphone a
/// second time. Driven with held and scripted probes on a test clock, so no
/// test here opens a device.
@MainActor
final class PermissionsControllerRecheckTests: XCTestCase {
    private let micBroken = HealthCheckResult(screenRecording: .healthy, microphone: .broken)

    // MARK: - Wake from sleep

    /// A broken verdict is replaced by the next check's result without any
    /// window coming to the front, and a second wake right after it falls
    /// inside the debounce.
    func testAWakeReplacesABrokenMicrophoneVerdict() async {
        let script = MicProbeScript([.failed(.noBufferBeforeTimeout), .failed(.noBufferBeforeTimeout), .delivered])
        let clock = ManualClock()
        let center = NotificationCenter()
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier, probe: script.check, now: clock.read)
        controller.recheckAfterWake(center: center)

        await controller.check()
        XCTAssertEqual(controller.health?.isHealthy, false, "precondition: the first check reports a broken grant")
        XCTAssertEqual(notifier.calls.map(\.title), ["Permission Problem"], "precondition")

        clock.advance(by: PermissionsController.recheckInterval)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waitUntil { controller.health?.isHealthy == true }
        XCTAssertEqual(controller.health?.isHealthy, true, "the wake did not run the check again, so the badge stays")
        XCTAssertEqual(script.attempts, 3)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        XCTAssertEqual(script.attempts, 3, "a wake inside the debounce ran the check again")
    }

    // MARK: - One check at a time

    /// A wake and two input device changes while the first check is held fold
    /// into one follow-up that starts after it. The probes are finished in the
    /// order that would let a stale result win: anything started beside the
    /// held check passes first, the held check fails last.
    func testEventsDuringARunningCheckFoldIntoOneFollowUpAndAStaleFailureCannotWin() async {
        let held = HeldChecks()
        let center = NotificationCenter()
        let controller = PermissionsController(notifier: RecordingNotifier()) { _ in await held.run() }
        controller.recheckAfterWake(center: center)

        controller.recheck()
        await waitUntil { held.started == 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        // What a change of the default input device calls, twice.
        controller.recheck()
        controller.recheck()
        await settle()

        held.finishAll(from: 1, with: .allHealthy)
        await settle()
        held.finish(0, with: micBroken)
        await waitUntil { held.started >= 2 }
        held.finishAll(from: 1, with: .allHealthy)
        await waitUntil { held.running == 0 && controller.health?.isHealthy == true }

        XCTAssertEqual(held.mostAtOnce, 1, "a second probe ran beside the held one")
        XCTAssertEqual(held.started, 2, "the events did not fold into exactly one follow-up check")
        XCTAssertEqual(controller.health?.isHealthy, true, "the held check's failure outlived a later passing check")
    }

    // MARK: - Recordings

    /// A recording that starts while a check waits for its retry: the retry
    /// does not open the microphone, the previous verdict stays and is not
    /// counted as a new check, and one check runs after the recording.
    func testARecordingThatStartsBeforeTheRetryGetsNoSecondProbeAndOneCheckAfterIt() async {
        let script = MicProbeScript([.delivered, .failed(.noBufferBeforeTimeout), .delivered])
        let clock = ManualClock()
        let notifier = RecordingNotifier()
        let controller = PermissionsController(notifier: notifier, probe: script.check, now: clock.read)
        await controller.check()
        let verdictBefore = controller.health
        let stampBefore = controller.lastCheckAt
        XCTAssertEqual(verdictBefore?.isHealthy, true, "precondition")

        clock.advance(by: PermissionsController.recheckInterval)
        script.holdNextPause()
        controller.recheck()
        await waitUntil { script.pauseIsHeld }
        controller.setRecordingActive(true)
        script.releasePause()
        await settle()

        XCTAssertEqual(script.attempts, 2, "the retry opened the microphone during the recording")
        XCTAssertEqual(controller.health, verdictBefore)
        XCTAssertEqual(controller.lastCheckAt, stampBefore, "a check that gave way counted as a completed one")

        controller.setRecordingActive(false)
        await waitUntil { script.attempts == 3 && controller.lastCheckAt != stampBefore }
        await settle()
        XCTAssertEqual(script.attempts, 3, "not exactly one check ran after the recording")
        XCTAssertNotEqual(controller.lastCheckAt, stampBefore, "no check completed after the recording")
        XCTAssertEqual(controller.health?.isHealthy, true)
        XCTAssertTrue(notifier.calls.isEmpty, "\(notifier.calls)")
    }

    /// A recording that stops and a new one that starts before the check owed
    /// to the first has run: the check waits for the second one too.
    func testANewRecordingBeforeTheDeferredCheckRunsDefersItAgain() async {
        let checks = CountingChecks()
        let controller = PermissionsController(notifier: RecordingNotifier()) { _ in checks.run() }

        controller.setRecordingActive(true)
        controller.recheck()
        controller.setRecordingActive(false)
        controller.setRecordingActive(true)
        await settle()
        XCTAssertEqual(checks.count, 0, "a check ran while a recording captured")

        controller.setRecordingActive(false)
        await waitUntil { checks.count == 1 }
        await settle()
        XCTAssertEqual(checks.count, 1, "not exactly one check ran after the recordings")
    }

    /// The recording signal is `WatchingController`'s own: Stop Watching takes
    /// the loop out of `.recording` at once while the meeting's recorder stops
    /// in a later turn, and a check asked for in between waits for that stop.
    func testACheckAskedForWhileStopWatchingFinishesTheCaptureWaitsForTheRecorder() async throws {
        let checks = CountingChecks()
        let permissions = PermissionsController(notifier: RecordingNotifier()) { _ in checks.run() }
        let recorder = StopObservingRecorder()
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "PermissionRecheck"), permissionHealth: .allHealthy,
            permissions: permissions, makeDetector: { FixedMeetingDetector() }, makeRecorder: { recorder },
        )
        controller.settings.recordWithoutAskingApps = [testMeetingApp]
        let started = await controller.startWatching()
        addTeardownBlock { _ = await controller.stopWatching() }
        XCTAssertEqual(started, .changed, "precondition")
        await waitUntil { controller.watchLoop?.state == .recording && recorder.startCalled }
        XCTAssertTrue(recorder.startCalled, "precondition: the meeting records")

        permissions.recheck()
        var checksWhenTheRecorderStopped: Int?
        recorder.duringStop = { checksWhenTheRecorderStopped = checks.count }
        controller.toggleWatching()
        XCTAssertFalse(recorder.stopCalled, "precondition: the recorder stops in a later turn")
        permissions.recheck()
        await waitUntil { recorder.stopCalled && checks.count == 1 }
        await settle()

        XCTAssertEqual(checksWhenTheRecorderStopped, 0, "a check ran while the recording captured")
        XCTAssertEqual(checks.count, 1, "not exactly one check ran once the capture had ended")
    }

    // MARK: - Helpers

    /// Polls `condition` every 10 ms until it holds or five seconds pass; the
    /// assertions after it report what did not happen.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Gives anything already started time to run, for asserting that nothing did.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// The controller's clock, moved by hand.
@MainActor
private final class ManualClock {
    private var current = Date(timeIntervalSinceReferenceDate: 0)

    func read() -> Date {
        current
    }

    func advance(by seconds: TimeInterval) {
        current += seconds
    }
}

/// Counts the checks that ran; every one passes.
@MainActor
private final class CountingChecks {
    private(set) var count = 0

    func run() -> HealthCheckResult? {
        count += 1
        return .allHealthy
    }
}

/// Checks that wait until the test finishes them, by start order, and how many
/// of them ran at once.
@MainActor
private final class HeldChecks {
    private(set) var started = 0
    private(set) var running = 0
    private(set) var mostAtOnce = 0
    private var held: [CheckedContinuation<HealthCheckResult?, Never>?] = []

    func run() async -> HealthCheckResult? {
        started += 1
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        let result = await withCheckedContinuation { held.append($0) }
        running -= 1
        return result
    }

    func finish(_ index: Int, with result: HealthCheckResult) {
        guard held.indices.contains(index) else { return }
        held[index]?.resume(returning: result)
        held[index] = nil
    }

    func finishAll(from first: Int, with result: HealthCheckResult) {
        for index in held.indices where index >= first {
            finish(index, with: result)
        }
    }
}

/// Plays microphone probe attempts from a script (the last one repeats) through
/// the real live microphone check, and can hold the next retry pause so a test
/// acts while a check waits to retry. Lock-guarded: the check runs off the main
/// actor.
private final class MicProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private let outcomes: [PermissionHealthCheck.MicProbeOutcome]
    private var count = 0
    private var holdNext = false
    private var heldPause: CheckedContinuation<Void, Never>?

    init(_ outcomes: [PermissionHealthCheck.MicProbeOutcome]) {
        self.outcomes = outcomes
    }

    var attempts: Int {
        lock.withLock { count }
    }

    var pauseIsHeld: Bool {
        lock.withLock { heldPause != nil }
    }

    func holdNextPause() {
        lock.withLock { holdNext = true }
    }

    func releasePause() {
        let pause = lock.withLock {
            defer { heldPause = nil }
            return heldPause
        }
        pause?.resume()
    }

    /// The live microphone check on this script, as a `PermissionsController.Probe`.
    func check(_ mayRetry: @escaping @Sendable () async -> Bool) async -> HealthCheckResult? {
        let microphone = await PermissionHealthCheck.checkMicrophoneLive(
            authStatus: .authorized,
            probe: { self.attempt() },
            sleep: { _ in await self.pause() },
            logFailure: { _, _ in },
            mayRetry: mayRetry,
        )
        return microphone.map { HealthCheckResult(screenRecording: .healthy, microphone: $0) }
    }

    private func attempt() -> PermissionHealthCheck.MicProbeOutcome {
        lock.withLock {
            defer { count += 1 }
            return outcomes[min(count, outcomes.count - 1)]
        }
    }

    private func pause() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let holding = lock.withLock {
                guard holdNext else { return false }
                holdNext = false
                heldPause = continuation
                return true
            }
            if !holding { continuation.resume() }
        }
    }
}

/// A recorder that completes a stop and runs `duringStop` at its start, so a
/// test can look at the permission checks at the moment the capture ends.
@MainActor
private final class StopObservingRecorder: MockRecorder {
    var duringStop: (() -> Void)?

    override init() {
        super.init()
        mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
    }

    override func stop() throws -> RecordingResult {
        duringStop?()
        return try super.stop()
    }
}
