@testable import MeetingTranscriber
import XCTest

/// The Settings side of "record without asking": the switch a user sets in
/// `AppSettings` must reach the watch loop the controller builds, and a start
/// without asking must stay visible. `WatchLoopAskBeforeRecordingTests` covers
/// the gate itself.
@MainActor
final class WatchingControllerAskBeforeRecordingTests: XCTestCase {
    private let teams = DetectedMeeting(
        pattern: .teams, windowTitle: "Weekly | Microsoft Teams", ownerName: "MSTeams", windowPID: 4242,
    )

    /// `RecordingNotifier` declines every prompt, so the only way to record is
    /// for the loop never to ask.
    private func startWatchingTeams(recordWithoutAsking: [String]) async throws -> (WatchingController, RecordingNotifier) {
        let notifier = RecordingNotifier()
        let meeting = teams
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "WatchingControllerAskBeforeRecordingTests"),
            notifier: notifier,
            permissionHealth: .allHealthy,
            makeDetector: { FixedMeetingDetector(meeting) },
            makeRecorder: { makeMockRecorder() },
        )
        controller.settings.recordWithoutAskingApps = recordWithoutAsking
        let started = await controller.startWatching()
        XCTAssertEqual(started, .changed, "precondition")
        return (controller, notifier)
    }

    func testTeamsSwitchedToRecordWithoutAskingRecordsAndSaysSo() async throws {
        let (controller, notifier) = try await startWatchingTeams(recordWithoutAsking: ["Microsoft Teams"])
        await waitFor(controller.isRecording, timeout: .seconds(2))
        XCTAssertTrue(controller.isRecording, "the setting must reach the loop")
        XCTAssertTrue(
            notifier.calls.contains { $0.title == "Meeting Detected" },
            "a recording started without asking must still be announced",
        )
        _ = await controller.stopWatching()
    }

    func testTeamsAsksFirstByDefault() async throws {
        let (controller, _) = try await startWatchingTeams(recordWithoutAsking: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(controller.isRecording, "a declined prompt must not record")
        _ = await controller.stopWatching()
    }
}
