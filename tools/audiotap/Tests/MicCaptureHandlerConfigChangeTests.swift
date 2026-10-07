@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The handler's clock in the tests below: it moves only when told to.
private final class ConfigChangeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000

    var now: TimeInterval {
        lock.withLock { value }
    }

    /// Absolute times rather than increments, so a boundary is exactly the
    /// value the test names.
    func set(_ time: TimeInterval) {
        lock.withLock { value = time }
    }
}

/// A session that never touches audio hardware. It records the device every
/// bring-up was asked for, keeps the handler's tap block as an engine would,
/// can fail its bring-up, and can hold one inside `hardwareFormat` until
/// released, which keeps a restart attempt in flight.
private final class ConfigChangeTestSession: MicEngineSessionProviding, @unchecked Sendable {
    private let stateLock = NSLock()
    private var recordedDeviceUIDs: [String?] = []
    private var installedTapBlock: AVAudioNodeTapBlock?
    private let gate = DispatchSemaphore(value: 0)

    var shouldFail = false
    var holdInHardwareFormat = false
    let entered = XCTestExpectation(description: "the attempt entered hardwareFormat")

    let notificationObject: AnyObject = NSObject()
    // swiftlint:disable:next force_unwrapping
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    var deviceUIDs: [String?] {
        stateLock.withLock { recordedDeviceUIDs }
    }

    func release() {
        gate.signal()
    }

    func hardwareFormat(deviceUID: String?) throws -> AVAudioFormat {
        stateLock.withLock { recordedDeviceUIDs.append(deviceUID) }
        if shouldFail { throw MicCaptureError.noInputDevice }
        if holdInHardwareFormat {
            entered.fulfill()
            // Bounded, so a test that goes wrong fails instead of hanging.
            _ = gate.wait(timeout: .now() + 10)
        }
        return format
    }

    func installTap(format _: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        stateLock.withLock { installedTapBlock = block }
    }

    func start() {}

    func teardown() {}
}

/// Hands out the queued sessions in order, counting every one built. Called
/// on the main queue at init and on the restart queue for each attempt.
private final class ConfigChangeTestSessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ConfigChangeTestSession]
    private var built = 0

    init(_ sessions: [ConfigChangeTestSession]) {
        remaining = sessions
    }

    var count: Int {
        lock.withLock { built }
    }

    func next() -> ConfigChangeTestSession {
        lock.withLock {
            built += 1
            return remaining.isEmpty ? ConfigChangeTestSession() : remaining.removeFirst()
        }
    }
}

private struct ConfigChangeTestFixture {
    let handler: MicCaptureHandler
    let url: URL
    let clock: ConfigChangeTestClock
    let sessions: ConfigChangeTestSessionQueue
}

/// Configuration-change restarts, end to end through the handler.
///
/// A pinned headset made AVAudioEngine post a configuration change after every
/// engine start, and every change restarted the capture: 233 engine starts in
/// 35 seconds, not one buffer, and a stall watchdog that never got to judge.
/// These drive `handleEngineConfigChange()` directly after each adoption,
/// rather than through a fake that posts on a timer, and assert on the
/// sessions the handler built.
final class MicCaptureHandlerConfigChangeTests: XCTestCase {
    /// The production window and cap, with real-time backoffs short enough to
    /// wait out.
    private static let shortLimits = MicConfigChangePolicy.Limits(
        windowSeconds: 60, maxRestartsPerWindow: 3, backoffSeconds: [0, 0.05, 0.1],
    )

    /// A second restart that waits longer than any test runs, so it is still
    /// pending whenever the test looks.
    private static let longBackoffLimits = MicConfigChangePolicy.Limits(
        windowSeconds: 60, maxRestartsPerWindow: 3, backoffSeconds: [0, 30],
    )

    /// The stall watchdog's production limits with a poll interval no test
    /// reaches, so only explicit `pollStallWatchdog()` calls tick.
    private static let manualStallLimits = MicStallWatchdogPolicy.Limits(
        pollIntervalSeconds: 3600,
        stallSeconds: 10,
        graceAfterAdoptionSeconds: 15,
        maxConsecutiveFruitlessRestarts: 3,
        maxRestartsPerRecording: 6,
    )

