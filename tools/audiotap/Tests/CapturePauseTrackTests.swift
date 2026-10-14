@testable import AudioTapLib
import XCTest

/// What a pause does to one track besides the cut itself, which
/// `CapturePauseAlignmentTests` measures: how it meets a real gap in the
/// buffers, and what the microphone keeps reporting while it lasts.
@available(macOS 14.2, *)
final class CapturePauseTrackTests: XCTestCase {
    private static let base = 1000.0

    /// A gap in delivery from 1 s to 3 s (a device restart) with a pause from
    /// 1.5 s to 2.5 s inside it. The gap fill writes silence for the gap's
    /// unpaused part only, half a second before the pause and half a second
    /// after the resume, and never hands that silence to the live sink.
    func testAGapAroundAPauseIsFilledOnlyForItsUnpausedPart() throws {
        for makeDriver in Self.drivers {
            let gate = CapturePauseGate()
            let driver = try makeDriver(gate)
            let oneSecond = [Float](repeating: 0.25, count: Int(driver.inputRate))

            try driver.deliver(oneSecond, atHostSeconds: Self.base)
            gate.pause(atHostSeconds: Self.base + 1.5)
            gate.resume(atHostSeconds: Self.base + 2.5)
            try driver.deliver(oneSecond, atHostSeconds: Self.base + 3)
            let output = try driver.finish()

            // The converters hold back a few frames at the start, which the
            // first gap fill also covers; 3 ms is far below the half second
            // either wrong answer (no fill, or a fill for the whole gap) is off by.
            let silence = Double(output.file.count - output.sink.count)
            XCTAssertEqual(silence, speechSampleRate, accuracy: 48, "\(driver.name): silence for the unpaused second only")
            XCTAssertEqual(
                Double(output.sink.count), 2 * speechSampleRate, accuracy: 48,
                "\(driver.name): the sink gets both seconds of audio and no silence",
            )
        }
    }

    /// The level and the buffer ages read the live device, not the file, so
    /// a buffer delivered during a pause still moves them; it reaches neither
    /// the file nor the live sink.
    func testTheMicrophoneKeepsReportingWhilePaused() throws {
        let gate = CapturePauseGate()
        let driver = try MicPauseTrackDriver(gate: gate)
        XCTAssertNil(driver.handler.currentSignalAges.secondsSinceLastBuffer, "nothing delivered yet")

        gate.pause(atHostSeconds: Self.base)
        let tone = (0 ..< 4410).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        try driver.deliver(tone, atHostSeconds: Self.base + 0.1)

        XCTAssertGreaterThan(driver.handler.currentLevelDBFS, -20, "the paused buffer's level is published")
        let age = try XCTUnwrap(driver.handler.currentSignalAges.secondsSinceLastBuffer)
        XCTAssertLessThan(age, 1, "the paused buffer counts as delivered")
        let output = try driver.finish()
        XCTAssertEqual(output.file.count, 0, "a paused buffer is not written")
        XCTAssertEqual(output.sink.count, 0, "a paused buffer is not forwarded")
    }

    private static var drivers: [(CapturePauseGate) throws -> any PauseTrackDriver] {
        [{ AppPauseTrackDriver(gate: $0) }, { try MicPauseTrackDriver(gate: $0) }]
    }
}
