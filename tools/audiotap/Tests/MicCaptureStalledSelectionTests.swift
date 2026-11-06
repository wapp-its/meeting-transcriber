@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// Choosing another microphone after the capture stalled for lack of audio and
/// released its engine. The choice goes through the same path as a change of
/// the system input (`handleDeviceChange`), so it is the change a stalled
/// capture waits for: it revives the capture on the chosen device, and the
/// revival is counted and bridged exactly as one a device change starts.
@MainActor
final class MicCaptureStalledSelectionTests: XCTestCase {
    nonisolated private static let present: Set = ["HeadsetUID", "USBMicUID"]

    private var harness = MicWatchdogHarness()

    override func setUp() {
        super.setUp()
        harness = MicWatchdogHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    func testSelectingAMicrophoneRevivesAStalledCaptureOnThatMicrophone() throws {
        let isPresent: @Sendable (String) -> Bool = { Self.present.contains($0) }
        let handler = try harness.makeHandler(deviceUID: "HeadsetUID", isDevicePresent: isPresent)
        harness.clock.advance(by: 120) { settle(handler) }
        XCTAssertEqual(harness.stalls.count, 1, "test premise: the capture stalled")
        XCTAssertEqual(handler.arbiter.withLock { $0.phase }, .stalled)
        let stalled = try XCTUnwrap(harness.sessions.last)
        let before = harness.sessions.count

        handler.selectDevice(uid: "USBMicUID")
        settle(handler)

        XCTAssertEqual(harness.sessions.count, before + 1, "one engine, started by the selection")
        let revived = try XCTUnwrap(harness.sessions.last)
        XCTAssertEqual(revived.deviceUIDs, ["USBMicUID"], "on the microphone just chosen")
        XCTAssertTrue(handler.isRecording)
        XCTAssertEqual(stalled.teardowns, 1, "the engine the stall released is not released again")
        XCTAssertFalse(handler.selectionRestartOutstanding, "its adoption was logged as the selection's")
        // What `noteRevival` records for a revival a device change starts.
        XCTAssertEqual(handler.progress.revivalsWithoutAudio, 1, "counted against the revival cap")
        XCTAssertTrue(handler.progress.revivalAwaitingAudio, "reported as back only once it delivers")
        XCTAssertEqual(handler.progress.rebuildsWithoutAudio, 0, "with a fresh budget")
        XCTAssertEqual(harness.resumes, 0)

        harness.keepDelivering(revived)
        harness.clock.advance(by: 3600) { settle(handler) }

        XCTAssertEqual(harness.resumes, 1, "reported as back once it delivered")
        XCTAssertEqual(harness.stalls.count, 1, "and it stays up while it delivers")
        XCTAssertEqual(handler.progress.revivalsWithoutAudio, 0, "delivery clears the revival count")
        XCTAssertEqual(harness.sessions.count, before + 1)
    }
}
