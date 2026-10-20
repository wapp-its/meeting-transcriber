@testable import MeetingTranscriber
import XCTest

/// The automation API's side of resuming meeting watching after a manual
/// recording: a `/v1/watch` stop sent during the recording cancels the resume,
/// a start does not, and a `/v1/record` stop or failed start answers only once
/// the resume has run, so a `GET /v1/watch` right after it agrees.
///
/// Every case starts watching and the recording through the controller's own
/// entry points, as `WatchingControllerResumeWatchingTests` does, and shuts
/// down the same way.
@MainActor
final class WatchingControllerResumeCancelTests: XCTestCase {
    private let diagnostics = RecordingDiagnostics()

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerResumeCancelTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    // MARK: - /v1/watch during a manual recording

    /// The stop answers as before and cancels the resume: watching stays off
    /// after the recording, and one line says so. The repeat has nothing left
    /// to cancel and writes nothing.
    func testAWatchStopDuringAManualRecordingCancelsTheResume() async {
        let controller = makeController()
        await startWatchingThenRecordMicrophone(controller)

        let stopped = await controller.stopWatching()
        let repeated = await controller.applyWatchAction(.stop)
        controller.stopRecording()
        _ = await controller.joinResume()

        XCTAssertEqual(stopped, .unchanged, "the answer is unchanged")
        XCTAssertEqual(repeated, .unchanged)
        XCTAssertFalse(controller.isManualRecording, "precondition: the recording ended")
        XCTAssertFalse(controller.isWatching, "watching stays off after the recording")
        XCTAssertNil(controller.watchLoop, "no watch loop was started")
        XCTAssertEqual(diagnostics.lines(.notice, startingWith: "watch_resume_cancelled"), ["watch_resume_cancelled"])
    }

    /// `start`, and a `toggle` that resolves to one, keep answering 409 and
    /// leave the resume alone: only a stop cancels it.
    func testAWatchStartDuringAManualRecordingIsBlockedAndKeepsTheResume() async {
        for action in [WatchAction.start, .toggle] {
            let controller = makeController()
            await startWatchingThenRecordMicrophone(controller)

            let outcome = await controller.applyWatchAction(action)
            controller.stopRecording()
            _ = await controller.joinResume()

            XCTAssertEqual(outcome, .blocked, "\(action)")
            XCTAssertTrue(controller.isWatching, "\(action): watching resumed after the recording")
            XCTAssertEqual(diagnostics.lines(.notice, startingWith: "watch_resume_cancelled"), [], "\(action)")
            await Self.shutDown(controller)
        }
    }

    // MARK: - /v1/record answers after the resume

    func testARecordStopOfAMicrophoneRecordingAnswersWithWatchingBack() async {
        let controller = makeController()
        await controller.startWatching()
        let started = await controller.applyRecordAction(.start)
        XCTAssertEqual(started, .changed, "precondition")

        let outcome = await controller.applyRecordAction(.stop)

        XCTAssertEqual(outcome, .changed)
        XCTAssertTrue(controller.isWatching, "watching is back when the answer arrives")
    }

    func testAnAnyScopeStopOfAnAppRecordingAnswersWithWatchingBack() async {
        let controller = makeController()
        await controller.startWatching()
        controller.startManualRecording(pid: getpid(), appName: "Chrome", title: "Standup")
        _ = await controller.joinManualStart()
        XCTAssertTrue(controller.isRecordingOtherThanMicrophone, "precondition: an app recording runs")

        let outcome = await controller.applyRecordStopAny()

        XCTAssertEqual(outcome, .changed)
        XCTAssertTrue(controller.isWatching, "watching is back when the answer arrives")
    }

    /// The recorder refuses to start: 503 as before, and watching is back
    /// through the same resume every other manual ending uses. The refused
    /// (412) arm is `WatchingControllerRecordControlTests`'
    /// `testARefusedStartPutsMeetingWatchingBack`.
    func testAFailedRecordStartAnswersWithWatchingBack() async {
        // swiftlint:disable:next trailing_closure
        let controller = makeController(makeRecorder: { ThrowingRecorder() })
        let watching = await controller.startWatching()
        XCTAssertEqual(watching, .changed, "precondition")

        let outcome = await controller.applyRecordAction(.start)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(controller.isWatching, "watching is back when the answer arrives")
    }

    // MARK: - Helpers

    private func makeController(
        makeRecorder: @escaping @MainActor () -> any RecordingProvider = { makeMockRecorder() },
    ) -> WatchingController {
        let controller = makeWatchingController(logDir: tmpDir, permissionHealth: .allHealthy, makeRecorder: makeRecorder)
        controller.diagnostics = diagnostics
        addTeardownBlock { await Self.shutDown(controller) }
        return controller
    }

    /// Nothing resumes, records or watches past the test.
    private static func shutDown(_ controller: WatchingController) async {
        controller.resumeWatchingPending = false
        _ = await controller.joinResume()
        _ = await controller.joinStarts()
        if controller.watchLoop?.isManualRecording == true { controller.stopManualRecording() }
        controller.watchLoop?.stop()
    }

    /// Watching on, then a microphone recording that takes it over.
    private func startWatchingThenRecordMicrophone(_ controller: WatchingController) async {
        let watching = await controller.startWatching()
        XCTAssertEqual(watching, .changed, "precondition: watching is on")
        controller.startMicrophoneRecording()
        _ = await controller.joinManualStart()
        XCTAssertTrue(controller.isRecordingMicrophoneOnly, "precondition: the recording runs")
    }
}
