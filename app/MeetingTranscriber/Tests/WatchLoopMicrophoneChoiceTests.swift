import Foundation
@testable import MeetingTranscriber
import XCTest

/// The microphone a recording opens with is the one chosen when that recording
/// starts. The watch loop used to copy the choice when watching started, so a
/// microphone picked while watching was on reached no recording until watching
/// was switched off and on again.
@MainActor
final class WatchLoopMicrophoneChoiceTests: XCTestCase {
    /// Reports nothing until a test hands it a meeting, so a loop can be
    /// watching before any meeting exists. Polled on the main actor only.
    private final class SwitchableMeetingDetector: MeetingDetecting {
        var meeting: DetectedMeeting?

        func checkOnce() -> DetectedMeeting? {
            meeting
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            true
        }

        func reset(appName _: String?) {}
    }

    /// Through `WatchingController`, on the loop it built when watching
    /// started: a choice made after that reaches the next detected meeting,
    /// and watching is not restarted to get there.
    func testAChoiceMadeWhileWatchingReachesTheNextDetectedMeeting() async throws {
        let dir = try makeTempDirectory(prefix: "WatchLoopMicrophoneChoiceTests")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let detector = SwitchableMeetingDetector()
        let recorder = makeMockRecorder()
        let controller = makeWatchingController(
            logDir: dir, permissionHealth: .allHealthy,
            makeDetector: { detector },
            makeRecorder: { recorder },
        )
        controller.settings.recordWithoutAskingApps = [testMeetingApp]
        controller.settings.micDeviceUID = "BuiltInUID"
        // The floor, so the poll after the first empty one comes within a second.
        controller.settings.pollInterval = 1
        let started = await controller.startWatching()
        addTeardownBlock { _ = await controller.stopWatching() }
        XCTAssertEqual(started, .changed, "precondition")
        let loop = try XCTUnwrap(controller.watchLoop)

        controller.settings.micDeviceUID = "HeadsetUID"
        detector.meeting = makeTestMeeting()
        await waitFor({ recorder.startCalled }, timeout: .seconds(5))

        XCTAssertTrue(recorder.startCalled, "precondition: the meeting must be recording by now")
        XCTAssertIdentical(controller.watchLoop, loop, "the choice must arrive without restarting watching")
        XCTAssertEqual(recorder.capturedMicDeviceUID, "HeadsetUID")
    }
}
