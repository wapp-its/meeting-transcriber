@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The handler's clock in the tests below: it moves only when told to.
private final class SelectionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000

    var now: TimeInterval {
        lock.withLock { value }
    }
}

/// A session that never touches audio hardware. It records the device every
/// bring-up was asked for and reports, as the device it is bound to, the one it
/// was asked for (`systemDefaultUID` when asked for none), so an adoption is
/// assertable by the device it publishes. It can hold inside `hardwareFormat`
/// until released, which keeps a restart attempt in flight, and can fail its
/// bring-up, after the hold when both are set.
private final class SelectionTestSession: MicEngineSessionProviding, @unchecked Sendable {
    static let systemDefaultUID = "SystemDefaultInputUID"

    private let stateLock = NSLock()
    private var recordedDeviceUIDs: [String?] = []
    private var lastRequested = SelectionTestSession.systemDefaultUID
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

    var boundInputDevice: MicInputDevice? {
        Self.device(stateLock.withLock { lastRequested })
    }

    static func device(_ uid: String) -> MicInputDevice {
        MicInputDevice(uid: uid, name: "Microphone \(uid)")
    }

    func release() {
        gate.signal()
    }

    func hardwareFormat(deviceUID: String?) throws -> AVAudioFormat {
        stateLock.withLock {
            recordedDeviceUIDs.append(deviceUID)
            lastRequested = deviceUID ?? Self.systemDefaultUID
        }
        if holdInHardwareFormat {
            entered.fulfill()
            // Bounded, so a test that goes wrong fails instead of hanging.
            _ = gate.wait(timeout: .now() + 10)
        }
        if shouldFail { throw MicCaptureError.noInputDevice }
        return format
    }

    func installTap(format _: AVAudioFormat, block _: AVAudioNodeTapBlock) {}

    func start() {}

    func teardown() {}
}

/// Hands out the queued sessions in order, counting every one built. Called
/// on the main queue at init and on the restart queue for each attempt.
private final class SelectionTestSessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [SelectionTestSession]
    private var built = 0

    init(_ sessions: [SelectionTestSession]) {
        remaining = sessions
    }

    var count: Int {
        lock.withLock { built }
    }

    func next() -> SelectionTestSession {
        lock.withLock {
            built += 1
            return remaining.isEmpty ? SelectionTestSession() : remaining.removeFirst()
        }
    }
}

private struct SelectionTestFixture {
    let handler: MicCaptureHandler
    let url: URL
    let clock: SelectionTestClock
    let sessions: SelectionTestSessionQueue
}

/// Choosing another microphone while a recording runs, end to end through the
/// handler: the choice rides the device-change restart path (one attempt at a
/// time, the arbiter's deadline, the retry budget), is applied after a
/// restart that is already running, and is what a retry aims at.
final class MicCaptureHandlerDeviceSelectionTests: XCTestCase {
    /// The stall watchdog's production limits with a poll interval no test
    /// reaches, so it never launches anything of its own here.
    private static let manualStallLimits = MicStallWatchdogPolicy.Limits(
        pollIntervalSeconds: 3600,
        stallSeconds: 10,
        graceAfterAdoptionSeconds: 15,
        maxConsecutiveFruitlessRestarts: 3,
        maxRestartsPerRecording: 6,
    )

    /// A backoff long enough that a test can act inside it, short enough to
    /// wait out.
    private static let slowRetry: @Sendable (Int) -> CaptureRestartRetryAction = { attempts in
        attempts < 3 ? .retry(afterSeconds: 0.5) : .giveUp
    }

    private static let present: Set = ["HeadsetUID", "USBMicUID", "BuiltInUID"]

