@testable import MeetingTranscriber
import XCTest

/// A detected Teams recording's title while it runs: each poll of the
/// meeting-end wait whose signal is present reads the Teams windows again, a
/// better-ranked window replaces the held title and an equal or weaker one
/// never does, and the title held at the stop is the one the job gets. Driven
/// on `TestClock`, polling once a virtual second, so every timing is exact.
/// Every window title below is made up.
@MainActor
final class WatchLoopMeetingTitleTests: XCTestCase {
    private static let meetingWindow = "Sprint Review | Contoso | user@contoso.com | Microsoft Teams"
    private static let basename = "20261116_100000"

    private func teams(_ title: String) -> DetectedMeeting {
        DetectedMeeting(pattern: .teams, windowTitle: title, ownerName: "MSTeams", windowPID: 4242)
    }

    // MARK: - A better window during the recording

    /// Detected with a rank-4 window, the recording takes the meeting window a
    /// later poll offers, keeps it when a rank-3 window comes after, shows it
    /// in the status line while it runs, and hands it to the job and to the
    /// meeting Record Again would replay after the stop by hand. The move
    /// into recording is the only phase change, so the "Meeting Detected"
    /// notice is not posted again; the log names ranks and part counts only.
    func testABetterWindowReplacesTheTitleAndAWeakerOneNeverDoes() async throws {
        let harness = Harness()
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "meeting-title-queue"))
        let loop = harness.makeLoop(queue: queue)
        var phaseChanges: [WatchLoop.State] = []
        loop.onStateChange = { _, new, _ in phaseChanges.append(new) }
        var detailWhileRecording: String?
        var meetingWhileRecording: DetectedMeeting?
        harness.onTick = { h, t in
            if t == 2 { h.detector.offer(Self.meetingWindow) }
            if t == 3 {
                detailWhileRecording = h.loop?.detail
                meetingWhileRecording = h.loop?.currentMeeting
            }
            if t == 4 { h.detector.offer("Jane Doe | Microsoft Teams") }
            if t == 6 { h.loop?.stopDetectedRecording() }
        }

        let meeting = teams("Some Popup")

        try await loop.handleMeeting(meeting)

        XCTAssertEqual(detailWhileRecording, "Recording: Sprint Review | Contoso | user@contoso.com")
        XCTAssertEqual(meetingWhileRecording, meeting.retitled(Self.meetingWindow), "a copy that differs only in the title")
        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Sprint Review | Contoso | user@contoso.com"])
        XCTAssertEqual(
            loop.redetectionHolds.offeredMeetings,
            [meeting.retitled(Self.meetingWindow)],
            "Record Again starts from the held title",
        )
        XCTAssertEqual(phaseChanges, [.recording])
        XCTAssertEqual(
            harness.titleLines,
            ["meeting_title_rank at=detection rank=4 parts=1", "meeting_title_rank at=change rank=1 parts=3 was=4"],
        )
        XCTAssertFalse(harness.diagnostics.lines.contains { $0.line.contains("Sprint") || $0.line.contains("Popup") })
    }

    /// Detected with the placeholder, the first usable window names it.
    func testARecordingDetectedWithThePlaceholderTakesTheFirstUsableTitle() async throws {
        let harness = Harness()
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "meeting-title-queue"))
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            if t == 1 { h.detector.offer("Some Popup") }
            if t == 3 { h.loop?.stopDetectedRecording() }
        }

        try await loop.handleMeeting(teams("Microsoft Teams Call"))

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Some Popup"])
        XCTAssertEqual(
            harness.titleLines,
            ["meeting_title_rank at=detection rank=none parts=0", "meeting_title_rank at=change rank=4 parts=1 was=none"],
        )
    }

    /// A record-only recording's sidecar gets the title held at the stop too.
    func testARecordOnlySidecarGetsTheHeldTitle() async throws {
        let harness = Harness()
        let dir = try makeTempDirectory(prefix: "meeting-title-record-only")
        harness.recorder.mixPath = dir.appendingPathComponent("\(Self.basename)\(RecordingFileSuffix.mix)")
        try Data().write(to: XCTUnwrap(harness.recorder.mixPath))
        let outputDir = dir.appendingPathComponent("output", isDirectory: true)
        let loop = harness.makeLoop(queue: nil, recordOnlyTo: outputDir)
        harness.onTick = { h, t in
            if t == 1 { h.detector.offer("Meeting compact view | Meeting in General | Microsoft Teams") }
            if t == 3 { h.loop?.stopDetectedRecording() }
        }

        try await loop.handleMeeting(teams("Some Popup"))

        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename))
        XCTAssertEqual(sidecar.title, "Meeting in General")
    }

    // MARK: - Polls that never refresh

    /// Call A holds a rank-4 title; the poll that brings call B's disjoint
    /// call IDs, with a meeting window up, ends A's recording without reading
    /// the windows, so A's job keeps A's title.
    func testThePollThatEndsTheRecordingForANewCallDoesNotRenameIt() async throws {
        let harness = Harness()
        harness.detector.calls = .ids(["call-a"])
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "meeting-title-queue"))
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            if t == 3 {
                h.detector.calls = .ids(["call-b"])
                h.detector.offer(Self.meetingWindow)
            }
        }

        let reason = try await loop.handleMeeting(teams("Some Popup"))

        XCTAssertEqual(reason, .replacedByNewCall, "precondition: ended for the new call")
        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Some Popup"])
        XCTAssertEqual(harness.detector.titleReads, 3, "the polls at 0, 1 and 2 s only")
    }

    /// Once the signal is gone, a window that appears changes nothing.
    func testPollsAfterTheSignalIsLostKeepTheTitle() async throws {
        let harness = Harness()
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "meeting-title-queue"))
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            if t == 2 {
                h.detector.active = false
                h.detector.offer(Self.meetingWindow)
            }
            if t == 5 { h.loop?.stopDetectedRecording() }
        }

        try await loop.handleMeeting(teams("Some Popup"))

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Some Popup"])
        XCTAssertEqual(harness.detector.titleReads, 2, "the polls at 0 and 1 s only")
    }

    /// A Zoom recording gets no refresh, whatever the detector offers.
    func testOtherAppsGetNoRefresh() async throws {
        let harness = Harness()
        harness.detector.offer(Self.meetingWindow)
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "meeting-title-queue"))
        let loop = harness.makeLoop(queue: queue)
        harness.onTick = { h, t in
            if t == 2 { h.loop?.stopDetectedRecording() }
        }

        try await loop.handleMeeting(DetectedMeeting(pattern: .zoom, windowTitle: "Zoom Meeting", ownerName: "zoom.us", windowPID: 2020))

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Zoom Meeting"])
        XCTAssertEqual(harness.titleLines, [])
    }

    // MARK: - A refresh during a pause

    /// The title improves while the recording is paused: the status line keeps
    /// its "Paused: " prefix with the new title, and capture stays paused.
    func testARefreshDuringAPauseKeepsThePause() async throws {
        let harness = Harness()
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "meeting-title-queue"))
        let loop = harness.makeLoop(queue: queue)
        var detailAfterRefresh: String?
        var pausedAfterRefresh: (loop: Bool, recorder: Bool)?
        harness.onTick = { h, t in
            if t == 1 { _ = h.loop?.pauseRecording() }
            if t == 2 { h.detector.offer(Self.meetingWindow) }
            if t == 3 {
                detailAfterRefresh = h.loop?.detail
                pausedAfterRefresh = (h.loop?.isPaused ?? false, h.recorder.isPaused)
            }
            if t == 4 { h.loop?.stopDetectedRecording() }
        }

        try await loop.handleMeeting(teams("Some Popup"))

        XCTAssertEqual(detailAfterRefresh, "Paused: Sprint Review | Contoso | user@contoso.com")
        XCTAssertEqual(pausedAfterRefresh?.loop, true)
        XCTAssertEqual(pausedAfterRefresh?.recorder, true)
        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Sprint Review | Contoso | user@contoso.com"])
    }
}

