import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// The staging recovery repairs WAV headers, re-mixes crashed recordings,
/// deletes temporary files and applies stored meeting-end cuts. All of them
/// write, so the folder it works in has to be the one the queue was built with
/// and never the process-wide default: a controller built against a temp
/// staging folder reaching into the real recordings folder is the hazard that
/// injecting the folder exists to remove.
///
/// Only the repaired header and the cut are asserted, because they have a
/// visible result on files these tests created. There is deliberately no probe
/// that reverts the fix: that one would scan and rewrite the real recordings
/// folder.
@MainActor
final class StagedRecoveryFolderTests: XCTestCase {
    func testTheStagedRecoveryWorksInTheQueuesStagingFolder() async throws {
        let staging = try makeTempDirectory(prefix: "StagedRecoveryStaging")
        let output = try makeTempDirectory(prefix: "StagedRecoveryOutput")

        // A mic track whose writer was killed, built from a real WAV the app
        // wrote and then left unfinalized and aged, so the repair is pinned
        // against the file shape it actually meets instead of an invented one.
        let unfinalized = staging.appendingPathComponent("20260101_1200_mic.wav")
        try writeUnfinalizedWav(at: unfinalized)
        XCTAssertEqual(try dataChunkSize(at: unfinalized), 0, "test premise: the header starts unfinalized")

        let queue = try PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: output,
            logDir: makeTempDirectory(prefix: "StagedRecoveryLog"),
            stagingDir: staging,
        )
        let recover = try XCTUnwrap(PipelineController.QueueEnvironment.production.recoverStagedRecordings)
        recover(queue, false)

