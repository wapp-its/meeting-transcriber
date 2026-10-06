import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// End-to-end coverage for the auto-detect (`handleMeeting`) call site of the
/// record-only branch. The manual-recording call site is already covered by
/// `WatchLoopTests.test_recordOnly_*`, but those tests use empty `Data()` for
/// the recorder output. These tests run with a real fixture WAV so a regression
/// that breaks file move semantics or sidecar JSON shape surfaces against
/// realistic content. They also exercise the auto-detect entry point (vs the
/// existing manual-recording entry point) so a refactor that touches one
/// `enqueueRecording` caller without the other is caught.
@MainActor
final class RecordOnlyE2ETests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var recorder: MockRecorder!
    private var queue: PipelineQueue!
    private var notifier: RecordingNotifier!
    // swiftlint:enable implicitly_unwrapped_optional

    private static let basename = "20260503_120000"

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "recordonly_e2e")
        recorder = try makeRecorderWithFixtureWAVs(basename: Self.basename)
        queue = PipelineQueue(logDir: tmpDir)
        notifier = RecordingNotifier()
    }

    // MARK: - Tests

    func test_handleMeeting_recordOnly_writesSidecarAndSkipsPipeline() async throws {
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let loop = makeRecordOnlyLoop(outputDir: outputDir)

        try await loop.handleMeeting(makeMeeting())

        XCTAssertTrue(queue.jobs.isEmpty, "record-only must not enqueue a pipeline job")
        XCTAssertTrue(notifier.calls.isEmpty, "no failure notification on the happy path")

        let sidecarURL = outputDir.appendingPathComponent("\(Self.basename)_meta.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "sidecar JSON must land in the output directory",
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(RecordingSidecar.self, from: Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.version, RecordingSidecar.currentVersion)
        XCTAssertEqual(sidecar.files.mix, "\(Self.basename)_mix.wav")
        XCTAssertEqual(sidecar.files.app, "\(Self.basename)_app.wav")
        XCTAssertEqual(sidecar.files.mic, "\(Self.basename)_mic.wav")
        XCTAssertEqual(
            sidecar.trigger, .auto,
            "a detector-started meeting must be labelled auto, not manual",
        )
        XCTAssertLessThanOrEqual(sidecar.startedAt, sidecar.stoppedAt)

        // Round-trip the moved mix file through AVAudioFile to catch corruption
        // in the move step. Lower bound is loose but tight enough to detect
        // silent truncation — fixture is 17 s @ 16 kHz ≈ 272 k frames.
        let movedMix = outputDir.appendingPathComponent("\(Self.basename)_mix.wav")
        let avFile = try AVAudioFile(forReading: movedMix)
        XCTAssertEqual(Int(avFile.processingFormat.sampleRate), 16000)
        XCTAssertGreaterThan(avFile.length, 100_000)
    }

    func test_handleMeeting_recordOnly_writeFailure_notifiesAndDoesNotEnqueue() async throws {
        // `/dev/null/...` makes `createDirectory(at:)` throw, hitting the
        // error branch in `writeRecordOnlySidecar`.
        let unwritable = URL(fileURLWithPath: "/dev/null/cannot-write")
        let loop = makeRecordOnlyLoop(outputDir: unwritable)

        try await loop.handleMeeting(makeMeeting())

        XCTAssertTrue(queue.jobs.isEmpty, "still no enqueue when sidecar write fails")
        XCTAssertEqual(notifier.calls.count, 1, "user must be notified about lost record-only output")
        XCTAssertEqual(notifier.calls.first?.title, "Record-only output failed")
    }

    /// A meeting ended through the "seems to have ended" question is cut back
    /// in record-only mode too: every written track ends at the cut point, and
    /// the sidecar stops there rather than claiming audio the files lost.
    func test_handleMeeting_recordOnly_cutBackEndsFilesAndSidecarAtTheCutPoint() async throws {
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.recordingStartDate = start
        let clock = TestClock()
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: { self.recorder },
            pipelineQueue: queue,
            pollInterval: 0.5,
            endGracePeriod: 2,
            maxDuration: 100,
            // Long enough that the virtual clock outlasts the fixture (about
            // 50 s), as a real clock outlasts the audio it captured.
            meetingEndCountdown: 60,
            recordOnly: { true },
            recordOnlyDestination: { .unscoped(outputDir) },
            notifier: notifier,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        try await loop.handleMeeting(makeMeeting())

        // The signal is gone from the first poll, at the recording's start, so
        // the cut keeps the grace period: 2 s at 16 kHz.
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let file = try AVAudioFile(forReading: outputDir.appendingPathComponent("\(Self.basename)\(suffix)"))
            XCTAssertEqual(file.length, 32000, "\(suffix) must end at the cut point")
        }
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename))
        XCTAssertEqual(sidecar.stoppedAt, start.addingTimeInterval(2), "the sidecar stops at the cut")
    }

    /// The audio began before capture reported running: the fixture (about
    /// 50 s) outlasts the 32 virtual seconds from start to stop. The cut keeps
    /// the audio up to the cut point on the audio's own timeline, and the
    /// sidecar still stops at the requested cut point, 2 s after the start,
    /// not at the start plus the audio kept.
    func test_handleMeeting_recordOnly_earlyCaptureSidecarStopsAtTheRequestedCutPoint() async throws {
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.recordingStartDate = start
        let fixtureFrames = try AVAudioFile(forReading: fixtureURL()).length
        let clock = TestClock()
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: { self.recorder },
            pipelineQueue: queue,
            pollInterval: 0.5,
            endGracePeriod: 2,
            maxDuration: 100,
            meetingEndCountdown: 30,
            recordOnly: { true },
            recordOnlyDestination: { .unscoped(outputDir) },
            notifier: notifier,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        try await loop.handleMeeting(makeMeeting())

        // Stopped 30 s after the cut point, so the last 30 s of audio go.
        let mix = try AVAudioFile(forReading: outputDir.appendingPathComponent("\(Self.basename)\(RecordingFileSuffix.mix)"))
        XCTAssertEqual(Double(mix.length), Double(fixtureFrames - 30 * 16000), accuracy: 1)
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: Self.basename))
        XCTAssertEqual(sidecar.stoppedAt, start.addingTimeInterval(2), "the sidecar stops at the requested cut point")
    }

    // MARK: - Helpers

    /// Copy the canonical two-speaker fixture into tmpDir under three
    /// recorder-shaped names. We copy (not point at the shared fixture
    /// directly) because `WatchLoop.move()` does `moveItem` and would
    /// destroy the fixture for any subsequent test.
    private func makeRecorderWithFixtureWAVs(basename: String) throws -> MockRecorder {
        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture missing: \(fixture.path)",
        )

        let mix = tmpDir.appendingPathComponent("\(basename)_mix.wav")
        let app = tmpDir.appendingPathComponent("\(basename)_app.wav")
        let mic = tmpDir.appendingPathComponent("\(basename)_mic.wav")
        for dst in [mix, app, mic] {
            try FileManager.default.copyItem(at: fixture, to: dst)
        }

        let recorder = MockRecorder()
        recorder.mixPath = mix
        recorder.appPath = app
        recorder.micPath = mic
        return recorder
    }

    /// Ended by the duration cap so the fixture arrives whole: a lost signal
    /// cuts the recording back (the cut-back test above).
    private func makeRecordOnlyLoop(outputDir: URL) -> WatchLoop {
        let loop = WatchLoop(
            detector: FixedMeetingDetector(),
            recorderFactory: { self.recorder },
            pipelineQueue: queue,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 0.1,
            noMic: false,
            recordOnly: { true },
            recordOnlyDestination: { .unscoped(outputDir) },
            notifier: notifier,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return loop
    }

    private func makeMeeting(pid: pid_t = 9999) -> DetectedMeeting {
        DetectedMeeting(
            pattern: .teams,
            windowTitle: "Standup | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: pid,
        )
    }
}
