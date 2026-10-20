@testable import MeetingTranscriber
import XCTest

/// Meeting watching comes back after a manual recording that took it over,
/// whichever way that recording ends, and a call that ran through the
/// recording is held rather than recorded or asked about from its middle.
///
/// Every case starts watching and the recording through the controller's own
/// entry points. The call starts as the recording does, so the loop the
/// recording took over never saw it and the resumed loop finds it signalling.
@MainActor
final class WatchingControllerResumeWatchingTests: XCTestCase {
    /// Reads the harness's calls: a poll confirms the first call not
    /// excluded, and every call signals, as the real detectors list
    /// unconfirmed calls too.
    private final class CallsDetector: MeetingDetecting {
        private let calls: () -> [DetectedMeeting]
        private(set) var polls = 0
        /// Polls that handed a meeting to the loop.
        private(set) var confirmed = 0

        init(calls: @escaping () -> [DetectedMeeting]) {
            self.calls = calls
        }

        func checkOnce() -> DetectedMeeting? {
            checkOnce(excluding: [])
        }

        func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
            polls += 1
            let meeting = calls().first { !excludedApps.contains($0.pattern.identityKey) }
            if meeting != nil { confirmed += 1 }
            return meeting
        }

        func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
            calls().contains { $0.pattern.identityKey == meeting.pattern.identityKey }
        }

        func signallingMeetings() -> [DetectedMeeting] {
            calls()
        }

        func reset(appName _: String?) {}
    }

    /// The controller's seams, counted. One detector per watch loop built.
    private final class Harness {
        var calls: [DetectedMeeting] = []
        private(set) var detectors: [CallsDetector] = []
        var micAccessRequests = 0
        var screenRecordingRequests = 0
        var accessibilityRequests = 0
        var micAccessGranted = true
        /// Parks every microphone request from the moment it is set.
        var micGate: AsyncGate?
        let notifier = ConsentLoopDoubles.AnsweringNotifier(.granted)
        let diagnostics = RecordingDiagnostics()

        var permissionRequests: [Int] {
            [micAccessRequests, screenRecordingRequests, accessibilityRequests]
        }

        func makeDetector() -> any MeetingDetecting {
            let detector = CallsDetector { [weak self] in self?.calls ?? [] }
            detectors.append(detector)
            return detector
        }
    }

    /// How the manual recording ends.
    private enum Ending {
        case stopRecording, targetAppExits, durationCap, recorderThrowsAtStop, permissionRefusedAtStart, recorderFailsToStart
    }

    private let call = makeTestMeeting()

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerResumeWatchingTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    // MARK: - Every way a manual recording ends

    func testWatchingResumesAfterStopRecording() async throws {
        try await assertWatchingResumes(after: .stopRecording)
    }

    func testWatchingResumesAfterTheRecordedAppExits() async throws {
        try await assertWatchingResumes(after: .targetAppExits)
    }

    func testWatchingResumesAfterTheDurationCap() async throws {
        try await assertWatchingResumes(after: .durationCap)
    }

    func testWatchingResumesAfterTheRecorderThrowsAtStop() async throws {
        try await assertWatchingResumes(after: .recorderThrowsAtStop)
    }

    func testWatchingResumesAfterAPermissionRefusalAtStart() async throws {
        try await assertWatchingResumes(after: .permissionRefusedAtStart)
    }

    func testWatchingResumesAfterTheRecorderFailsToStart() async throws {
        try await assertWatchingResumes(after: .recorderFailsToStart)
    }

    /// Record-only output is written as without the resume, and the resume is
    /// the same.
    func testWatchingResumesInRecordOnlyMode() async throws {
        let harness = Harness()
        let recorder = makeMockRecorder()
        let mix = tmpDir.appendingPathComponent("20261020_090000_mix.wav")
        try Data().write(to: mix)
        recorder.mixPath = mix
        let controller = makeController(harness) { recorder }
        controller.settings.recordOnly = true
        await startWatchingThenRecord(controller, harness)

        controller.stopRecording()
        let resumed = await controller.joinResume()

        XCTAssertTrue(resumed)
        let written = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("output/recordings").path)
        XCTAssertTrue(written.contains("20261020_090000_mix.wav"), "the recording is kept: \(written)")
        try await assertResumedHoldingTheCall(controller, harness, "record-only")
    }

    // MARK: - No prompt

    /// The resume calls none of the permission requests a watch start makes,
    /// also when they report access missing: the request could raise a system
    /// dialog for a permission revoked during the session.
    func testTheResumeRequestsNoPermissionEvenWhenOneIsMissing() async {
        for missing in [false, true] {
            let harness = Harness()
            harness.micAccessGranted = !missing
            let health = missing ? HealthCheckResult(screenRecording: .denied, microphone: .healthy) : .allHealthy
            let controller = makeController(harness, logDir: tmpDir.appendingPathComponent("\(missing)"), permissionHealth: health)
            // A Start Watching press, which asks for all three.
            controller.toggleWatching()
            _ = await controller.joinStart()
            controller.startMicrophoneRecording()
            _ = await controller.joinManualStart()
            XCTAssertEqual(harness.permissionRequests, [2, 1, 1], "missing \(missing): precondition: the press and the start asked")

            controller.stopRecording()
            _ = await controller.joinResume()

            XCTAssertTrue(controller.isWatching, "missing \(missing): resumed")
            XCTAssertEqual(harness.permissionRequests, [2, 1, 1], "missing \(missing): the resume asked for nothing")
            await Self.shutDown(controller)
        }
    }

    // MARK: - Watching that was off, or is changed meanwhile

    func testWatchingOffBeforeTheRecordingStaysOff() async {
        let harness = Harness()
        let controller = makeController(harness)
        controller.startMicrophoneRecording()
        _ = await controller.joinManualStart()
        XCTAssertTrue(controller.isRecordingMicrophoneOnly, "precondition")

        controller.stopRecording()
        _ = await controller.joinResume()

        XCTAssertFalse(controller.isWatching)
        XCTAssertTrue(harness.detectors.isEmpty, "no watch loop was started")
    }

    /// Start Watching pressed between the end and the resume: the resume finds
    /// watching on and adds nothing.
    func testStartWatchingPressedBeforeTheResumeLeavesOneLoop() async {
        let harness = Harness()
        let controller = makeController(harness)
        await startWatchingThenRecord(controller, harness)

        controller.stopRecording()
        controller.toggleWatching()
        _ = await controller.joinResume()

        XCTAssertTrue(controller.isWatching)
        XCTAssertEqual(harness.detectors.count, 2, "the press built one loop and the resume none")
        XCTAssertFalse(controller.resumeWatchingPending)
    }

    /// A second recording started before the resume ran (watching was off for
    /// it): watching stays off until that one ends, then resumes once.
    func testASecondRecordingStartedBeforeTheResumeDefersIt() async throws {
        let harness = Harness()
        let controller = makeController(harness)
        await startWatchingThenRecord(controller, harness)

        controller.stopRecording()
        controller.startMicrophoneRecording()
        _ = await controller.joinManualStart()
        _ = await controller.joinResume()

        XCTAssertTrue(controller.isRecordingMicrophoneOnly, "precondition: the second recording runs")
        XCTAssertFalse(controller.isWatching, "watching stays off during it")
        XCTAssertEqual(harness.detectors.count, 1, "no watch loop was started")
        XCTAssertTrue(controller.resumeWatchingPending, "the resume waits for the second recording")

        controller.stopRecording()
        _ = await controller.joinResume()

        try await assertResumedHoldingTheCall(controller, harness, "after the second recording")
    }

    /// The resume began, and its watch start was launched, when a second
    /// manual start registered. That start runs first and makes the watch
    /// start bail, so the intent must still be pending afterwards: one
    /// consumed when the resume began would be lost, and watching would stay
    /// off after the second recording.
    func testAManualStartRegisteringAfterTheResumeBeganKeepsTheIntent() async throws {
        let harness = Harness()
        let controller = makeController(harness)
        await startWatchingThenRecord(controller, harness)

        controller.stopRecording()
        // Queued behind the resume, so it runs while the resume's watch start
        // waits for its own turn.
        Task { @MainActor in controller.startMicrophoneRecording() }
        _ = await controller.joinResume()

        XCTAssertTrue(controller.isRecordingMicrophoneOnly, "precondition: the second recording runs")
        XCTAssertFalse(controller.isWatching)
        XCTAssertEqual(harness.detectors.count, 1, "the bailed start built no loop")
        XCTAssertTrue(controller.resumeWatchingPending, "the intent is still pending")

        controller.stopRecording()
        _ = await controller.joinResume()

        try await assertResumedHoldingTheCall(controller, harness, "after the second recording")
    }

    // MARK: - Quitting, and a resume that cannot start

    /// The app's quit path stops the loop with `stop()`, which signals no end.
    func testQuittingDuringARecordingStartsNoWatching() async throws {
        let harness = Harness()
        let controller = makeController(harness)
        await startWatchingThenRecord(controller, harness)

        controller.watchLoop?.stop()
        _ = await controller.joinResume()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(controller.resumeTask, "no resume was launched")
        XCTAssertFalse(controller.isWatching)
        XCTAssertEqual(harness.detectors.count, 1, "no watch loop was started")
        XCTAssertTrue(controller.resumeWatchingPending, "the intent was not consumed into a start")
    }

    /// Start Watching pressed as the recording ends, its microphone prompt
    /// left unanswered: the resume cannot settle that start within the bound,
    /// so watching stays off and the diagnostics line says so.
    func testAResumeThatCannotStartWatchingLeavesItOffAndLogsIt() async {
        let harness = Harness()
        let gate = AsyncGate()
        let controller = makeController(harness, startJoinTimeout: .milliseconds(300))
        addTeardownBlock { await gate.open() }
        await startWatchingThenRecord(controller, harness)

        controller.stopRecording()
        harness.micGate = gate
        controller.toggleWatching()
        await waitFor { await gate.hasWaiter }
        await waitFor(controller.resumeTask == nil, timeout: .seconds(3))

        XCTAssertNil(controller.resumeTask, "precondition: the resume finished")
        XCTAssertFalse(controller.isWatching, "watching stays off")
        XCTAssertEqual(
            harness.diagnostics.lines(.notice, startingWith: "watch_resume_failed"),
            ["watch_resume_failed reason=start_did_not_settle"],
        )
        XCTAssertFalse(controller.resumeWatchingPending, "the intent is dropped with the failure")
    }

    /// The same unanswered press, and a second recording started before it
    /// settles: the resume gives up on the press, but the intent stays with
    /// that recording, whose end brings watching back. Dropped there, nothing
    /// would, since the press yields to the recording.
    func testASecondRecordingStartedWhileTheResumeWaitsOnAPressKeepsTheIntent() async throws {
        let harness = Harness()
        let gate = AsyncGate()
        let controller = makeController(harness, startJoinTimeout: .milliseconds(300))
        addTeardownBlock { await gate.open() }
        await startWatchingThenRecord(controller, harness)

        controller.stopRecording()
        harness.micGate = gate
        controller.toggleWatching()
        await waitFor { await gate.hasWaiter }
        controller.startMicrophoneRecording()
        await waitFor(controller.resumeTask == nil, timeout: .seconds(3))

        XCTAssertNil(controller.resumeTask, "precondition: the resume gave up on the press")
        XCTAssertTrue(controller.isManualRecording, "precondition: the second start is registered")
        XCTAssertTrue(controller.resumeWatchingPending, "the intent stays with the second recording")
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "watch_resume_failed"), [], "nothing failed")

        await gate.open()
        await waitFor(controller.isRecordingMicrophoneOnly, timeout: .seconds(3))
        _ = await controller.joinStarts()

        XCTAssertTrue(controller.isRecordingMicrophoneOnly, "precondition: the second recording runs")
        XCTAssertFalse(controller.isWatching, "the press yielded to the recording")
        XCTAssertEqual(harness.detectors.count, 1, "the bailed press built no loop")
        XCTAssertTrue(controller.resumeWatchingPending, "the intent is still pending")

        controller.stopRecording()
        _ = await controller.joinResume()

        try await assertResumedHoldingTheCall(controller, harness, "after the second recording")
    }

    // MARK: - Helpers

    private func makeController(
        _ harness: Harness,
        logDir: URL? = nil,
        permissionHealth: HealthCheckResult = .allHealthy,
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
        makeRecorder: @escaping @MainActor () -> any RecordingProvider = { makeMockRecorder() },
    ) -> WatchingController {
        let controller = makeWatchingController(
            logDir: logDir ?? tmpDir,
            notifier: harness.notifier,
            ensureMicAccess: {
                harness.micAccessRequests += 1
                if let gate = harness.micGate { await gate.wait() }
                return harness.micAccessGranted
            },
            requestScreenRecording: { harness.screenRecordingRequests += 1 },
            requestAccessibility: { harness.accessibilityRequests += 1 },
            permissionHealth: permissionHealth,
            startJoinTimeout: startJoinTimeout,
            makeDetector: { harness.makeDetector() },
            makeRecorder: makeRecorder,
        )
        controller.diagnostics = harness.diagnostics
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

    /// Watching on, then a manual recording through the controller's entry
    /// point. The call starts as the recording does: before the start's task
    /// runs and takes the watch loop over, and with nothing yielding to that
    /// loop's poll in between.
    private func startWatchingThenRecord(_ controller: WatchingController, _ harness: Harness, pid: pid_t? = nil) async {
        let watching = await controller.startWatching()
        XCTAssertEqual(watching, .changed, "precondition: watching is on")
        if let pid {
            controller.startManualRecording(pid: pid, appName: "Chrome", title: "Standup")
        } else {
            controller.startMicrophoneRecording()
        }
        harness.calls = [call]
        _ = await controller.joinManualStart()
    }

    private func assertWatchingResumes(after ending: Ending) async throws {
        let harness = Harness()
        let micDenied = HealthCheckResult(screenRecording: .healthy, microphone: .denied)
        var clockOffset: TimeInterval = 0
        let controller = makeController(harness, permissionHealth: ending == .permissionRefusedAtStart ? micDenied : .allHealthy) {
            switch ending {
            case .recorderThrowsAtStop: MockRecorder() // no mix: its stop throws
            case .recorderFailsToStart: ThrowingRecorder()
            default: makeMockRecorder()
            }
        }
        controller.manualRecordingClock = { Date().addingTimeInterval(clockOffset) }
        controller.settings.pollInterval = 1

        switch ending {
        case .stopRecording:
            await startWatchingThenRecord(controller, harness, pid: getpid())
            controller.stopRecording()

        case .targetAppExits:
            // Above the system's pid range, so the monitor finds the app gone
            // at its first check and stops the recording itself.
            await startWatchingThenRecord(controller, harness, pid: .max)

        case .durationCap:
            await startWatchingThenRecord(controller, harness)
            XCTAssertTrue(controller.isRecordingMicrophoneOnly, "precondition: recording")
            clockOffset = 4 * 3600 + 60

        case .recorderThrowsAtStop:
            await startWatchingThenRecord(controller, harness)
            XCTAssertTrue(controller.isRecordingMicrophoneOnly, "precondition: recording")
            controller.stopRecording()
            XCTAssertTrue(controller.pipeline.queue.jobs.isEmpty, "precondition: the stop threw, so nothing was enqueued")

        case .permissionRefusedAtStart, .recorderFailsToStart:
            await startWatchingThenRecord(controller, harness)
            XCTAssertFalse(controller.isRecordingMicrophoneOnly, "precondition: the start recorded nothing")
        }
        await waitFor(!controller.isManualRecording, timeout: .seconds(5))
        let resumed = await controller.joinResume()

        XCTAssertTrue(resumed, "\(ending): the resume finished")
        try await assertResumedHoldingTheCall(controller, harness, "\(ending)")
    }

    /// Watching is on through exactly one loop built for the resume, and the
    /// call signalling at the resume is neither recorded nor asked about.
    private func assertResumedHoldingTheCall(_ controller: WatchingController, _ harness: Harness, _ label: String) async throws {
        XCTAssertTrue(controller.isWatching, "\(label): watching is on again")
        XCTAssertEqual(harness.detectors.count, 2, "\(label): the resume built one watch loop")
        XCTAssertFalse(controller.resumeWatchingPending, "\(label): the intent is consumed")
        let loop = try XCTUnwrap(controller.watchLoop)
        let detector = try XCTUnwrap(harness.detectors.last)
        XCTAssertEqual(loop.appsHeldFromDetection, [call.pattern.identityKey], "\(label): the signalling call is held")
        await waitFor(detector.polls >= 1, timeout: .seconds(2))
        XCTAssertGreaterThanOrEqual(detector.polls, 1, "\(label): precondition: the resumed loop polled")
        XCTAssertEqual(detector.confirmed, 0, "\(label): the held call never reached detection")
        XCTAssertEqual(loop.state, .watching, "\(label): not recorded")
        XCTAssertTrue(harness.notifier.prompts.isEmpty, "\(label): nor asked about")
    }
}
