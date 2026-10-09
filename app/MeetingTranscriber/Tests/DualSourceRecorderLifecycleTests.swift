import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The in-progress marker's whole life: written before capture opens, dropped
/// again when the start never opened, and dropped only once a durable mix
/// exists. Crash recovery reads that marker as "this process died mid-
/// recording", so every one of these transitions decides whether a real
/// recording is rescued, lost, or resurrected as a duplicate.
///
/// Reachable at all because the recorder takes its staging directory and its
/// capture session as arguments. Without both, driving `start()` would open the
/// real hardware and write into the production staging directory that crash
/// recovery and the orphan scan walk.
@MainActor
final class DualSourceRecorderLifecycleTests: XCTestCase {
    // MARK: - Doubles

    /// A capture session that touches nothing: it throws what the test staged,
    /// records what the recorder asked for, and reports back the file the test
    /// wrote.
    private final class FakeCaptureSession: AudioCapturing {
        var startError: (any Error)?
        /// The tracks `stop()` reports, set by a test after `start()` has
        /// picked the URLs and the test has written fixture audio there.
        var appTrack: URL?
        var micTrack: URL?
        var appLevelDBFS: Double = -120
        var micLevelDBFS: Double = -120
        var appCaptureGaveUp = false
        var micCaptureGaveUp = false
        var appSilentTrackWatchdogGaveUp = false
        var appSignalAges: ChannelSignalAges = .unknown
        var micSignalAges: ChannelSignalAges = .unknown
        /// The configuration the recorder handed the factory, so a test can
        /// assert on the choices and write to the URLs it picked.
        var lastConfiguration: AudioCaptureConfiguration?

        func start() throws {
            if let startError { throw startError }
        }

        func stop() -> AudioCaptureResult {
            AudioCaptureResult(
                appAudioFileURL: appTrack, micAudioFileURL: micTrack,
                actualSampleRate: 16000, actualChannels: 1, micDelay: 0,
            )
        }
    }

    // MARK: - Helpers

    private func makeRecorder(
        dir: URL,
        pendingCutSync: @escaping PendingRecordingCut.Sync = { try PendingRecordingCut.fullSync($0) },
    ) -> (DualSourceRecorder, FakeCaptureSession) {
        let session = FakeCaptureSession()
        let recorder = DualSourceRecorder(
            recordingsDir: dir,
            makeCaptureSession: { configuration in
                session.lastConfiguration = configuration
                return session
            },
            pendingCutSync: pendingCutSync,
        )
        return (recorder, session)
    }

    /// Stems of the markers in `dir`, read through the same suffix rule the
    /// janitor and crash recovery use rather than a second copy of it.
    private func markerStems(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .compactMap { RecordingFileSuffix.stripInProgress(from: $0) }
    }

    /// Start a microphone-only recording and hand back the mic track's URL, so
    /// the test can stage what the session will report at `stop()`.
    private func startMicOnly(
        recorder: DualSourceRecorder,
        session: FakeCaptureSession,
    ) throws -> URL {
        try recorder.start(source: .micOnly)
        return try XCTUnwrap(session.lastConfiguration?.micOutputURL)
    }

    // MARK: - start

    func testStartMarksTheRecordingUnderTheSameStemAsItsTracks() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_start")
        let (recorder, session) = makeRecorder(dir: dir)

        let micURL = try startMicOnly(recorder: recorder, session: session)