        var repaired = false
        let deadline = ContinuousClock.now + .seconds(5)
        while !repaired, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            repaired = ((try? dataChunkSize(at: unfinalized)) ?? 0) > 0
        }
        XCTAssertTrue(
            repaired,
            "the staging recovery did not touch the queue's staging folder, so it was working somewhere else",
        )
    }

    // MARK: - The stored meeting-end cut

    /// A queue on a temp staging folder, wired to mocks.
    private func makeQueue(staging: URL) throws -> PipelineQueue {
        try PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: makeTempDirectory(prefix: "StagedRecoveryOutput"),
            logDir: makeTempDirectory(prefix: "StagedRecoveryLog"),
            stagingDir: staging,
        )
    }

    /// A stopped, uncut 25 s recording whose stored cut is placed by its
    /// capture end: 12.999 968 75 s are kept. Placed again on the cut mix the
    /// cut would keep under 10 s, so a second cut shows in the frame count.
    private func recordingToCut() throws -> StagedRecordingFixture {
        let fixture = try StagedRecordingFixture(dir: makeTempDirectory(prefix: "StagedRecoveryCut"))
        try fixture.stoppedRecording(seconds: 25)
        try fixture.storeCut(startedAt: -22, cutAt: -12.000_031_25)
        return fixture
    }

    private let keptFrames: AVAudioFramePosition = 207_999

    func testTheStoredCutIsAppliedInTheQueuesStagingFolder() async throws {
        let fixture = try recordingToCut()
        let recover = try XCTUnwrap(PipelineController.QueueEnvironment.production.recoverStagedRecordings)

        try recover(makeQueue(staging: fixture.dir), false)
        await PipelineController.stagedRecoveryPass?.value

        for suffix in RecordingFileSuffix.all {
            XCTAssertEqual(try fixture.frames(suffix), keptFrames, suffix)
        }
        XCTAssertFalse(fixture.storedCutExists)
    }

    /// A recording the pass left unsettled (an original track still under its
    /// hidden name) is passed over by the pass's orphan scan and released
    /// afterwards, so a later pass can queue it; every other recording is
    /// queued as before.
    func testTheOrphanScanPassesOverARecordingThePassLeftUnsettled() async throws {
        let dir = try makeTempDirectory(prefix: "StagedRecoveryOrphans")
        let unsettled = dir.appendingPathComponent("20260311_100000_mix.wav")
        let settled = dir.appendingPathComponent("20260311_110000_mix.wav")
        for mix in [unsettled, settled] {
            try Data(repeating: 0xFF, count: 100).write(to: mix)
        }
        let registry = InFlightRunRegistry()
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "StagedRecoveryLog"), stagingDir: dir, inFlightRuns: registry)

        await PipelineController.recoverOrphans(into: queue, holdingBack: [unsettled], recordingsDir: dir)

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Recovered Recording (20260311_110000)"])
        XCTAssertTrue(registry.claimedAudioPaths.isEmpty, "the hold ends with the scan")
    }

    // MARK: - A cut that is not settled yet

    /// One staged recovery pass on `dir`, the steps the production pass runs,
    /// with the orphan scan reading `dir`.
    private func runPass(on dir: URL, into queue: PipelineQueue) async {
        let unsettled = PipelineController.recoverStagingFolder(dir, levelBalance: false, diagnostics: RecordingDiagnostics())
        await PipelineController.recoverOrphans(
            into: queue, holdingBack: unsettled.map { dir.appendingPathComponent($0 + RecordingFileSuffix.mix) }, recordingsDir: dir,
        )
    }

    /// Between a detected meeting's live stop and its live cut, its mix is on
    /// its path and its stem is held: the state a pass running at that moment
    /// meets (a queue rebuilt while a meeting ends). The pass leaves the held
    /// stored cut to the stop, so its orphan scan must leave the recording to
    /// the stop too; queued now, it would be transcribed with the room audio
    /// the cut is about to remove. A stop whose stored cut was never written
    /// is held all the same and passed over the same way. Once the stop has
    /// cut it and settled its stored cut, the scan takes it as before, which
    /// shows the hold did the excluding.
    func testTheOrphanScanPassesOverARecordingBetweenItsLiveStopAndItsLiveCut() async throws {
        let dir = try makeTempDirectory(prefix: "StagedRecoveryHeld")
        let stored = StagedRecordingFixture(dir: dir, stem: "20260312_100000")
        let unstored = StagedRecordingFixture(dir: dir, stem: "20260312_110000")
        for fixture in [stored, unstored] {
            try fixture.stoppedRecording(seconds: 25)
            PendingRecordingCut.hold(fixture.stem)
        }
        defer { [stored, unstored].forEach { PendingRecordingCut.release($0.stem) } }
        try stored.storeCut(startedAt: -22, cutAt: -12.000_031_25)

        let queue = try makeQueue(staging: dir)
        await runPass(on: dir, into: queue)

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), [], "a recording whose live cut is still to come was queued")
        for fixture in [stored, unstored] {
            for suffix in RecordingFileSuffix.all {
                XCTAssertEqual(try fixture.frames(suffix), 400_000, "\(fixture.stem)\(suffix)")
            }
        }
        XCTAssertTrue(stored.storedCutExists)

        // The live cut done: its stored cut removed and the hold released.
        _ = PendingRecordingCut.remove(stem: stored.stem, in: dir)
        [stored, unstored].forEach { PendingRecordingCut.release($0.stem) }
        let next = try makeQueue(staging: dir)
        await runPass(on: dir, into: next)

        XCTAssertEqual(
            Set(next.jobs.map(\.meetingTitle)),
            ["Recovered Recording (20260312_100000)", "Recovered Recording (20260312_110000)"],
        )
    }

    /// A stored cut still beside a mix when the scan runs is one the pass did
    /// not settle: a cut-carrying stop that failed after the pass collected,
    /// which hands its cut to the next pass, or an unsettled restore. The
    /// scan passes over that recording, so it is cut before it is queued. An
    /// emptied stored cut is a settled one (it never decodes, so it is never
    /// applied) and holds nothing back.
    func testTheOrphanScanPassesOverARecordingWhoseStoredCutIsStillBesideIt() async throws {
        let dir = try makeTempDirectory(prefix: "StagedRecoveryStoredCut")
        let pending = StagedRecordingFixture(dir: dir, stem: "20260313_100000")
        let emptied = StagedRecordingFixture(dir: dir, stem: "20260313_110000")
        for fixture in [pending, emptied] {
            try fixture.stoppedRecording(seconds: 25)
            try fixture.storeCut(startedAt: -22, cutAt: -12.000_031_25)
        }
        try Data().write(to: PendingRecordingCut.url(stem: emptied.stem, in: dir))
        let queue = try makeQueue(staging: dir)

        await queue.recoverOrphanedRecordings(recordingsDir: dir)

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Recovered Recording (20260313_110000)"])
    }

    /// A recording recovered more than a day after it was made is still cut
    /// (its countdown minutes are not kept) but, as before this spec, no
    /// longer queued: the cut keeps the recording's age, so the orphan scan's
    /// day limit still excludes it. A fresh recording beside it is cut and
    /// queued, which is what shows the age and not the cut did the excluding.
    func testARecordingRecoveredAfterADayIsCutButNotQueued() async throws {
        let dir = try makeTempDirectory(prefix: "StagedRecoveryOld")
        let old = StagedRecordingFixture(dir: dir, stem: "20260301_100000")
        let fresh = StagedRecordingFixture(dir: dir, stem: "20260301_110000")
        for fixture in [old, fresh] {
            try fixture.stoppedRecording(seconds: 25)
            try fixture.storeCut(startedAt: -22, cutAt: -12.000_031_25)
        }
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 86400)
        for suffix in RecordingFileSuffix.all {
            try FileManager.default.setAttributes([.creationDate: twoDaysAgo], ofItemAtPath: old.url(suffix).path)
        }
        let queue = try makeQueue(staging: dir)

        let unsettled = PipelineController.recoverStagingFolder(dir, levelBalance: false, diagnostics: RecordingDiagnostics())
        await PipelineController.recoverOrphans(
            into: queue, holdingBack: unsettled.map { dir.appendingPathComponent($0 + RecordingFileSuffix.mix) }, recordingsDir: dir,
        )

        for fixture in [old, fresh] {
            for suffix in RecordingFileSuffix.all {
                XCTAssertEqual(try fixture.frames(suffix), keptFrames, "\(fixture.stem)\(suffix)")
            }
            XCTAssertFalse(fixture.storedCutExists, fixture.stem)
        }
        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Recovered Recording (20260301_110000)"])
    }

    /// A queue rebuilt while the previous pass still runs starts a second
    /// pass on the same folder. It waits for the first, which has settled the
    /// stored cut by then, so the recording is cut once and not deeper.
    func testTwoPassesStartedBackToBackCutTheRecordingOnce() async throws {
        let fixture = try recordingToCut()
        let queue = try makeQueue(staging: fixture.dir)
        let log = RecordingDiagnostics()

        let first = PipelineController.startStagedRecovery(into: queue, levelBalance: false, diagnostics: log)
        let second = PipelineController.startStagedRecovery(into: queue, levelBalance: false, diagnostics: log)
        await first.value
        await second.value

        for suffix in RecordingFileSuffix.all {
            XCTAssertEqual(try fixture.frames(suffix), keptFrames, suffix)
        }
        XCTAssertEqual(log.lines.map(\.line), ["recovered_cut applied removed_s=12 kept_s=13"])
    }
}
