@testable import MeetingTranscriber
import XCTest

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