        XCTAssertTrue(recorder.isRecording)
        let track = try XCTUnwrap(RecordingFileSuffix.stripSuffix(from: micURL.lastPathComponent))
        XCTAssertEqual(
            try markerStems(in: dir), [track.stem],
            "recovery pairs marker and tracks by stem, so a marker under any other name rescues nothing",
        )
    }

    /// The microphone-only shape (issue #633): no process tap is opened at all,
    /// which is not the same as a tap that captured nothing — the session
    /// treats a mic failure as terminal only when the mic is the whole
    /// recording.
    func testAMicrophoneOnlyRecordingOpensNoProcessTap() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_mic_only")
        let (recorder, session) = makeRecorder(dir: dir)

        try recorder.start(source: .micOnly)

        let configuration = try XCTUnwrap(session.lastConfiguration)
        XCTAssertNil(configuration.appOutputURL, "a tap would capture a meeting that is happening in the room")
        XCTAssertNotNil(configuration.micOutputURL)
        XCTAssertTrue(configuration.pids.isEmpty)
    }

    /// The mirror image: "No Microphone" opens the tap and no mic track.
    func testAnAppOnlyRecordingOpensNoMicrophone() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_app_only")
        let (recorder, session) = makeRecorder(dir: dir)

        // A PID no process holds: the tap-PID resolution then has no bundle to
        // enumerate and falls back to the root alone, with nothing to depend on
        // in whatever else is running on the machine.
        try recorder.start(source: .appOnly(pid: 999_999))

        let configuration = try XCTUnwrap(session.lastConfiguration)
        XCTAssertNotNil(configuration.appOutputURL)
        XCTAssertNil(configuration.micOutputURL)
        XCTAssertEqual(configuration.pids, [999_999])
    }

    /// A start that threw before capture opened is not an interrupted
    /// recording, and nothing else would ever clear its marker: `stop()` is
    /// unreachable with `isRecording` still false, and the janitor keys on
    /// tracks this start never created.
    func testAStartThatNeverOpenedLeavesNoMarkerBehind() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_start_failed")
        let (recorder, session) = makeRecorder(dir: dir)
        session.startError = RecorderError.noAudioData

        XCTAssertThrowsError(try recorder.start(source: .micOnly))

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(try markerStems(in: dir), [], "a start that never opened is not a crash")
    }

    // MARK: - stop

    func testStopDropsTheMarkerOnceTheMixExists() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_stop")
        let (recorder, session) = makeRecorder(dir: dir)
        let micURL = try startMicOnly(recorder: recorder, session: session)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micURL)
        session.micTrack = micURL

        let recording = try recorder.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.mixPath.path))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(
            try markerStems(in: dir), [],
            "a marker left beside a finished recording turns into a false crash on the next launch",
        )
    }

    /// A stop whose mix write fails has finished nothing. Keeping the marker is
    /// what lets the next launch re-mix from the surviving tracks — the same
    /// second chance the app-audio path has always had from its raw temp.
    func testAStopWhoseMixFailsKeepsTheMarkerForTheNextLaunch() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_stop_failed")
        let (recorder, session) = makeRecorder(dir: dir)
        let micURL = try startMicOnly(recorder: recorder, session: session)
        // Past the size guard, but not decodable audio: the mix fails after the
        // tracks have been read and before anything durable is written.
        try Data(repeating: 0xFF, count: 128).write(to: micURL)
        session.micTrack = micURL

        XCTAssertThrowsError(try recorder.stop())

        XCTAssertEqual(
            try markerStems(in: dir).count, 1,
            "dropping the marker here would strand a mic-only recording for good",
        )
    }

    // MARK: - Channel reporting

    /// The levels, the give-up flags and the signal ages all come from the live
    /// session. A level cannot say a channel was abandoned: one that fell
    /// silent may come back, one that gave up will not.
    func testTheRecorderReportsTheLiveSessionsChannelState() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_levels")
        let (recorder, session) = makeRecorder(dir: dir)
        // Each channel gets a different value from its sibling, so a forwarder
        // wired to the wrong one — or hardcoded to the no-session default —
        // fails rather than coinciding with the right answer.
        session.appLevelDBFS = -12
        session.micLevelDBFS = -30
        session.appCaptureGaveUp = true
        session.micCaptureGaveUp = false
        session.appSilentTrackWatchdogGaveUp = true
        session.appSignalAges = ChannelSignalAges(secondsSinceLastBuffer: 1, secondsSinceLastEnergy: 2)
        session.micSignalAges = ChannelSignalAges(secondsSinceLastBuffer: 3, secondsSinceLastEnergy: 4)

        // Between recordings there is no session to ask, and silence plus "has
        // not given up" is the only safe answer: a spurious give-up would tell
        // the user a capture died that never ran.
        XCTAssertEqual(recorder.appLevelDBFS, -120, accuracy: 0.001)
        XCTAssertEqual(recorder.micLevelDBFS, -120, accuracy: 0.001)
        XCTAssertFalse(recorder.appCaptureGaveUp)
        XCTAssertFalse(recorder.micCaptureGaveUp)
        XCTAssertFalse(recorder.appSilentTrackWatchdogGaveUp)
        // Never opened, not "opened and long silent": the fault monitor reads
        // the two apart, so the no-session answer has to be the absent one.
        XCTAssertEqual(recorder.appSignalAges, .unknown)
        XCTAssertEqual(recorder.micSignalAges, .unknown)

        try recorder.start(source: .micOnly)

        XCTAssertEqual(recorder.appLevelDBFS, -12, accuracy: 0.001)
        XCTAssertEqual(recorder.micLevelDBFS, -30, accuracy: 0.001)
        XCTAssertTrue(recorder.appCaptureGaveUp)
        XCTAssertFalse(recorder.micCaptureGaveUp)
        XCTAssertTrue(recorder.appSilentTrackWatchdogGaveUp)
        // Its own flag, not the give-up one read under another name.
        session.appCaptureGaveUp = false
        XCTAssertTrue(recorder.appSilentTrackWatchdogGaveUp)
        session.appCaptureGaveUp = true
        XCTAssertEqual(recorder.appSignalAges.secondsSinceLastBuffer, 1)
        XCTAssertEqual(recorder.appSignalAges.secondsSinceLastEnergy, 2)
        XCTAssertEqual(recorder.micSignalAges.secondsSinceLastBuffer, 3)
        XCTAssertEqual(recorder.micSignalAges.secondsSinceLastEnergy, 4)
    }

    // MARK: - Silent-track watchdog option (issue #672)

    /// The option has to travel from the setting to the capture configuration
    /// a recording opens with. Two hops live in this module: the recorder
    /// factory reads the setting into the recorder, and the recorder writes it
    /// into `AudioCaptureConfiguration`. The hop from there into the tap is
    /// pinned in AudioTapLib. A dropped hop would leave the switch reading "on"
    /// while every recording ran without the watchdog.
    func testTheRecorderOpensWithoutTheWatchdogByDefault() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_watchdog_default")
        let (recorder, session) = makeRecorder(dir: dir)
        try recorder.start(source: .micOnly)
        XCTAssertEqual(session.lastConfiguration?.silentTrackWatchdog, false)
    }

    func testTheRecorderHandsTheWatchdogToTheCapture() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_watchdog_on")
        let (recorder, session) = makeRecorder(dir: dir)
        recorder.silentTrackWatchdogEnabled = true
        try recorder.start(source: .micOnly)
        XCTAssertEqual(session.lastConfiguration?.silentTrackWatchdog, true)
    }

    /// The setting reaches a recording that `WatchingController` starts, read
    /// when that recording starts rather than when watching was set up.
    func testTheSettingReachesARecordingTheControllerStarts() async throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_watchdog_controller")
        let (recorder, session) = makeRecorder(dir: dir.appendingPathComponent("staging", isDirectory: true))
        let controller = makeWatchingController(
            logDir: dir, permissionHealth: .allHealthy,
            // Labelled on purpose: as a trailing closure it would bind to the
            // first closure parameter, not to `makeRecorder`.
            // swiftlint:disable:next trailing_closure
            makeRecorder: { recorder },
        )
        controller.settings.silentTrackWatchdogEnabled = true

        // This process, so the target is alive for the length of the test.
        controller.startManualRecording(pid: getpid(), appName: "Chrome", title: "Standup")
        addTeardownBlock { controller.stopManualRecording() }
        await waitFor(controller.watchLoop?.state == .recording, timeout: .seconds(2))

        XCTAssertEqual(session.lastConfiguration?.silentTrackWatchdog, true)
    }

    // MARK: - Level balance

    /// `stop()` hands the recorder's flag to the mix: a quiet microphone and a
    /// loud far end land within 6 dB of each other with it on, and stay as far
    /// apart as recorded with it off.
    func testStopHandsTheLevelBalanceFlagToTheMix() throws {
        for levelBalance in [false, true] {
            let dir = try makeTempDirectory(prefix: "lifecycle_level_balance")
            let (recorder, session) = makeRecorder(dir: dir)
            recorder.levelBalanceEnabled = levelBalance
            // A PID no process holds, as in the app-only test above.
            try recorder.start(source: .appAndMic(pid: 999_999))
            let configuration = try XCTUnwrap(session.lastConfiguration)
            session.appTrack = try XCTUnwrap(configuration.appOutputURL)
            session.micTrack = try XCTUnwrap(configuration.micOutputURL)
            // 16 kHz mono raw floats, what the in-IOProc resampler writes.
            try writeRawFloat32(HeadsetGapFixture.farEnd, to: XCTUnwrap(session.appTrack))
            try AudioMixer.saveWAV(
                samples: HeadsetGapFixture.ownVoice, sampleRate: HeadsetGapFixture.rate, url: XCTUnwrap(session.micTrack),
            )

            let mix = try AudioMixer.loadAudioFileAsFloat32(url: recorder.stop().mixPath)

            let gap = HeadsetGapFixture.gap(in: mix)
            if levelBalance {
                XCTAssertLessThanOrEqual(abs(gap), 6)
            } else {
                XCTAssertEqual(gap, HeadsetGapFixture.recordedGap, accuracy: 1)
            }
        }
    }

    /// The setting reaches a recording that `WatchingController` starts, both
    /// ways. The recorder comes in holding the opposite value, so a factory
    /// that never writes the flag, or always writes the same one, fails one of
    /// the two rounds.
    func testTheLevelBalanceSettingReachesARecordingTheControllerStarts() async throws {
        for enabled in [true, false] {
            let dir = try makeTempDirectory(prefix: "lifecycle_level_balance_controller")
            let (recorder, _) = makeRecorder(dir: dir.appendingPathComponent("staging", isDirectory: true))
            recorder.levelBalanceEnabled = !enabled
            let controller = makeWatchingController(
                logDir: dir, permissionHealth: .allHealthy,
                // swiftlint:disable:next trailing_closure
                makeRecorder: { recorder },
            )
            controller.settings.levelBalanceEnabled = enabled

            controller.startManualRecording(pid: getpid(), appName: "Chrome", title: "Standup")
            await waitFor(controller.watchLoop?.state == .recording, timeout: .seconds(2))

            XCTAssertEqual(recorder.levelBalanceEnabled, enabled)
            controller.stopManualRecording()
        }
    }
}

