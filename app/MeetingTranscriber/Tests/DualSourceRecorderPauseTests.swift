import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Pausing at the recorder: what reaches the capture session, what comes back
/// on the recording, and how a paused recording, which writes nothing, keeps
/// the staging recovery from taking it for a crashed one.
@MainActor
final class DualSourceRecorderPauseTests: XCTestCase {
    private typealias FakeCaptureSession = DualSourceRecorderLifecycleTests.FakeCaptureSession

    /// Short enough that a test sees a touch within a fraction of a second.
    private let touchInterval = Duration.milliseconds(20)

    private func makeRecorder(dir: URL) -> (DualSourceRecorder, FakeCaptureSession) {
        let session = FakeCaptureSession()
        let recorder = DualSourceRecorder(
            recordingsDir: dir,
            makeCaptureSession: { configuration in
                session.lastConfiguration = configuration
                return session
            },
            pausedTrackTouchInterval: touchInterval,
        )
        return (recorder, session)
    }

    /// Start a recording of both tracks and write a second of audio to each,
    /// as the capture would have by the time of a pause.
    private func startWithTracks(
        _ recorder: DualSourceRecorder,
        _ session: FakeCaptureSession,
    ) throws -> (app: URL, mic: URL) {
        // A PID no process holds: the tap-PID resolution falls back to the root alone.
        try recorder.start(source: .appAndMic(pid: 999_999))
        let configuration = try XCTUnwrap(session.lastConfiguration)
        let app = try XCTUnwrap(configuration.appOutputURL)
        let mic = try XCTUnwrap(configuration.micOutputURL)
        try writeRawFloat32([Float](repeating: 0.1, count: 16000), to: app)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: mic)
        session.appTrack = app
        session.micTrack = mic
        return (app, mic)
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func backdate(_ urls: [URL], to date: Date) throws {
        for url in urls {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private func isTouched(_ url: URL, since stale: Date) -> Bool {
        modified(url).map { $0 > stale } ?? false
    }

    // MARK: - Forwarding

    func testPauseAndResumeReachTheSessionOnceEach() throws {
        let dir = try makeTempDirectory(prefix: "pause_forward")
        let (recorder, session) = makeRecorder(dir: dir)
        try recorder.start(source: .micOnly)

        recorder.pause()
        recorder.pause()
        XCTAssertTrue(recorder.isPaused)
        XCTAssertEqual(session.pauseCallCount, 1, "a pause while paused is not a second pause")
        XCTAssertEqual(session.resumeCallCount, 0)

        recorder.resume()
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
        XCTAssertEqual(session.pauseCallCount, 1)
        XCTAssertEqual(session.resumeCallCount, 1, "a resume while running is not a second resume")
    }

    /// Before the start and after the stop there is no recording to pause,
    /// and the stop ends a pause still open.
    func testNothingReachesTheSessionOutsideARecording() throws {
        let dir = try makeTempDirectory(prefix: "pause_outside")
        let (recorder, session) = makeRecorder(dir: dir)

        recorder.pause()
        recorder.resume()
        XCTAssertFalse(recorder.isPaused, "nothing to pause before the start")

        _ = try startWithTracks(recorder, session)
        recorder.pause()
        _ = try recorder.stop()
        XCTAssertFalse(recorder.isPaused, "the stop ends the pause")

        recorder.pause()
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
        XCTAssertEqual(session.pauseCallCount, 1, "only the pause during the recording reached the session")
        XCTAssertEqual(session.resumeCallCount, 0)
    }

    func testTheSessionsPausePositionsArriveOnTheRecording() throws {
        let dir = try makeTempDirectory(prefix: "pause_offsets")
        let (recorder, session) = makeRecorder(dir: dir)
        _ = try startWithTracks(recorder, session)
        session.pauseOffsets = [0.25, 0.75]

        let recording = try recorder.stop()

        XCTAssertEqual(recording.pauseOffsets, [0.25, 0.75])
    }

    // MARK: - Looking alive while paused

    /// The tracks' modification dates advance while paused, and only then.
    /// Each check backdates the files first, so a date that moves can only
    /// have been moved by the recorder.
    func testAPausedRecordingKeepsItsTracksFresh() async throws {
        let dir = try makeTempDirectory(prefix: "pause_touch")
        let (recorder, session) = makeRecorder(dir: dir)
        let (app, mic) = try startWithTracks(recorder, session)
        let stale = Date().addingTimeInterval(-60)

        try backdate([app, mic], to: stale)
        recorder.pause()
        await waitFor(isTouched(app, since: stale) && isTouched(mic, since: stale), timeout: .seconds(5))
        XCTAssertTrue(isTouched(app, since: stale), "the raw app temp is refreshed while paused")
        XCTAssertTrue(isTouched(mic, since: stale), "the microphone WAV is refreshed while paused")

        recorder.resume()
        try backdate([app, mic], to: stale)
        try await Task.sleep(for: touchInterval * 10)
        XCTAssertFalse(isTouched(app, since: stale), "a resumed recording writes its tracks itself")
        XCTAssertFalse(isTouched(mic, since: stale))

        recorder.pause()
        await waitFor(isTouched(mic, since: stale), timeout: .seconds(5))
        _ = try recorder.stop()
        // The mix consumed the raw app temp; the microphone WAV stays.
        try backdate([mic], to: stale)
        try await Task.sleep(for: touchInterval * 10)
        XCTAssertFalse(isTouched(mic, since: stale), "a stopped recording is no longer kept alive")
    }

    /// A recording paused for longer than the 30 s the staging recovery
    /// allows a writer is neither re-mixed nor has its raw app temp deleted.
    /// A crashed recording and an orphaned temp of the same age beside it
    /// show the two passes did run and judge by age.
    func testAPausedRecordingIsNeitherRecoveredNorCleanedUp() async throws {
        let dir = try makeTempDirectory(prefix: "pause_recovery")
        let (recorder, session) = makeRecorder(dir: dir)
        let (app, mic) = try startWithTracks(recorder, session)
        let stem = try XCTUnwrap(RecordingFileSuffix.stripAppRaw(from: app.lastPathComponent))
        let stale = Date().addingTimeInterval(-60)
        try backdate([app, mic], to: stale)

        recorder.pause()
        await waitFor(isTouched(app, since: stale) && isTouched(mic, since: stale), timeout: .seconds(5))

        let crashed = dir.appendingPathComponent("20200101_000000" + RecordingFileSuffix.appRaw)
        let orphan = dir.appendingPathComponent("20200101_000001" + RecordingFileSuffix.appRaw)
        try writeRawFloat32([Float](repeating: 0.1, count: 16000), to: crashed)
        try Data().write(to: orphan)
        try backdate([crashed, orphan], to: stale)

        XCTAssertEqual(DualSourceRecorder.recoverCrashedRecordings(in: dir), 1, "the crashed recording, not the paused one")
        let mix = dir.appendingPathComponent(stem + RecordingFileSuffix.mix)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mix.path), "a paused recording is not a crash")

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "the raw app temp survives under its writer")
    }
}