/// Everything a loop under test talks to. `onTick` runs after every virtual
/// second, before that second's poll, with the seconds since the clock
/// started; it is handed the harness rather than capturing it, so no test
/// builds a reference cycle.
@MainActor
private final class Harness {
    /// The meeting's signal, its calls and the Teams window it offers, all set by the test.
    final class Detector: MeetingDetecting {
        var active = true
        var calls: ActiveCalls = .unidentified
        private(set) var offered: RankedWindowTitle?
        private(set) var titleReads = 0

        func offer(_ title: String) {
            offered = TeamsWindowTitle.rank(of: title).map { RankedWindowTitle(title: title, rank: $0) }
        }

        func checkOnce() -> DetectedMeeting? {
            nil
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            active
        }

        func activeCalls(_: DetectedMeeting) -> ActiveCalls {
            calls
        }

        func reset(appName _: String?) {}

        func rankedWindowTitle(for _: DetectedMeeting) -> RankedWindowTitle? {
            titleReads += 1
            return offered
        }
    }

    static let start = Date(timeIntervalSince1970: 1_000_000)
    let clock = TestClock(start: start)
    let detector = Detector()
    let diagnostics = RecordingDiagnostics()
    let recorder = makeMockRecorder()
    var onTick: @MainActor (Harness, TimeInterval) -> Void = { _, _ in }
    private(set) weak var loop: WatchLoop?

    init() {
        recorder.recordingStartDate = Self.start
    }

    var titleLines: [String] {
        diagnostics.lines(.notice, startingWith: "meeting_title_rank")
    }

    func makeLoop(queue: PipelineQueue?, recordOnlyTo outputDir: URL? = nil) -> WatchLoop {
        let sleepProvider: (TimeInterval) async -> Void = { interval in
            await self.clock.sleep(for: interval)
            self.onTick(self, self.clock.now.timeIntervalSince(Self.start))
        }
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { self.recorder },
            pipelineQueue: queue,
            pollInterval: 1,
            endGracePeriod: 10,
            maxDuration: 1_000_000,
            recordOnly: { outputDir != nil },
            recordOnlyDestination: { .unscoped(outputDir ?? FileManager.default.temporaryDirectory) },
            notifier: RecordingNotifier(),
            diagnostics: diagnostics,
            nowProvider: { self.clock.now },
            sleepProvider: sleepProvider,
        )
        loop.permissionChecker = { .allHealthy }
        self.loop = loop
        return loop
    }
}
