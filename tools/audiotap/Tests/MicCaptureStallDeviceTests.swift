@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// The microphone a capture reports it records from (`activeInputDevice`)
/// across a stall. A stall releases the engine, so nothing records from the
/// device it was on: the menu would otherwise go on naming a microphone the
/// recording no longer hears. A revival reports the device it came back on.
@MainActor
final class MicCaptureStallDeviceTests: XCTestCase {
    nonisolated private static let present: Set = ["HeadsetUID", "USBMicUID"]
    nonisolated private static let isPresent: @Sendable (String) -> Bool = { present.contains($0) }

    private var harness = MicWatchdogHarness()

    override func setUp() {
        super.setUp()
        harness = MicWatchdogHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    func testAStallReportsNoDeviceAndARevivalReportsTheOneItCameBackOn() throws {
        let handler = try harness.makeHandler(deviceUID: "HeadsetUID", isDevicePresent: Self.isPresent)
        XCTAssertEqual(handler.activeInputDevice, ScriptedMicSession.device("HeadsetUID"))

        harness.clock.advance(by: 120) { settle(handler) }
        XCTAssertEqual(harness.stalls.count, 1, "test premise: the capture stalled")
        XCTAssertNil(handler.activeInputDevice, "nothing records from the released device")

        handler.selectDevice(uid: "USBMicUID")
        settle(handler)
        XCTAssertTrue(handler.isRecording, "test premise: the selection revived the capture")
        XCTAssertEqual(handler.activeInputDevice, ScriptedMicSession.device("USBMicUID"))
    }

    /// The other way into a stall: a rebuild whose attempts fail for the
    /// whole budget. Its first attempt released the engine, and none was
    /// adopted, so the device reported before the rebuild is not recording.
    func testARebuildWhoseAttemptsAllFailReportsNoDeviceOnceStalled() throws {
        harness.factory.script(Array(repeating: { $0.shouldThrow = true }, count: 200))
        let handler = try harness.makeHandler(deviceUID: "HeadsetUID", isDevicePresent: Self.isPresent)
        XCTAssertEqual(handler.activeInputDevice, ScriptedMicSession.device("HeadsetUID"))

        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.stalls.count, 1, "test premise: the failed rebuild returned to stalled")
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .stalled)
        XCTAssertNil(handler.activeInputDevice)
    }
}
