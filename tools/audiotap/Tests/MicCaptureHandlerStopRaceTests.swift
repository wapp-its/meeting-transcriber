@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// A session that never touches audio hardware. It records every call the
/// handler makes on it, in order, and can fail its bring-up.
private final class StopRaceTestSession: MicEngineSessionProviding, @unchecked Sendable {
    let followsSystemDefaultInput = false
    private let stateLock = NSLock()
    private var recordedCalls: [String] = []

    var shouldFail = false

    let notificationObject: AnyObject = NSObject()
    // swiftlint:disable:next force_unwrapping
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    var calls: [String] {
        stateLock.withLock { recordedCalls }
    }

    private func record(_ call: String) {
        stateLock.withLock { recordedCalls.append(call) }
    }

    func hardwareFormat(deviceUID _: String?) throws -> AVAudioFormat {
        record("hardwareFormat")
        if shouldFail { throw MicCaptureError.noInputDevice }
        return format
    }

    func installTap(format _: AVAudioFormat, block _: AVAudioNodeTapBlock) {
        record("installTap")
    }

    func start() {
        record("start")
    }

    func teardown() {
        record("teardown")
    }
}

/// Hands out the queued sessions in order, counting every one built. Called
/// on the main queue at init and on the restart queue for each attempt.
private final class StopRaceTestSessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [StopRaceTestSession]
    private var built = 0

    init(_ sessions: [StopRaceTestSession]) {
        remaining = sessions
    }

    var count: Int {
        lock.withLock { built }
    }

    func next() -> StopRaceTestSession {
        lock.withLock {
            built += 1
            return remaining.isEmpty ? StopRaceTestSession() : remaining.removeFirst()
        }
    }
}

private struct StopRaceTestFixture {
    let handler: MicCaptureHandler
    let url: URL
    let clock: ManualMainClock
    let sessions: StopRaceTestSessionQueue
}

/// A restart that is on its way when the capture stops.
///
/// A restart is granted on the main queue and then handed to the serial
/// restart queue, where it builds a new session once any silence bridge is
/// written.
/// `stop()` returns without waiting for that queue, because an attempt there
/// can block forever inside the engine. An attempt that was queued but had not
/// started when `stop()` ran would therefore build its session afterwards,
/// unless it asks the arbiter first, under the lock `stop()`'s seal takes.
///
/// These hold the restart queue with a blocking item, so the attempt is
/// queued, not started, whenever `stop()` is called: the schedule that a
/// loaded machine produces only sometimes happens on every run here.
///
/// The handler's timers (the progress watchdog, the attempt deadline and the
/// retry backoff) run on a manual clock, so only the test's own `advance`
/// fires them.
final class MicCaptureHandlerStopRaceTests: XCTestCase {
    private func makeFixture(
        _ sessions: [StopRaceTestSession],
        decideRetry: @escaping @Sendable (Int) -> CaptureRestartRetryAction = CaptureRestartRetryPolicy.decide,
    ) -> StopRaceTestFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-race-\(UUID().uuidString).wav")
        let queue = StopRaceTestSessionQueue(sessions)
        let clock = ManualMainClock()
        // Typed locals, not trailing closures: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let factory: () -> any MicEngineSessionProviding = { queue.next() }
        let handler = MicCaptureHandler(
            outputURL: url,
            sessionFactory: factory,
            decideRetry: decideRetry,
            scheduleOnMain: clock.scheduler,
            clock: clock.reading,
        )
        return StopRaceTestFixture(handler: handler, url: url, clock: clock, sessions: queue)
    }

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

    func testARebuildQueuedWhenStopIsCalledBuildsNoSession() throws {
        let first = StopRaceTestSession()
        let candidate = StopRaceTestSession()
        let fixture = makeFixture([first, candidate])
        let handler = fixture.handler
        // Signalled on every path, so a failing run never leaves the queue held.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.restartQueue.async { gate.wait() }
        // No buffer within the first deadline: the progress watchdog orders a rebuild.
        fixture.clock.advance(by: MicCaptureProgressPolicy.firstBufferDeadline)
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .attemptInFlight(generation: 2))

        handler.stop()
        let builtAtStop = fixture.sessions.count
        XCTAssertEqual(builtAtStop, 1, "the rebuild is queued, not started, when stop() returns")

        gate.signal()
        handler.restartQueue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertIdentical(handler.session as AnyObject, first, "a stopped capture adopts nothing")
        XCTAssertEqual(fixture.sessions.count, builtAtStop, "no session is built after the stop")
        XCTAssertEqual(candidate.calls, [], "the queued restart never touches its session")
    }

    func testADefaultInputRestartQueuedWhenStopIsCalledBuildsNoSession() throws {
        // The refusal sits on the attempt path every trigger shares, not on the
        // progress watchdog's own.
        let fixture = makeFixture([StopRaceTestSession(), StopRaceTestSession()])
        let handler = fixture.handler
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.restartQueue.async { gate.wait() }
        XCTAssertTrue(handler.handleDeviceChange(), "the device change launched a restart")

        handler.stop()
        gate.signal()
        handler.restartQueue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(fixture.sessions.count, 1, "no session is built after the stop")
    }

    func testARetryWaitingOutItsBackoffWhenStopIsCalledBuildsNoSession() throws {
        // A retry is launched from the main queue only once the arbiter grants
        // it, and a stopped capture never does. Pinned because "no restart
        // after stop" covers this restart too.
        let failing = StopRaceTestSession()
        failing.shouldFail = true
        // Typed local, not a trailing closure (see `makeFixture`).
        let slowRetry: @Sendable (Int) -> CaptureRestartRetryAction = { _ in .retry(afterSeconds: 0.2) }
        let fixture = makeFixture([StopRaceTestSession(), failing], decideRetry: slowRetry)
        let handler = fixture.handler
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        fixture.clock.advance(by: MicCaptureProgressPolicy.firstBufferDeadline)
        waitUntil("the failed rebuild waits out its backoff") {
            handler.arbiter.withLock { $0.phase } == .backingOff && handler.restartRetryCount == 1
        }

        handler.stop()
        let builtAtStop = fixture.sessions.count
        XCTAssertEqual(builtAtStop, 2, "the retry is waiting out its backoff when stop() returns")
        // Past the backoff and the attempt deadline: the retry falls due on a stopped capture.
        fixture.clock.advance(by: RestartArbiter.attemptTimeout + 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        handler.restartQueue.sync {}

        XCTAssertEqual(fixture.sessions.count, builtAtStop, "no session is built after the stop")
    }
}