    private func makeFixture(
        _ sessions: [ConfigChangeTestSession],
        limits: MicConfigChangePolicy.Limits = shortLimits,
        decideRetry: @escaping @Sendable (Int) -> CaptureRestartRetryAction = CaptureRestartRetryPolicy.decide,
        isDevicePresent: @escaping @Sendable (String) -> Bool = { _ in false },
    ) -> ConfigChangeTestFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-change-\(UUID().uuidString).wav")
        let queue = ConfigChangeTestSessionQueue(sessions)
        let clock = ConfigChangeTestClock()
        // Typed locals, not trailing closures: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let factory: () -> any MicEngineSessionProviding = { queue.next() }
        let manualNow: @Sendable () -> TimeInterval = { clock.now }
        let handler = MicCaptureHandler(
            outputURL: url,
            sessionFactory: factory,
            decideRetry: decideRetry,
            stallWatchdogLimits: Self.manualStallLimits,
            stallClock: manualNow,
            isDevicePresent: isDevicePresent,
            configChangeLimits: limits,
        )
        return ConfigChangeTestFixture(handler: handler, url: url, clock: clock, sessions: queue)
    }

    /// Drain the main queue until `condition` holds. Adoption and a delayed
    /// restart both run on the main queue, so the observable is the handler's
    /// state after those blocks ran.
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

    /// Give anything that might still be scheduled the time to run, then
    /// let a queued attempt finish building.
    private func settle(_ handler: MicCaptureHandler) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        handler.restartQueue.sync {}
    }

    private func isLive(_ session: ConfigChangeTestSession, in handler: MicCaptureHandler) -> Bool {
        (handler.session as AnyObject) === session
    }

    private func launched(_ fixture: ConfigChangeTestFixture) -> Int {
        fixture.handler.configChangePolicy.launchedInWindow(at: fixture.clock.now)
    }

    // MARK: - The loop

    func testAChangeAfterEveryStartStopsAtTheCapAndTheStallWatchdogThenRestarts() throws {
        let sessions = (0 ..< 5).map { _ in ConfigChangeTestSession() }
        let fixture = makeFixture(sessions)
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        for restart in 1 ... 3 {
            fixture.clock.set(1000 + TimeInterval(restart))
            handler.handleEngineConfigChange()
            waitUntil("configuration-change restart \(restart) adopted") { isLive(sessions[restart], in: handler) }
        }

        fixture.clock.set(1004)
        handler.handleEngineConfigChange()
        settle(handler)
        XCTAssertEqual(fixture.sessions.count, 4, "1 + 3 sessions: the fourth change in the window builds nothing")
        XCTAssertTrue(isLive(sessions[3], in: handler))

        // The last adoption was at 1003: its grace and the stall time have
        // both passed without a buffer.
        fixture.clock.set(1018)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 15))
        waitUntil("the stall restart adopted") { isLive(sessions[4], in: handler) }
    }

    // MARK: - Pacing

    func testTheFirstChangeInAWindowRestartsAtOnce() throws {
        let first = ConfigChangeTestSession()
        let candidate = ConfigChangeTestSession()
        // Held, so the attempt cannot return and move the phase on before
        // the assertion reads it.
        candidate.holdInHardwareFormat = true
        let fixture = makeFixture([first, candidate], limits: .production)
        let handler = fixture.handler
        defer { handler.stop(); candidate.release(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.handleEngineConfigChange()
        XCTAssertEqual(
            handler.arbiter.withLock { $0.phase }, .attemptInFlight(generation: 1),
            "the attempt was launched before the call returned",
        )
        XCTAssertNil(handler.pendingConfigChangeRestart, "nothing was deferred")

        candidate.release()
        waitUntil("adopted") { isLive(candidate, in: handler) }
        XCTAssertEqual(launched(fixture), 1)
    }

    func testASecondChangeInTheWindowWaitsForItsBackoff() throws {
        let sessions = (0 ..< 3).map { _ in ConfigChangeTestSession() }
        let fixture = makeFixture(sessions)
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.handleEngineConfigChange()
        waitUntil("the first restart adopted") { isLive(sessions[1], in: handler) }

        handler.handleEngineConfigChange()
        XCTAssertNotNil(handler.pendingConfigChangeRestart, "the second restart waits for its backoff")
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .capturing, "nothing was launched at once")
        XCTAssertEqual(launched(fixture), 1)

        waitUntil("the delayed restart adopted") { isLive(sessions[2], in: handler) }
        XCTAssertNil(handler.pendingConfigChangeRestart)
        XCTAssertEqual(launched(fixture), 2)
    }

    func testAChangeWhileARestartIsPendingAddsNothing() throws {
        let sessions = (0 ..< 3).map { _ in ConfigChangeTestSession() }
        let fixture = makeFixture(sessions)
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.handleEngineConfigChange()
        waitUntil("the first restart adopted") { isLive(sessions[1], in: handler) }

        handler.handleEngineConfigChange()
        handler.handleEngineConfigChange()
        waitUntil("the delayed restart adopted") { isLive(sessions[2], in: handler) }
        settle(handler)
        XCTAssertEqual(fixture.sessions.count, 3, "both changes share one delayed restart")
        XCTAssertEqual(launched(fixture), 2)
    }

    // MARK: - Dropping a pending restart

    func testStopDropsAPendingRestart() throws {
        let sessions = (0 ..< 2).map { _ in ConfigChangeTestSession() }
        let fixture = makeFixture(sessions)
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.handleEngineConfigChange()
        waitUntil("the first restart adopted") { isLive(sessions[1], in: handler) }
        handler.handleEngineConfigChange()
        let pending = try XCTUnwrap(handler.pendingConfigChangeRestart)

        handler.stop()
        XCTAssertTrue(pending.isCancelled)
        XCTAssertNil(handler.pendingConfigChangeRestart)
        settle(handler)
        XCTAssertEqual(fixture.sessions.count, 2, "nothing is built after the stop")
    }

    func testAnAdoptionDropsAPendingRestart() throws {
        let sessions = (0 ..< 3).map { _ in ConfigChangeTestSession() }
        let fixture = makeFixture(sessions, limits: Self.longBackoffLimits)
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.handleEngineConfigChange()
        waitUntil("the first restart adopted") { isLive(sessions[1], in: handler) }
        handler.handleEngineConfigChange()
        let pending = try XCTUnwrap(handler.pendingConfigChangeRestart)

        handler.handleDeviceChange(.defaultInputChanged)
        waitUntil("the default-input restart adopted") { isLive(sessions[2], in: handler) }
        XCTAssertTrue(pending.isCancelled, "the newer session supersedes the pending restart")
        XCTAssertNil(handler.pendingConfigChangeRestart)
        XCTAssertEqual(launched(fixture), 1, "a default-input restart is not charged to the configuration-change budget")
    }

    func testEitherGiveUpDropsAPendingRestart() throws {
        // The two ways the arbiter abandons the track: the retry budget runs
        // out on attempts that fail, or an attempt never returns.
        for neverReturns in [false, true] {
            let sessions = (0 ..< 3).map { _ in ConfigChangeTestSession() }
            sessions[2].shouldFail = !neverReturns
            sessions[2].holdInHardwareFormat = neverReturns
            let giveUpAtOnce: @Sendable (Int) -> CaptureRestartRetryAction = { _ in .giveUp }
            let fixture = makeFixture(sessions, limits: Self.longBackoffLimits, decideRetry: giveUpAtOnce)
            let handler = fixture.handler
            defer { handler.stop(); sessions[2].release(); try? FileManager.default.removeItem(at: fixture.url) }
            let gaveUp = expectation(description: "give-up reported (attempt never returns: \(neverReturns))")
            handler.onGiveUp = { gaveUp.fulfill() }

            try handler.start()
            handler.handleEngineConfigChange()
            waitUntil("the first restart adopted") { isLive(sessions[1], in: handler) }
            handler.handleEngineConfigChange()
            let pending = try XCTUnwrap(handler.pendingConfigChangeRestart)

            handler.handleDeviceChange(.defaultInputChanged)
            wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)
            XCTAssertTrue(pending.isCancelled, "attempt never returns: \(neverReturns)")
            XCTAssertNil(handler.pendingConfigChangeRestart, "attempt never returns: \(neverReturns)")
        }
    }

    // MARK: - Which device

    func testEveryConfigChangeRestartTargetsAPresentPinnedDevice() throws {
        // Falling back to the built-in microphone would bypass a headset's
        // hardware mute, so a delayed restart re-pins exactly as an
        // immediate one does.
        let sessions = (0 ..< 3).map { _ in ConfigChangeTestSession() }
        // Typed local, not a trailing closure (see `makeFixture`).
        let headsetPresent: @Sendable (String) -> Bool = { $0 == "USBHeadsetUID" }
        let fixture = makeFixture(sessions, isDevicePresent: headsetPresent)
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start(deviceUID: "USBHeadsetUID")
        handler.handleEngineConfigChange()
        waitUntil("the immediate restart adopted") { isLive(sessions[1], in: handler) }
        handler.handleEngineConfigChange()
        XCTAssertNotNil(handler.pendingConfigChangeRestart, "the second restart is the delayed one")
        waitUntil("the delayed restart adopted") { isLive(sessions[2], in: handler) }

        for session in sessions {
            XCTAssertEqual(session.deviceUIDs, ["USBHeadsetUID"])
        }
    }

    // MARK: - Wiring

    func testTheEnginesNotificationReachesThePolicy() throws {
        let first = ConfigChangeTestSession()
        let candidate = ConfigChangeTestSession()
        let fixture = makeFixture([first, candidate])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        // AVFAudio posts from a private queue of its own.
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: first.notificationObject)
        }
        waitUntil("the notification restarted the capture") { isLive(candidate, in: handler) }
        XCTAssertEqual(launched(fixture), 1, "the restart went through the policy and was charged to it")
    }

    func testAChangeDuringAStallRestartLaunchesAndChargesNothing() throws {
        let first = ConfigChangeTestSession()
        let candidate = ConfigChangeTestSession()
        candidate.holdInHardwareFormat = true
        let spare = ConfigChangeTestSession()
        let fixture = makeFixture([first, candidate, spare])
        let handler = fixture.handler
        defer { handler.stop(); candidate.release(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))
        wait(for: [candidate.entered], timeout: 5)

        handler.handleEngineConfigChange()
        XCTAssertEqual(launched(fixture), 0, "the arbiter declined, so the budget is not charged")
        XCTAssertNil(handler.pendingConfigChangeRestart)

        candidate.release()
        waitUntil("the stall restart adopted") { isLive(candidate, in: handler) }
        settle(handler)
        XCTAssertEqual(fixture.sessions.count, 2, "only the stall restart's session was built")
        XCTAssertTrue(spare.deviceUIDs.isEmpty)
        XCTAssertEqual(launched(fixture), 0)
    }
}
