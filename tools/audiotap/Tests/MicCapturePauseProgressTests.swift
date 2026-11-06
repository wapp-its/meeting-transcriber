@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// A paused recording against the progress watchdog, driven through the
/// handler's real tap block with a manual clock.
///
/// A pause cuts every buffer out of the file, so a watchdog that judged
/// delivery by what was written would read a pause longer than its budget as
/// a dead microphone: rebuild the engine, then release it and tell the user
/// the microphone is lost while it works. The tap block publishes each buffer
/// before the pause cut, which keeps the watchdog's last-buffer time fresh
/// through any pause.
@MainActor
final class MicCapturePauseProgressTests: XCTestCase {
    private typealias Policy = MicCaptureProgressPolicy

    private var harness = MicWatchdogHarness()

    override func setUp() {
        super.setUp()
        harness = MicWatchdogHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    func testAPauseLongerThanTheBudgetNeitherReleasesNorRebuildsTheMicrophone() throws {
        let gate = CapturePauseGate()
        let handler = try harness.makeHandler(pauseGate: gate)
        let engine = try XCTUnwrap(harness.sessions.first)
        harness.keepDelivering(engine)
        harness.clock.advance(by: 5) { settle(handler) }
        let beforePause = try XCTUnwrap(handler.outputFile).length
        XCTAssertGreaterThan(beforePause, 0, "test premise: the microphone delivered before the pause")

        gate.pause()
        harness.clock.advance(by: 2 * Policy.maxSecondsWithoutAudio) { settle(handler) }

        XCTAssertEqual(
            try XCTUnwrap(handler.outputFile).length, beforePause,
            "test premise: nothing captured during the pause reached the file",
        )
        XCTAssertEqual(harness.stalls, [], "a pause is not a stall")
        XCTAssertEqual(harness.sessions.count, 1, "no rebuild during the pause")
        XCTAssertEqual(engine.teardowns, 0, "the microphone was not released")
        XCTAssertEqual(handler.progress.rebuildsWithoutAudio, 0)
        XCTAssertTrue(handler.isRecording)

        gate.resume()
        harness.clock.advance(by: 5) { settle(handler) }

        XCTAssertGreaterThan(try XCTUnwrap(handler.outputFile).length, beforePause, "the capture goes on after the resume")
        XCTAssertEqual(harness.sessions.count, 1, "on the same engine")
        XCTAssertEqual(harness.stalls, [])
    }
}
