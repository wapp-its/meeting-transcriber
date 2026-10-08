@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The watchdog's clock in the tests below: it moves only when told to.
private final class StallTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Absolute times rather than increments, so a boundary is exactly the
    /// value the test names and never a sum that rounds below it.
    func set(_ time: TimeInterval) {
        lock.lock(); value = time; lock.unlock()
    }
}

/// A session that can deliver buffers on demand through the handler's real
/// tap block, wedge inside `hardwareFormat` while holding its "engine
/// mutex" (the issue #588 shape), fail, or block inside `teardown`.
private final class StallTestSession: MicEngineSessionProviding, @unchecked Sendable {
    private let engineMutex = NSLock()
    private let stateLock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedDeviceUIDs: [String?] = []
    private var installedTapBlock: AVAudioNodeTapBlock?
    private var teardownThreadsWereMain: [Bool] = []
    private let wedge = DispatchSemaphore(value: 0)
    private let teardownGate = DispatchSemaphore(value: 0)

    var shouldWedge = false
    var shouldFail = false
    /// When true, `teardown` blocks until `releaseTeardown()`, or for at
    /// most ten seconds, so a test that goes wrong fails instead of hanging.
    var blockTeardown = false
    let entered = XCTestExpectation(description: "attempt entered the wedging call")
    let teardownEntered = DispatchSemaphore(value: 0)

    let notificationObject: AnyObject = NSObject()
    // swiftlint:disable:next force_unwrapping
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    var calls: [String] {
        stateLock.withLock { recordedCalls }
    }

    var deviceUIDs: [String?] {
        stateLock.withLock { recordedDeviceUIDs }
    }

    var tapBlock: AVAudioNodeTapBlock? {
        stateLock.withLock { installedTapBlock }
    }

    /// True when `teardown` ran, and every time on the main thread.
    var teardownRanOnMainThread: Bool {
        stateLock.withLock { !teardownThreadsWereMain.isEmpty && teardownThreadsWereMain.allSatisfy(\.self) }
    }

    private func record(_ call: String) {
        stateLock.withLock { recordedCalls.append(call) }
    }

    func release() {
        wedge.signal()
    }

    func releaseTeardown() {
        teardownGate.signal()
    }

    func hardwareFormat(deviceUID: String?) throws -> AVAudioFormat {
        record("hardwareFormat")
        stateLock.withLock { recordedDeviceUIDs.append(deviceUID) }
        if shouldFail { throw MicCaptureError.noInputDevice }
        if shouldWedge {
            engineMutex.lock()
            defer { engineMutex.unlock() }
            entered.fulfill()
            wedge.wait()
        }
        return format
    }

    func installTap(format _: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        engineMutex.lock(); defer { engineMutex.unlock() }
        record("installTap")
        stateLock.withLock { installedTapBlock = block }
    }

    func start() {
        engineMutex.lock(); defer { engineMutex.unlock() }
        record("start")
    }

    func teardown() {
        engineMutex.lock(); defer { engineMutex.unlock() }
        record("teardown")
        stateLock.withLock { teardownThreadsWereMain.append(Thread.isMainThread) }
        if blockTeardown {
            teardownEntered.signal()
            _ = teardownGate.wait(timeout: .now() + 10)
        }
    }
}

/// Hands out the queued sessions in order, counting every one built. Called
/// on the main queue at init and on the restart queue for each attempt.
private final class StallTestSessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [StallTestSession]
    private var built = 0

    init(_ sessions: [StallTestSession]) {
        remaining = sessions
    }

    var count: Int {
        lock.withLock { built }
    }

    func next() -> StallTestSession {
        lock.withLock {
            built += 1
            return remaining.isEmpty ? StallTestSession() : remaining.removeFirst()
        }
    }
}

private struct StallTestFixture {
    let handler: MicCaptureHandler
    let url: URL
    let clock: StallTestClock
    let sessions: StallTestSessionQueue
}