// MARK: - Stored meeting-end cut

/// The recorder writes, updates and removes the stored meeting-end cut
/// (`PendingRecordingCut`) of the recording it is making, and holds it in the
/// process-wide set that recovery leaves alone until its stop sequence has
/// settled it.
extension DualSourceRecorderLifecycleTests {
    /// The stored cuts in `dir`, a write's hidden temporary file included.
    private func storedCutFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(RecordingFileSuffix.pendingCut) }
    }

    /// The case a removal ended in, so an assertion on it names what it got.
    private func name(of outcome: PendingRecordingCut.RemoveOutcome) -> String {
        switch outcome {
        case .removed: "removed"
        case .removedNotSynced: "removedNotSynced"
        case .emptied: "emptied"
        case .failed: "failed"
        }
    }

    /// Start a microphone-only recording whose holds end with the test, and
    /// hand back its mic track and its stem.
    private func startHoldingRecording(
        _ recorder: DualSourceRecorder,
        _ session: FakeCaptureSession,
        in dir: URL,
    ) throws -> (mic: URL, stem: String) {
        addTeardownBlock { PendingRecordingCut.releaseAllForTesting() }
        let mic = try startMicOnly(recorder: recorder, session: session)
        return try (mic, XCTUnwrap(markerStems(in: dir).first))
    }

    func testAStoreWritesTheCutBesideTheMarkerOwnerOnlyAndHoldsIt() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_cut_store")
        let (recorder, session) = makeRecorder(dir: dir)
        let (_, stem) = try startHoldingRecording(recorder, session, in: dir)
        let now = Date()
        let first = PendingRecordingCut(stem: stem, cutAt: now - 60, startedAt: now - 600, deadline: now + 60)

        try recorder.storePendingCut(cutAt: first.cutAt, deadline: first.deadline, startedAt: first.startedAt)

        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .valid(first), "under the marker's stem")
        let path = PendingRecordingCut.url(stem: stem, in: dir).path
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(PendingRecordingCut.isHeld(stem))

        // A later question in the same recording.
        let second = PendingRecordingCut(stem: stem, cutAt: now - 5, startedAt: now - 590, deadline: now + 115)
        try recorder.storePendingCut(cutAt: second.cutAt, deadline: second.deadline, startedAt: second.startedAt)

        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .valid(second))
    }

    /// A cut-carrying stop: the live cut runs after `stop()` returns, records
    /// its resolution first, and clears the stored cut last.
    func testTheStoredCutOutlivesTheStopUntilItIsResolvedAndCleared() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_cut_resolve")
        let (recorder, session) = makeRecorder(dir: dir)
        let (mic, stem) = try startHoldingRecording(recorder, session, in: dir)
        let now = Date()
        try recorder.storePendingCut(cutAt: now - 60, deadline: now + 60, startedAt: now - 600)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: mic)
        session.micTrack = mic

        _ = try recorder.stop()

        XCTAssertEqual(try markerStems(in: dir), [], "the stop finished its recording")
        guard case var .valid(stored) = PendingRecordingCut.read(stem: stem, in: dir) else {
            XCTFail("the live cut has not run when the stop returns, so its stored cut must outlive it")
            return
        }
        XCTAssertTrue(PendingRecordingCut.isHeld(stem))

        try recorder.recordPendingCutResolution(keptSeconds: 540, captureEndedAt: now)
        try recorder.recordPendingCutResolution(keptSeconds: 1, captureEndedAt: now + 5)

        stored.keptSeconds = 540
        stored.captureEndedAt = now
        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .valid(stored), "set once, never changed")

        XCTAssertEqual(name(of: recorder.clearPendingCut()), "removed")
        XCTAssertEqual(PendingRecordingCut.read(stem: stem, in: dir), .absent)
        XCTAssertFalse(PendingRecordingCut.isHeld(stem))
    }

    /// What the loop does before every stop that carries no cut, whether or
    /// not a question was ever asked.
    func testAClearWithNothingStoredChangesNothing() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_cut_clear_nothing")
        let (recorder, session) = makeRecorder(dir: dir)
        XCTAssertEqual(name(of: recorder.clearPendingCut()), "removed", "between recordings")
        _ = try startHoldingRecording(recorder, session, in: dir)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        try recorder.recordPendingCutResolution(keptSeconds: 60, captureEndedAt: Date())
        XCTAssertEqual(name(of: recorder.clearPendingCut()), "removed")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), before)
    }

    /// The stop could not finalize the recording, so its marker survives for
    /// recovery, and the stored cut goes to recovery with it.
    func testAStopThatThrowsAfterAStoreHandsTheStoredCutToRecovery() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_cut_stop_failed")
        let (recorder, session) = makeRecorder(dir: dir)
        let (mic, stem) = try startHoldingRecording(recorder, session, in: dir)
        let now = Date()
        try recorder.storePendingCut(cutAt: now - 60, deadline: now + 60, startedAt: now - 600)
        // Not decodable audio, as in the marker test above: the mix fails.
        try Data(repeating: 0xFF, count: 128).write(to: mic)
        session.micTrack = mic

        XCTAssertThrowsError(try recorder.stop())

        XCTAssertEqual(try markerStems(in: dir), [stem])
        XCTAssertEqual(try storedCutFiles(dir), [stem + RecordingFileSuffix.pendingCut])
        XCTAssertFalse(PendingRecordingCut.isHeld(stem), "recovery passes over a held stored cut")
        // Recovery's now, not the recorder's.
        XCTAssertEqual(name(of: recorder.clearPendingCut()), "removed")
        XCTAssertEqual(try storedCutFiles(dir), [stem + RecordingFileSuffix.pendingCut])
    }

    func testAStoreWhileNotRecordingThrowsAndWritesNothing() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_cut_not_recording")
        let (recorder, session) = makeRecorder(dir: dir)
        let now = Date()
        let store = { try recorder.storePendingCut(cutAt: now - 60, deadline: now + 60, startedAt: now - 600) }
        let notRecording: (any Error) -> Void = { error in
            guard case RecorderError.notRecording = error else { return XCTFail("expected notRecording, got \(error)") }
        }

        XCTAssertThrowsError(try store(), "before the recording", notRecording)
        let (mic, stem) = try startHoldingRecording(recorder, session, in: dir)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: mic)
        session.micTrack = mic
        _ = try recorder.stop()
        XCTAssertThrowsError(try store(), "after it", notRecording)

        XCTAssertEqual(try storedCutFiles(dir), [])
        XCTAssertFalse(PendingRecordingCut.isHeld(stem))
    }

    /// The record is in place but its folder sync failed. Keep recording
    /// clears it all the same, so the recovery after a crash that follows
    /// leaves the whole recording.
    func testAStoreThatPublishedWithoutItsFolderSyncIsClearedByKeepAndRecoveryAppliesNothing() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_cut_folder_sync")
        let failure = POSIXError(.EIO)
        let (recorder, session) = makeRecorder(dir: dir) { descriptor in
            if isFolder(descriptor) { throw failure }
        }
        let (mic, stem) = try startHoldingRecording(recorder, session, in: dir)
        // Two seconds of capture that ended an hour ago, so recovery does not
        // take the recording for one still being written.
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 32000), sampleRate: 16000, url: mic)
        let captureEnd = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: captureEnd], ofItemAtPath: mic.path)
        let recorded = try Data(contentsOf: mic)

        // Left in place, recovery would cut this recording to its first second.
        XCTAssertThrowsError(try recorder.storePendingCut(
            cutAt: captureEnd - 1, deadline: captureEnd + 60, startedAt: captureEnd - 2,
        )) { error in
            XCTAssertEqual((error as? PendingCutWriteError)?.published, true)
            XCTAssertEqual((error as? PendingCutWriteError)?.underlying as? POSIXError, failure)
        }
        XCTAssertEqual(try storedCutFiles(dir), [stem + RecordingFileSuffix.pendingCut])
        XCTAssertTrue(PendingRecordingCut.isHeld(stem))

        XCTAssertEqual(name(of: recorder.clearPendingCut()), "removedNotSynced")
        XCTAssertEqual(try storedCutFiles(dir), [])
        XCTAssertFalse(PendingRecordingCut.isHeld(stem))

        // The app dies with the recording running; the next launch recovers.
        let log = RecordingDiagnostics()
        PipelineController.recoverStagingFolder(dir, levelBalance: false, diagnostics: log)

        XCTAssertEqual(log.lines.map(\.line), [])
        XCTAssertEqual(try Data(contentsOf: mic), recorded)
        let mix = dir.appendingPathComponent(stem + RecordingFileSuffix.mix)
        XCTAssertEqual(try XCTUnwrap(RecordingCut.duration(of: mix)), 2, accuracy: 0.001, "re-mixed whole, not cut")
    }

    func testAStoreWhoseFileSyncFailedPublishesNothingAndItsClearOnlyReleasesTheHold() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_cut_file_sync")
        let failure = POSIXError(.EIO)
        let (recorder, session) = makeRecorder(dir: dir) { descriptor in
            if !isFolder(descriptor) { throw failure }
        }
        let (_, stem) = try startHoldingRecording(recorder, session, in: dir)
        let now = Date()

        XCTAssertThrowsError(try recorder.storePendingCut(cutAt: now - 60, deadline: now + 60, startedAt: now - 600)) { error in
            XCTAssertEqual((error as? PendingCutWriteError)?.published, false)
            XCTAssertEqual((error as? PendingCutWriteError)?.underlying as? POSIXError, failure)
        }
        XCTAssertEqual(try storedCutFiles(dir), [], "neither the record nor its temporary file")
        XCTAssertTrue(PendingRecordingCut.isHeld(stem))

        // Nothing stored to resolve: its failure was the store's.
        try recorder.recordPendingCutResolution(keptSeconds: 60, captureEndedAt: now)
        XCTAssertEqual(name(of: recorder.clearPendingCut()), "removed")
        XCTAssertFalse(PendingRecordingCut.isHeld(stem))
    }
}

/// Whether an open descriptor is a folder, to tell the folder sync from the
/// file sync.
private func isFolder(_ descriptor: Int32) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
}
