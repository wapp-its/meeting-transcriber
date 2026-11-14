@testable import MeetingTranscriber
import XCTest

/// "Record Again" through `WatchingController`'s real auto-detect path, so the
/// transition handler that posts "Meeting Detected" is the production one:
/// it announces a detection, not the recording a click started, and again
/// the next call's recording that a split starts after it.
///
/// Real time, because the controller builds its loop from `AppSettings`; the
/// poll interval is set to its one-second floor.
@MainActor
final class WatchingControllerRecordAgainTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerRecordAgainTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// Always in a call, so a stop by hand holds the app; changing `callID`
    /// while recording is a split.
    private final class CallDetector: MeetingDetecting {
        var callID = "call-A"

        func checkOnce() -> DetectedMeeting? {
            makeTestMeeting(pid: getpid())
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            true
        }

        func activeCalls(_: DetectedMeeting) -> ActiveCalls {
            .ids([callID])
        }

        func reset(appName _: String?) {}
    }

    /// Generous: each step takes about one one-second poll, and every wait
    /// below ends as soon as its condition holds.
    private let stepTimeout: Duration = .seconds(10)

    private func announcements(_ notifier: RecordingNotifier) -> Int {
        notifier.calls.count { $0.title == "Meeting Detected" }
    }

    func testTheClicksRecordingIsNotAnnouncedAndASplitAfterItIs() async {
        let detector = CallDetector()
        let notifier = RecordingNotifier()
        let controller = makeWatchingController(logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy) { detector }
        controller.settings.pollInterval = 1
        controller.settings.recordWithoutAskingApps = [testMeetingApp]
        let offer = RecordAgainOffer(identityKey: testMeetingApp, appName: testMeetingApp)
        XCTAssertFalse(controller.recordAgain(offer), "nothing is watching")
        let started = await controller.startWatching()
        addTeardownBlock { _ = await controller.stopWatching() }
        XCTAssertEqual(started, .changed, "precondition")

        await waitFor({ controller.watchLoop?.state == .recording }, timeout: stepTimeout)
        XCTAssertEqual(announcements(notifier), 1, "the detection is announced")
        controller.stopRecording()
        await waitFor({ controller.watchLoop?.recordAgainOffers == [offer] }, timeout: stepTimeout)
        XCTAssertEqual(controller.watchLoop?.recordAgainOffers, [offer], "precondition: held and offered")

        XCTAssertTrue(controller.recordAgain(offer))
        await waitFor({ controller.watchLoop?.state == .recording }, timeout: stepTimeout)
        XCTAssertEqual(controller.watchLoop?.state, .recording, "precondition: the click's recording runs")
        XCTAssertEqual(announcements(notifier), 1, "the click's recording is not announced")

        detector.callID = "call-B"
        await waitFor({ self.announcements(notifier) == 2 }, timeout: stepTimeout)
        XCTAssertEqual(announcements(notifier), 2, "the split's recording is")
    }
}