/// The microphone stall watchdog, end to end through the handler.
///
/// A pinned USB headset delivered buffers for about ninety seconds of a call
/// and then none at all, and nothing restarted it. These drive the watchdog
/// with a manual clock and a session fake, so the ten-second trigger and the
/// fifteen-second grace cost no wall-clock time, and assert on what the
/// handler did to its sessions rather than on log lines.
///
/// The poll interval is set out of reach (`manualLimits`) so only the test's
/// own `pollStallWatchdog()` calls tick, which keeps every step deterministic.
/// One test runs the real timer on short limits to prove the wiring.
final class MicCaptureHandlerStallWatchdogTests: XCTestCase {
    /// Production limits, with a poll interval no test reaches.
    private static let manualLimits = MicStallWatchdogPolicy.Limits(
        pollIntervalSeconds: 3600,
        stallSeconds: 10,
        graceAfterAdoptionSeconds: 15,
        maxConsecutiveFruitlessRestarts: 3,
        maxRestartsPerRecording: 6,
    )

    private func makeFixture(
        _ sessions: [StallTestSession],
        limits: MicStallWatchdogPolicy.Limits = manualLimits,
        realClock: Bool = false,
        decideRetry: @escaping @Sendable (Int) -> CaptureRestartRetryAction = CaptureRestartRetryPolicy.decide,
        isDevicePresent: @escaping @Sendable (String) -> Bool = { _ in false },
    ) -> StallTestFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-\(UUID().uuidString).wav")
        let queue = StallTestSessionQueue(sessions)
        let clock = StallTestClock()
        // Typed locals, not trailing closures: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let factory: () -> any MicEngineSessionProviding = { queue.next() }
        let manualNow: @Sendable () -> TimeInterval = { clock.now }
        let handler = MicCaptureHandler(
            outputURL: url,
            sessionFactory: factory,
            decideRetry: decideRetry,
            stallWatchdogLimits: limits,
            stallClock: realClock ? MicStallWatchdogPolicy.monotonicNow : manualNow,
            isDevicePresent: isDevicePresent,
        )
        return StallTestFixture(handler: handler, url: url, clock: clock, sessions: queue)
    }

    private func deliver(to session: StallTestSession, zeros: Bool = false) throws {
        let block = try XCTUnwrap(session.tapBlock, "the session must have the handler's tap installed")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: session.format, frameCapacity: 4096))
        buffer.frameLength = 4096
        for channel in 0 ..< Int(session.format.channelCount) {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0 ..< 4096 {
                samples[frame] = zeros ? 0 : Float(sin(Double(frame) * 0.05)) * 0.5
            }
        }
        block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
    }

    /// Drain the main queue until `condition` holds. Adoption is dispatched to
    /// the main queue from the restart queue, so the observable is the
    /// handler's state after that block ran.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool,
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private func restartsLaunched(_ handler: MicCaptureHandler) -> Int {
        handler.stallWatchdog.withLock { $0.restartsLaunched }
    }

    // MARK: - Triggering

    func testAnInputThatNeverDeliversGetsAStallRestart() throws {
        let first = StallTestSession()
        let candidate = StallTestSession()
        let fixture = makeFixture([first, candidate])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        fixture.clock.set(1009.9)
        XCTAssertNil(handler.pollStallWatchdog())
        XCTAssertEqual(fixture.sessions.count, 1, "no attempt before ten seconds without a buffer")

        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        waitUntil("the stall restart became the live session") {
            (handler.session as AnyObject) === candidate
        }
        XCTAssertEqual(restartsLaunched(handler), 1)
        XCTAssertTrue(first.calls.contains("teardown"), "the stalled session must be released")
    }

    func testAnInputDeliveringZerosIsNeverRestarted() throws {
        // A headset muted in hardware, or by the call app, delivers buffers of
        // exact zeros. That is a working transport and must never be restarted.
        let first = StallTestSession()
        let fixture = makeFixture([first])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        for second in 1 ... 120 {
            fixture.clock.set(1000 + TimeInterval(second))
            try deliver(to: first, zeros: true)
            XCTAssertNil(handler.pollStallWatchdog(), "no restart at \(second) s of zeros")
        }

        XCTAssertEqual(fixture.sessions.count, 1, "no attempt was ever built")
        XCTAssertEqual(restartsLaunched(handler), 0)
        // The buffers reached the handler as zeros, so the test is about zeros
        // and not about buffers that were dropped before the level path.
        XCTAssertNotNil(handler.currentSignalAges.secondsSinceLastBuffer)
        XCTAssertNil(handler.currentSignalAges.secondsSinceLastEnergy)
    }

    func testARecoveredInputIsNotRestartedAgain() throws {
        let first = StallTestSession()
        let candidate = StallTestSession()
        let spare = StallTestSession()
        let fixture = makeFixture([first, candidate, spare])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        waitUntil("adopted") { (handler.session as AnyObject) === candidate }

        // The restarted engine delivers one second after its adoption.
        fixture.clock.set(1011)
        try deliver(to: candidate)
        XCTAssertEqual(handler.pollStallWatchdog(), .resumed(restart: 1, secondsAfterAdoption: 1))
        XCTAssertEqual(handler.stallWatchdog.withLock { $0.consecutiveFruitless }, 0)

        for second in 12 ... 90 {
            fixture.clock.set(1000 + TimeInterval(second))
            try deliver(to: candidate)
            XCTAssertNil(handler.pollStallWatchdog(), "no further restart at \(second) s")
        }
        XCTAssertEqual(restartsLaunched(handler), 1)
        XCTAssertTrue(spare.calls.isEmpty, "a recovered input must not be restarted again")
    }

    // MARK: - One attempt at a time

    func testAConfigChangeAndAStallAtTheSameMomentLaunchOneAttempt() throws {
        let first = StallTestSession()
        let candidate = StallTestSession()
        let spare = StallTestSession()
        let fixture = makeFixture([first, candidate, spare])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        fixture.clock.set(1010)
        handler.handleDeviceChange(.configurationChanged)
        XCTAssertNil(handler.pollStallWatchdog(), "the config change's attempt is in flight")
        XCTAssertEqual(restartsLaunched(handler), 0, "the watchdog's budget is not charged for it")

        waitUntil("adopted") { (handler.session as AnyObject) === candidate }
        handler.restartQueue.sync {}
        XCTAssertEqual(fixture.sessions.count, 2, "exactly one attempt was built")
        XCTAssertTrue(spare.calls.isEmpty)
    }

    func testAStallRestartOwnsTheAttemptAndAConfigChangeRightAfterIsIgnored() throws {
        let first = StallTestSession()
        let candidate = StallTestSession()
        let spare = StallTestSession()
        let fixture = makeFixture([first, candidate, spare])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        handler.handleDeviceChange(.configurationChanged)

        waitUntil("adopted") { (handler.session as AnyObject) === candidate }
        handler.restartQueue.sync {}
        XCTAssertEqual(fixture.sessions.count, 2, "exactly one attempt was built")
        XCTAssertEqual(restartsLaunched(handler), 1)
        XCTAssertTrue(spare.calls.isEmpty)
    }

    // MARK: - Stop and give-up

    func testAStopDuringAStallRestartLeavesTheWedgedEngineAlone() throws {
        let first = StallTestSession()
        let candidate = StallTestSession()
        candidate.shouldWedge = true
        let fixture = makeFixture([first, candidate])
        let handler = fixture.handler
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        wait(for: [candidate.entered], timeout: 5)

        // The .sealAndSkipEngine branch: returning at all is the assertion that
        // matters, since the candidate holds its engine mutex.
        handler.stop()
        XCTAssertNil(handler.stallTimer, "the watchdog's timer must stop with the capture")
        fixture.clock.set(2000)
        XCTAssertNil(handler.pollStallWatchdog(), "a stopped watchdog restarts nothing")

        candidate.release()
        waitUntil("the late attempt tore its own work down") { candidate.calls.contains("teardown") }
        XCTAssertNotIdentical(handler.session as AnyObject, candidate)
        XCTAssertEqual(restartsLaunched(handler), 1)
    }

    func testAWedgedStallRestartStillGivesUpWithinTheDeadline() throws {
        // The issue #588 guarantees do not depend on who launched the attempt.
        let first = StallTestSession()
        let candidate = StallTestSession()
        candidate.shouldWedge = true
        let spare = StallTestSession()
        let fixture = makeFixture([first, candidate, spare])
        let handler = fixture.handler
        defer { handler.stop(); candidate.release(); try? FileManager.default.removeItem(at: fixture.url) }

        let gaveUp = expectation(description: "give-up reported")
        handler.onGiveUp = { gaveUp.fulfill() }

        try handler.start()
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)

        XCTAssertFalse(candidate.calls.contains("teardown"), "a give-up must never touch the wedged engine")
        XCTAssertNil(handler.stallTimer, "the arbiter's give-up ends the watchdog too")
        fixture.clock.set(2000)
        XCTAssertNil(handler.pollStallWatchdog())
        XCTAssertTrue(spare.calls.isEmpty, "nothing is restarted after a give-up")
    }

    func testExhaustingTheWatchdogKeepsTheTrackAndDeviceChangesAlive() throws {
        // Three stall restarts in a row that bring nothing back: the watchdog
        // stops, but the track is not given up. A device change still restarts,
        // and a capture that comes back on its own still records.
        let first = StallTestSession()
        let stalled = (0 ..< 3).map { _ in StallTestSession() }
        let afterDeviceChange = StallTestSession()
        let fixture = makeFixture([first] + stalled + [afterDeviceChange])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        var gaveUp = false
        handler.onGiveUp = { gaveUp = true }

        try handler.start()
        var now: TimeInterval = 1010
        for (index, session) in stalled.enumerated() {
            fixture.clock.set(now)
            XCTAssertNotNil(handler.pollStallWatchdog(), "stall restart \(index + 1) is due")
            waitUntil("stall restart \(index + 1) adopted") { (handler.session as AnyObject) === session }
            now += 15
        }
        fixture.clock.set(now)
        XCTAssertEqual(handler.pollStallWatchdog(), .exhausted(.fruitlessStreak, silentSeconds: 15))
        XCTAssertEqual(restartsLaunched(handler), 3)
        XCTAssertFalse(gaveUp, "watchdog exhaustion must not end the track")
        XCTAssertTrue(handler.isRecording)

        handler.handleDeviceChange(.defaultInputChanged)
        waitUntil("a device change still restarts") { (handler.session as AnyObject) === afterDeviceChange }

        fixture.clock.set(now + 120)
        XCTAssertNil(handler.pollStallWatchdog(), "no stall restart after exhaustion")
        XCTAssertEqual(fixture.sessions.count, 5)
    }

    // MARK: - Which device

    func testAStallRestartStaysOnAPresentPinnedDeviceThroughFailures() throws {
        // Falling back to the built-in microphone would bypass a headset's
        // hardware mute. A pinned device that is still present is the target of
        // every attempt, including the retries after failed ones.
        let first = StallTestSession()
        let failing = (0 ..< 2).map { _ -> StallTestSession in
            let session = StallTestSession()
            session.shouldFail = true
            return session
        }
        let succeeding = StallTestSession()
        let fastRetry: @Sendable (Int) -> CaptureRestartRetryAction = { attemptsSoFar in
            attemptsSoFar < CaptureRestartRetryPolicy.maxAttempts ? .retry(afterSeconds: 0.02) : .giveUp
        }
        // Typed local, not a trailing closure (see `makeFixture`).
        let headsetPresent: @Sendable (String) -> Bool = { $0 == "USBHeadsetUID" }
        let fixture = makeFixture(
            [first] + failing + [succeeding],
            decideRetry: fastRetry,
            isDevicePresent: headsetPresent,
        )
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start(deviceUID: "USBHeadsetUID")
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        waitUntil("adopted after two failed attempts") { (handler.session as AnyObject) === succeeding }

        for session in failing + [succeeding] {
            XCTAssertEqual(session.deviceUIDs, ["USBHeadsetUID"])
        }
    }

    func testAStallRestartTakesTheDefaultOnlyWhenThePinnedDeviceIsGone() throws {
        let first = StallTestSession()
        let candidate = StallTestSession()
        let headsetGone: @Sendable (String) -> Bool = { _ in false }
        let fixture = makeFixture([first, candidate], isDevicePresent: headsetGone)
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start(deviceUID: "USBHeadsetUID")
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        waitUntil("adopted") { (handler.session as AnyObject) === candidate }
        XCTAssertEqual(candidate.deviceUIDs, [nil])
    }

    // MARK: - Timer wiring

    func testTheTimerDrivesTheWatchdogAndStopsWithTheCapture() throws {
        let limits = MicStallWatchdogPolicy.Limits(
            pollIntervalSeconds: 0.05,
            stallSeconds: 0.3,
            graceAfterAdoptionSeconds: 0.5,
            maxConsecutiveFruitlessRestarts: 3,
            maxRestartsPerRecording: 6,
        )
        let fixture = makeFixture([StallTestSession(), StallTestSession()], limits: limits, realClock: true)
        let handler = fixture.handler
        // Holds the restart queue until after stop(), so the stall restart the
        // timer launches is queued, not started, when stop() returns. The timer
        // cannot tick before the main run loop runs, so this is always ahead.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.restartQueue.async { gate.wait() }
        XCTAssertNotNil(handler.stallTimer, "start() must arm the watchdog")
        waitUntil("the timer launched a stall restart on its own") { restartsLaunched(handler) >= 1 }

        handler.stop()
        XCTAssertNil(handler.stallTimer)
        let built = fixture.sessions.count
        XCTAssertEqual(built, 1, "the stall restart is queued, not started, when stop() returns")
        gate.signal()
        handler.restartQueue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTExpectFailure("a restart queued before stop() still builds its session after stop() returned") {
            XCTAssertEqual(fixture.sessions.count, built, "no attempt after the stop")
        }
    }

    // MARK: - Known risk: the outgoing teardown runs on the main thread

    /// Documents current behaviour, it does not endorse it. A restart releases
    /// the outgoing session on the main queue, synchronously, before it arms
    /// the attempt's deadline or hands the attempt to the restart queue. For a
    /// stall that is the stalled engine. If its teardown blocked, the main
    /// thread would block with it, and no deadline would be there to notice:
    /// the deadline is armed after the teardown returns, and it fires on the
    /// main queue anyway.
    ///
    /// The fake's teardown blocks until released, at most ten seconds, so this
    /// fails instead of hanging if the release never comes.
    func testTheOutgoingTeardownBlocksTheMainThreadBeforeTheAttemptIsQueued() throws {
        let first = StallTestSession()
        first.blockTeardown = true
        let candidate = StallTestSession()
        let fixture = makeFixture([first, candidate])
        let handler = fixture.handler
        defer { first.releaseTeardown(); handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        final class Observations: @unchecked Sendable {
            let lock = NSLock()
            var enteredInTime = false
            var phaseWhileBlocked: RestartArbiter.Phase?
            var sessionsBuiltWhileBlocked = -1
            var mainRanWhileBlocked = false
            var mainRan = false
        }
        let seen = Observations()
        let sessions = fixture.sessions

        try handler.start()
        fixture.clock.set(1010)

        // Watches from off the main thread while the main thread is held.
        DispatchQueue.global().async {
            let entered = first.teardownEntered.wait(timeout: .now() + 5) == .success
            seen.lock.withLock { seen.enteredInTime = entered }
            guard entered else {
                first.releaseTeardown()
                return
            }
            DispatchQueue.main.async { seen.lock.withLock { seen.mainRan = true } }
            // Long enough for a queued attempt to have built its session, or a
            // main-queue block to have run, had either been possible.
            Thread.sleep(forTimeInterval: 0.3)
            let phase = handler.arbiter.withLock { $0.phase }
            seen.lock.withLock {
                seen.phaseWhileBlocked = phase
                seen.sessionsBuiltWhileBlocked = sessions.count
                seen.mainRanWhileBlocked = seen.mainRan
            }
            first.releaseTeardown()
        }

        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))

        seen.lock.withLock {
            XCTAssertTrue(seen.enteredInTime, "the stall restart tore the stalled session down")
            XCTAssertEqual(
                seen.phaseWhileBlocked, .attemptInFlight(generation: 1),
                "the arbiter already counts the attempt as in flight while the teardown blocks",
            )
            XCTAssertEqual(
                seen.sessionsBuiltWhileBlocked, 1,
                "the attempt reaches the restart queue only after the outgoing teardown returned",
            )
            XCTAssertFalse(seen.mainRanWhileBlocked, "the main queue is held for as long as the teardown blocks")
        }
        XCTAssertTrue(first.teardownRanOnMainThread)

        // Once released, the restart completes as usual.
        waitUntil("adopted after the teardown returned") { (handler.session as AnyObject) === candidate }
    }
}