    private func makeFixture(
        _ sessions: [SelectionTestSession],
        decideRetry: @escaping @Sendable (Int) -> CaptureRestartRetryAction = slowRetry,
    ) -> SelectionTestFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-\(UUID().uuidString).wav")
        let queue = SelectionTestSessionQueue(sessions)
        let clock = SelectionTestClock()
        // Typed locals, not trailing closures: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let factory: () -> any MicEngineSessionProviding = { queue.next() }
        let manualNow: @Sendable () -> TimeInterval = { clock.now }
        let isPresent: @Sendable (String) -> Bool = { Self.present.contains($0) }
        let handler = MicCaptureHandler(
            outputURL: url,
            sessionFactory: factory,
            decideRetry: decideRetry,
            stallWatchdogLimits: Self.manualStallLimits,
            stallClock: manualNow,
            isDevicePresent: isPresent,
        )
        return SelectionTestFixture(handler: handler, url: url, clock: clock, sessions: queue)
    }

    /// Drain the main queue until `condition` holds. Adoption runs on the
    /// main queue, so the observable is the handler's state after it ran.
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

    /// Give anything that might still be scheduled the time to run, then let a
    /// queued attempt finish building.
    private func settle(_ handler: MicCaptureHandler) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        handler.restartQueue.sync {}
    }

    private func isLive(_ session: SelectionTestSession, in handler: MicCaptureHandler) -> Bool {
        (handler.session as AnyObject) === session
    }

    /// A selection restart is charged to neither the stall watchdog's budget
    /// nor the configuration-change window (R7).
    private func assertNoBudgetCharged(
        _ fixture: SelectionTestFixture, file: StaticString = #filePath, line: UInt = #line,
    ) {
        let stall = fixture.handler.stallWatchdog.withLock { ($0.restartsLaunched, $0.consecutiveFruitless) }
        XCTAssertEqual(stall.0, 0, "stall restarts launched", file: file, line: line)
        XCTAssertEqual(stall.1, 0, "fruitless stall restarts", file: file, line: line)
        XCTAssertEqual(
            fixture.handler.configChangePolicy.launchedInWindow(at: fixture.clock.now), 0,
            "configuration-change restarts in the window", file: file, line: line,
        )
    }

    // MARK: - Selecting while capturing

    func testASelectionWhileCapturingRestartsOnceOnTheNewDeviceAndPublishesIt() throws {
        let first = SelectionTestSession()
        let candidate = SelectionTestSession()
        // Held, so the attempt cannot be adopted before the assertions read
        // the state during it.
        candidate.holdInHardwareFormat = true
        let fixture = makeFixture([first, candidate])
        let handler = fixture.handler
        defer { handler.stop(); candidate.release(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start(deviceUID: "HeadsetUID")
        XCTAssertEqual(handler.activeInputDevice, SelectionTestSession.device("HeadsetUID"))

        handler.selectDevice(uid: "USBMicUID")
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .attemptInFlight(generation: 1))
        wait(for: [candidate.entered], timeout: 5)
        XCTAssertEqual(
            handler.activeInputDevice, SelectionTestSession.device("HeadsetUID"),
            "the previous device is reported until the restart is adopted",
        )

        candidate.release()
        waitUntil("the selection restart adopted") { isLive(candidate, in: handler) }
        settle(handler)
        XCTAssertEqual(fixture.sessions.count, 2, "exactly one attempt was built")
        XCTAssertEqual(candidate.deviceUIDs, ["USBMicUID"])
        XCTAssertEqual(handler.activeInputDevice, SelectionTestSession.device("USBMicUID"))
        XCTAssertFalse(handler.selectionPending)
        assertNoBudgetCharged(fixture)
    }

    func testSelectingTheCurrentDeviceAgainLaunchesNothing() throws {
        for current in ["HeadsetUID", nil] as [String?] {
            let fixture = makeFixture([])
            let handler = fixture.handler
            defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

            try handler.start(deviceUID: current)
            handler.selectDevice(uid: current)
            settle(handler)
            XCTAssertEqual(fixture.sessions.count, 1, "current device \(current ?? "nil")")
            XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .capturing)
        }
    }

    func testASelectionOfAnAbsentDeviceTargetsTheSystemDefault() throws {
        let candidate = SelectionTestSession()
        let fixture = makeFixture([SelectionTestSession(), candidate])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start(deviceUID: "HeadsetUID")
        handler.selectDevice(uid: "UnpluggedUID")
        waitUntil("the selection restart adopted") { isLive(candidate, in: handler) }

        XCTAssertEqual(candidate.deviceUIDs, [nil])
        XCTAssertEqual(handler.activeInputDevice, SelectionTestSession.device(SelectionTestSession.systemDefaultUID))
    }

    // MARK: - Selecting while a restart runs

    func testSelectionsDuringAnOutstandingAttemptAddOneAttemptAfterItsAdoptionAndTheLastWins() throws {
        let first = SelectionTestSession()
        let inFlight = SelectionTestSession()
        inFlight.holdInHardwareFormat = true
        let applied = SelectionTestSession()
        let fixture = makeFixture([first, inFlight, applied])
        let handler = fixture.handler
        defer { handler.stop(); inFlight.release(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start(deviceUID: "HeadsetUID")
        XCTAssertTrue(handler.handleDeviceChange(.defaultInputChanged))
        wait(for: [inFlight.entered], timeout: 5)

        handler.selectDevice(uid: "USBMicUID")
        handler.selectDevice(uid: "BuiltInUID")
        XCTAssertTrue(handler.selectionPending, "both selections wait for the running restart")
        XCTAssertEqual(fixture.sessions.count, 2, "nothing was launched beside the running attempt")

        inFlight.release()
        waitUntil("the deferred selection restart adopted") { isLive(applied, in: handler) }
        settle(handler)
        XCTAssertEqual(inFlight.deviceUIDs, ["HeadsetUID"])
        XCTAssertEqual(applied.deviceUIDs, ["BuiltInUID"], "the last selection is the one applied")
        XCTAssertEqual(fixture.sessions.count, 3, "exactly one more attempt after the adoption")
        XCTAssertEqual(handler.activeInputDevice, SelectionTestSession.device("BuiltInUID"))
        XCTAssertFalse(handler.selectionPending)
        assertNoBudgetCharged(fixture)
    }

    func testASelectionDuringABackoffIsUsedByTheRetryWithoutAnExtraAttempt() throws {
        let first = SelectionTestSession()
        let failing = SelectionTestSession()
        failing.shouldFail = true
        let retry = SelectionTestSession()
        let fixture = makeFixture([first, failing, retry])
        let handler = fixture.handler
        defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start(deviceUID: "HeadsetUID")
        XCTAssertTrue(handler.handleDeviceChange(.defaultInputChanged))
        waitUntil("the failed attempt is backing off") { handler.restartRetryCount == 1 }

        handler.selectDevice(uid: "USBMicUID")
        XCTAssertTrue(handler.selectionPending)
        waitUntil("the retry adopted") { isLive(retry, in: handler) }
        settle(handler)
        XCTAssertEqual(retry.deviceUIDs, ["USBMicUID"])
        XCTAssertEqual(fixture.sessions.count, 3, "the retry applied the selection, nothing else was launched")
        XCTAssertEqual(handler.activeInputDevice, SelectionTestSession.device("USBMicUID"))
        assertNoBudgetCharged(fixture)
    }

    /// Today's retry falls back to the device it was aimed at when the current
    /// target resolves to nil, which after a selection is the failing previous
    /// device rather than the system default the user chose.
    func testSystemDefaultOrAnUnconnectedDeviceChosenDuringABackoffIsWhatTheRetryAimsAt() throws {
        for choice in [nil, "UnpluggedUID"] as [String?] {
            let failing = SelectionTestSession()
            failing.shouldFail = true
            let retry = SelectionTestSession()
            let fixture = makeFixture([SelectionTestSession(), failing, retry])
            let handler = fixture.handler
            defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

            try handler.start(deviceUID: "HeadsetUID")
            XCTAssertTrue(handler.handleDeviceChange(.defaultInputChanged))
            waitUntil("the failed attempt is backing off") { handler.restartRetryCount == 1 }

            handler.selectDevice(uid: choice)
            waitUntil("the retry adopted") { isLive(retry, in: handler) }
            XCTAssertEqual(failing.deviceUIDs, ["HeadsetUID"])
            XCTAssertEqual(retry.deviceUIDs, [nil], "choice \(choice ?? "System Default")")
        }
    }

    // MARK: - Sealed sessions

    func testASelectionAfterStopOrGiveUpLaunchesNothing() throws {
        for gaveUpFirst in [false, true] {
            let failing = SelectionTestSession()
            failing.shouldFail = true
            let giveUpAtOnce: @Sendable (Int) -> CaptureRestartRetryAction = { _ in .giveUp }
            let fixture = makeFixture([SelectionTestSession(), failing], decideRetry: giveUpAtOnce)
            let handler = fixture.handler
            defer { handler.stop(); try? FileManager.default.removeItem(at: fixture.url) }

            try handler.start(deviceUID: "HeadsetUID")
            if gaveUpFirst {
                let gaveUp = expectation(description: "give-up reported")
                handler.onGiveUp = { gaveUp.fulfill() }
                XCTAssertTrue(handler.handleDeviceChange(.defaultInputChanged))
                wait(for: [gaveUp], timeout: 5)
            } else {
                handler.stop()
            }
            let built = fixture.sessions.count

            handler.selectDevice(uid: "USBMicUID")
            settle(handler)
            XCTAssertEqual(fixture.sessions.count, built, "gave up first: \(gaveUpFirst)")
            XCTAssertFalse(handler.selectionPending, "gave up first: \(gaveUpFirst)")
        }
    }

    // MARK: - The device reported

    func testTheActiveDeviceIsNilBeforeStartAndAfterStopAndAfterEitherGiveUp() throws {
        let stopped = makeFixture([])
        XCTAssertNil(stopped.handler.activeInputDevice, "before start")
        try stopped.handler.start(deviceUID: "HeadsetUID")
        XCTAssertEqual(stopped.handler.activeInputDevice, SelectionTestSession.device("HeadsetUID"))
        stopped.handler.stop()
        XCTAssertNil(stopped.handler.activeInputDevice, "after stop")
        try? FileManager.default.removeItem(at: stopped.url)

        // The two ways the arbiter abandons the track: the retry budget runs
        // out on an attempt that fails, or an attempt never returns. A second
        // selection made while the first one's attempt runs is pending then,
        // and the give-up drops it too.
        for neverReturns in [false, true] {
            let attempt = SelectionTestSession()
            attempt.holdInHardwareFormat = true
            attempt.shouldFail = !neverReturns
            let giveUpAtOnce: @Sendable (Int) -> CaptureRestartRetryAction = { _ in .giveUp }
            let fixture = makeFixture([SelectionTestSession(), attempt], decideRetry: giveUpAtOnce)
            let handler = fixture.handler
            defer { handler.stop(); attempt.release(); try? FileManager.default.removeItem(at: fixture.url) }
            let gaveUp = expectation(description: "give-up reported (attempt never returns: \(neverReturns))")
            handler.onGiveUp = { gaveUp.fulfill() }

            try handler.start(deviceUID: "HeadsetUID")
            handler.selectDevice(uid: "USBMicUID")
            wait(for: [attempt.entered], timeout: 5)
            handler.selectDevice(uid: "BuiltInUID")
            XCTAssertTrue(handler.selectionPending)
            if !neverReturns { attempt.release() }

            wait(for: [gaveUp], timeout: RestartArbiter.attemptTimeout + 5)
            XCTAssertNil(handler.activeInputDevice, "attempt never returns: \(neverReturns)")
            XCTAssertFalse(handler.selectionPending, "attempt never returns: \(neverReturns)")
        }
    }

    /// The lines are unconditional and public, and `PersistentDiagnosticLog`
    /// writes them into the file Settings exports as redacted, so none may name
    /// or identify a device. Notice level, because info lines are not retained.
    func testTheSelectionLogLinesAreNoticeLevelAndNameNoDevice() {
        let lines: [(MicSelectionLogLine, String)] = [
            (.restarting, "Mic: microphone selection changed during the recording, restarting capture"),
            (.deferred, "Mic: microphone selection changed while a restart is running, applying it after that restart"),
            (.adopted(rate: 24000), "Mic: capture restarted on the newly selected microphone (24000 Hz)"),
        ]
        for (line, expected) in lines {
            XCTAssertEqual(line.text, expected)
            XCTAssertEqual(line.level, .default, "notice is os_log's default level: \(expected)")
            XCTAssertEqual(line.text.filter { $0 == ":" }.count, 1, expected)
            XCTAssertNil(line.text.range(of: "uid", options: .caseInsensitive), expected)
            XCTAssertNil(line.text.range(of: "name", options: .caseInsensitive), expected)
        }
    }
}
