@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The watchdog's clock in the tests below: it moves only when told to.
private final class StopRaceTestClock: @unchecked Sendable {
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

/// A session that never touches audio hardware. It records every call the
/// handler makes on it, in order, and can fail its bring-up.
private final class StopRaceTestSession: MicEngineSessionProviding, @unchecked Sendable {
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
    let clock: StopRaceTestClock
    let sessions: StopRaceTestSessionQueue
}

/// A restart that is on its way when the capture stops.
///
/// A restart is claimed and charged on the main queue and then handed to the
/// serial restart queue, where its first step is to build a new session.
/// `stop()` returns without waiting for that queue, because an attempt there
/// can block forever inside the engine. An attempt that was queued but had not
/// started when `stop()` ran therefore still builds its session afterwards.
///
/// These hold the restart queue with a blocking item, so the attempt is
/// queued, not started, whenever `stop()` is called: the schedule that a
/// loaded machine produces only sometimes happens on every run here.
final class MicCaptureHandlerStopRaceTests: XCTestCase {
    /// Production limits, with a poll interval no test reaches, so only the
    /// test's own `pollStallWatchdog()` calls tick.
    private static let manualLimits = MicStallWatchdogPolicy.Limits(
        pollIntervalSeconds: 3600,
        stallSeconds: 10,
        graceAfterAdoptionSeconds: 15,
        maxConsecutiveFruitlessRestarts: 3,
        maxRestartsPerRecording: 6,
    )

    private func makeFixture(_ sessions: [StopRaceTestSession]) -> StopRaceTestFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-race-\(UUID().uuidString).wav")
        let queue = StopRaceTestSessionQueue(sessions)
        let clock = StopRaceTestClock()
        // Typed locals, not trailing closures: SwiftFormat restyles a labelled
        // closure argument into a trailing one and mangles the call.
        let factory: () -> any MicEngineSessionProviding = { queue.next() }
        let manualNow: @Sendable () -> TimeInterval = { clock.now }
        let handler = MicCaptureHandler(
            outputURL: url,
            sessionFactory: factory,
            stallWatchdogLimits: Self.manualLimits,
            stallClock: manualNow,
        )
        return StopRaceTestFixture(handler: handler, url: url, clock: clock, sessions: queue)
    }

    func testAStallRestartQueuedWhenStopIsCalledBuildsNoSession() throws {
        let first = StopRaceTestSession()
        let candidate = StopRaceTestSession()
        let fixture = makeFixture([first, candidate])
        let handler = fixture.handler
        // Signalled on every path, so a failing run never leaves the queue held.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); try? FileManager.default.removeItem(at: fixture.url) }

        try handler.start()
        handler.restartQueue.async { gate.wait() }
        fixture.clock.set(1010)
        XCTAssertEqual(handler.pollStallWatchdog(), .restart(silentSeconds: 10))

        handler.stop()
        let builtAtStop = fixture.sessions.count
        XCTAssertEqual(builtAtStop, 1, "the stall restart is queued, not started, when stop() returns")

        gate.signal()
        handler.restartQueue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertIdentical(handler.session as AnyObject, first, "a stopped capture adopts nothing")
        XCTExpectFailure("a restart queued before stop() still builds and starts its session after stop() returned") {
            XCTAssertEqual(fixture.sessions.count, builtAtStop, "no session is built after the stop")
            XCTAssertEqual(candidate.calls, [], "the queued restart never touches its session")
        }
    }
}
