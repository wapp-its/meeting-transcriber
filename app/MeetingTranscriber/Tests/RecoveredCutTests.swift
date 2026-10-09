import AVFoundation
import Darwin
@testable import MeetingTranscriber
import XCTest

/// One recording in a staging folder, written the way the recorder and a crash
/// leave it, with its stored meeting-end cut. Times are offsets from
/// `captureEnd`, the moment its capture stopped.
struct StagedRecordingFixture {
    struct StoreFailed: Error {}

    /// A title-derived stem, the kind no diagnostics line may carry.
    static let stem = "2026-10-09_10-00-00_Weekly Sync"
    static let rate = 16000

    let dir: URL
    var stem = Self.stem
    /// An hour ago: far past the half minute within which recovery takes a
    /// recording for one still being written.
    let captureEnd = Date(timeIntervalSinceNow: -3600)

    func url(_ suffix: String) -> URL {
        dir.appendingPathComponent(stem + suffix)
    }

    /// A 16 kHz track of `seconds` holding a ramp, last written at
    /// `captureEnd + writtenAt`.
    @discardableResult
    func track(_ suffix: String, seconds: Double, writtenAt: TimeInterval = 0) throws -> URL {
        try AudioMixer.saveWAV(samples: ramp(seconds), sampleRate: Self.rate, url: url(suffix))
        try setWritten(url(suffix), at: writtenAt)
        return url(suffix)
    }

    /// The raw app temp a recording that tapped an app leaves when it dies.
    func rawAppTemp(seconds: Double, writtenAt: TimeInterval = 0) throws {
        try writeRawFloat32(ramp(seconds), to: url(RecordingFileSuffix.appRaw))
        try setWritten(url(RecordingFileSuffix.appRaw), at: writtenAt)
    }

    func marker() throws {
        try Data().write(to: DualSourceRecorder.inProgressMarker(stem: stem, in: dir))
    }

    /// A recording that stopped but was not cut yet: mix and both tracks, no
    /// marker. The microphone was written last during capture, the app track
    /// and the mix at the stop.
    func stoppedRecording(seconds: Double = 10) throws {
        try track(RecordingFileSuffix.mic, seconds: seconds)
        try track(RecordingFileSuffix.app, seconds: seconds, writtenAt: 1)
        try track(RecordingFileSuffix.mix, seconds: seconds, writtenAt: 1)
    }

    func setWritten(_ url: URL, at offset: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: captureEnd.addingTimeInterval(offset)], ofItemAtPath: url.path,
        )
    }

    func storeCut(
        startedAt: TimeInterval,
        cutAt: TimeInterval,
        deadline: TimeInterval = 10,
        captureEndedAt: Date? = nil,
        keptSeconds: TimeInterval? = nil,
    ) throws {
        let record = PendingRecordingCut(
            stem: stem,
            cutAt: captureEnd.addingTimeInterval(cutAt),
            startedAt: captureEnd.addingTimeInterval(startedAt),
            deadline: captureEnd.addingTimeInterval(deadline),
            captureEndedAt: captureEndedAt,
            keptSeconds: keptSeconds,
        )
        guard case .written = PendingRecordingCut.write(record, in: dir) else { throw StoreFailed() }
    }

    func frames(_ suffix: String) throws -> AVAudioFramePosition {
        try AVAudioFile(forReading: url(suffix)).length
    }

    var storedCutExists: Bool {
        FileManager.default.fileExists(atPath: PendingRecordingCut.url(stem: stem, in: dir).path)
    }

    func hiddenFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
    }

    private func ramp(_ seconds: Double) -> [Float] {
        (0 ..< Int(seconds * Double(Self.rate))).map { Float($0 % 1000) / 2000 }
    }
}

/// The stored meeting-end cut applied by the launch recovery of the staging
/// folder: a crashed or stopped-but-uncut recording ends where the countdown
/// would have cut it, an interrupted cut is finished at the same point and
/// never deepened, and every cut that must not apply leaves the recording as
/// recorded. Real WAV files in a real folder, through the same sequence the
/// production pass runs.
final class RecoveredCutTests: XCTestCase {
    /// Placed by the "from the start" estimate, so the expected frame does not
    /// depend on how exactly a file system keeps modification times: started
    /// 11 s and cut 3 s before the capture ended keeps 8 s of a 10 s mix (the
    /// "from the end" estimate is 7 s).
    private let byStart = (startedAt: -11.0, cutAt: -3.0, frames: AVAudioFramePosition(128_000))
    /// Placed by the "from the end" estimate, so the capture end decides the
    /// frame: 6.999 968 75 s of a 10 s mix, half a frame clear of a whole one.
    private let byCaptureEnd = (startedAt: -5.0, cutAt: -3.000_031_25, frames: AVAudioFramePosition(111_999))

    private func makeFixture(_ name: String) throws -> StagedRecordingFixture {
        try StagedRecordingFixture(dir: makeTempDirectory(prefix: "recovered-cut-\(name)"))
    }

    /// A sink whose lines are checked, once the test ends, for the stem and
    /// for any path.
    private func makeLog() -> RecordingDiagnostics {
        let log = RecordingDiagnostics()
        addTeardownBlock {
            for entry in log.lines {
                XCTAssertFalse(entry.line.contains(StagedRecordingFixture.stem), "a line names the recording: \(entry.line)")
                XCTAssertFalse(entry.line.contains("/"), "a line carries a path: \(entry.line)")
            }
        }
        return log
    }

    private func recover(_ fixture: StagedRecordingFixture, _ log: RecordingDiagnostics) {
        PipelineController.recoverStagingFolder(fixture.dir, levelBalance: false, diagnostics: log)
    }

    private func contents(_ fixture: StagedRecordingFixture, _ suffixes: [String] = RecordingFileSuffix.all) throws -> [Data] {
        try suffixes.map { try Data(contentsOf: fixture.url($0)) }
    }

    // MARK: - Where the cut lands

    func testDecideKeepsAResolvedCutAndPlacesAnUnresolvedOneByTheLiveRule() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func record(ended: TimeInterval?, cutAt: TimeInterval = 100, kept: TimeInterval? = nil) -> PendingRecordingCut {
            PendingRecordingCut(
                stem: "s", cutAt: start + cutAt, startedAt: start, deadline: start + 240,
                captureEndedAt: ended.map { start + $0 }, keptSeconds: kept,
            )
        }
        let cases: [(name: String, record: PendingRecordingCut, mix: TimeInterval?, expected: RecoveredCut.Decision)] = [
            ("resolved, no capture end", record(ended: nil, kept: 42.5), 250, .cut(keptSeconds: 42.5)),
            ("resolved, ended long past the deadline", record(ended: 10000, kept: 42.5), 250, .cut(keptSeconds: 42.5)),
            // Capture began before it was seen running: the end estimate wins.
            ("ended inside the countdown", record(ended: 220), 250, .cut(keptSeconds: 130)),
            ("ended at the deadline plus the tolerance", record(ended: 540), 250, .cut(keptSeconds: 100)),
            ("ended just after it", record(ended: 540.001), 250, .refuse(.ranPastDeadline)),
            ("no capture end", record(ended: nil), 250, .refuse(.noCaptureEnd)),
            ("cut at the audio's start", record(ended: 220, cutAt: 0), 200, .refuse(.nothingToKeep)),
            ("cut before it", record(ended: 220, cutAt: -5), nil, .refuse(.nothingToKeep)),
        ]
        for (name, record, mix, expected) in cases {
            XCTAssertEqual(RecoveredCut.decide(record: record, mixDuration: mix), expected, name)
        }
        XCTAssertEqual(
            RecoveredCut.decide(record: record(ended: 220), mixDuration: 250),
            .cut(keptSeconds: RecordingCut.keptSeconds(cutAt: start + 100, startedAt: start, stoppedAt: start + 220, mixDuration: 250)),
            "the live cut's own placement",
        )
    }

    // MARK: - Recordings that are cut

    func testACrashedDualSourceRecordingIsCutBeforeItIsQueued() throws {
        let fixture = try makeFixture("dual")
        let log = makeLog()
        try fixture.rawAppTemp(seconds: 10)
        try fixture.track(RecordingFileSuffix.mic, seconds: 10)
        try fixture.marker()
        try fixture.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)

        recover(fixture, log)

        for suffix in RecordingFileSuffix.all {
            XCTAssertEqual(try fixture.frames(suffix), byStart.frames, suffix)
        }
        XCTAssertFalse(fixture.storedCutExists)
        XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut"), ["recovered_cut applied removed_s=2 kept_s=8"])
        XCTAssertEqual(try fixture.hiddenFiles(), [])
    }

    /// A microphone-only crash, and a recording that stopped but died before
    /// its live cut (a mix and no marker, so only the orphan scan sees it).
    func testAMicrophoneOnlyCrashAndAStoppedButUncutRecordingAreCutTheSameWay() throws {
        let shapes: [(name: String, build: (StagedRecordingFixture) throws -> Void, tracks: [String])] = [
            ("microphone-only crash", { fixture in
                try fixture.track(RecordingFileSuffix.mic, seconds: 10)
                try fixture.marker()
            }, [RecordingFileSuffix.mix, RecordingFileSuffix.mic]),
            ("stopped, not cut", { try $0.stoppedRecording() }, RecordingFileSuffix.all),
        ]
        for (name, build, tracks) in shapes {
            let fixture = try makeFixture("shape")
            let log = makeLog()
            try build(fixture)
            try fixture.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)

            recover(fixture, log)

            for suffix in tracks {
                XCTAssertEqual(try fixture.frames(suffix), byStart.frames, "\(name): \(suffix)")
            }
            XCTAssertFalse(fixture.storedCutExists, name)
            XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut applied").count, 1, name)
        }
    }

    /// Scaled from capture beginning 3 s before it was seen running: started
    /// at 0, cut at 10, stopped at 22, a 25 s mix, so the live cut keeps 13 s.
    /// Placed again on a 13 s mix it would keep 10.
    func testAResolvedCutIsFinishedAtItsPointAndNeverCutDeeper() throws {
        XCTAssertEqual(
            RecordingCut.keptSeconds(
                cutAt: Date(timeIntervalSince1970: 10),
                startedAt: Date(timeIntervalSince1970: 0),
                stoppedAt: Date(timeIntervalSince1970: 22),
                mixDuration: 13,
            ),
            10, "premise: placing the cut on the cut mix would cut deeper",
        )
        let shapes: [(name: String, mix: Double, tracks: Double)] = [("already cut", 13, 13), ("crashed mid-swap", 13, 25)]
        for (name, mixSeconds, trackSeconds) in shapes {
            let fixture = try makeFixture("resolved")
            let log = makeLog()
            try fixture.track(RecordingFileSuffix.mic, seconds: trackSeconds)
            try fixture.track(RecordingFileSuffix.app, seconds: trackSeconds)
            try fixture.track(RecordingFileSuffix.mix, seconds: mixSeconds)
            try fixture.storeCut(startedAt: -22, cutAt: -12, captureEndedAt: fixture.captureEnd, keptSeconds: 13)

            recover(fixture, log)

            for suffix in RecordingFileSuffix.all {
                XCTAssertEqual(try fixture.frames(suffix), 208_000, "\(name): \(suffix)")
            }
            XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut"), ["recovered_cut applied removed_s=0 kept_s=13"], name)
        }
    }

    /// The re-mix writes the app track anew, so a pass that died after it
    /// would read a capture end of "now" from that track and refuse the cut.
    /// The first pass stored the original one.
    func testAnAppOnlyRecordingInterruptedAfterItsReMixIsCutWhereOnePassCutsIt() throws {
        var results: [[AVAudioFramePosition]] = []
        for interrupted in [false, true] {
            let fixture = try makeFixture("app-only")
            let log = makeLog()
            try fixture.rawAppTemp(seconds: 10)
            try fixture.marker()
            try fixture.storeCut(startedAt: byCaptureEnd.startedAt, cutAt: byCaptureEnd.cutAt)
            if interrupted {
                _ = RecoveredCut.collect(in: fixture.dir, diagnostics: log)
                XCTAssertEqual(DualSourceRecorder.recoverCrashedRecordings(in: fixture.dir), 1)
                let rewritten = try XCTUnwrap(
                    FileManager.default.attributesOfItem(atPath: fixture.url(RecordingFileSuffix.app).path)[.modificationDate] as? Date,
                )
                XCTAssertGreaterThan(rewritten, fixture.captureEnd + 10 + RecoveredCut.deadlineTolerance, "premise")
            }

            recover(fixture, log)

            try results.append([fixture.frames(RecordingFileSuffix.mix), fixture.frames(RecordingFileSuffix.app)])
            XCTAssertFalse(fixture.storedCutExists)
        }
        XCTAssertEqual(results, [[byCaptureEnd.frames, byCaptureEnd.frames], [byCaptureEnd.frames, byCaptureEnd.frames]])
    }

    /// Collected before headers are repaired and tracks re-mixed: the stop
    /// is the raw app temp's last write, which the re-mix deletes. Read after
    /// it, the microphone's would place the cut a second later.
    func testTheCaptureEndIsReadBeforeHeadersAreRepairedAndTracksReMixed() throws {
        let fixture = try makeFixture("before-repair")
        let log = makeLog()
        try fixture.rawAppTemp(seconds: 10)
        let mic = try writeUnfinalizedWav(at: fixture.url(RecordingFileSuffix.mic), seconds: 10)
        try fixture.setWritten(mic, at: -1)
        try fixture.marker()
        try fixture.storeCut(startedAt: byCaptureEnd.startedAt, cutAt: byCaptureEnd.cutAt)
        XCTAssertEqual(try dataChunkSize(at: mic), 0, "premise: the microphone's header is unfinalized")

        recover(fixture, log)

        for suffix in RecordingFileSuffix.all {
            XCTAssertEqual(try fixture.frames(suffix), byCaptureEnd.frames, suffix)
        }
        XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut"), ["recovered_cut applied removed_s=3 kept_s=7"])
    }

    /// Neither the capture end nor the resolved cut can be stored; the value
    /// read is used and the cut still goes ahead.
    func testACutWhoseResolutionCannotBeStoredStillCuts() throws {
        let fixture = try makeFixture("store-fails")
        let log = makeLog()
        try fixture.stoppedRecording()
        try fixture.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)
        let failingOnFiles: PendingRecordingCut.Sync = { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.EIO) }
        }

        let collected = RecoveredCut.collect(in: fixture.dir, diagnostics: log, sync: failingOnFiles)
        RecoveredCut.apply(collected, in: fixture.dir, diagnostics: log, sync: failingOnFiles)

        XCTAssertEqual(log.lines(.warning, startingWith: "recovered_cut_store_failed"), [
            "recovered_cut_store_failed value=capture_end outcome=not_published domain=NSPOSIXErrorDomain code=5",
            "recovered_cut_store_failed value=kept_s outcome=not_published domain=NSPOSIXErrorDomain code=5",
        ])
        XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut"), ["recovered_cut applied removed_s=2 kept_s=8"])
        XCTAssertEqual(try fixture.frames(RecordingFileSuffix.mix), byStart.frames)
        XCTAssertFalse(fixture.storedCutExists)
    }

    // MARK: - Stored cuts that are refused or left alone

    func testAStoredCutBesideARecordingThatRanPastTheDeadlineIsRefused() throws {
        let fixture = try makeFixture("past-deadline")
        let log = makeLog()
        try fixture.stoppedRecording()
        try fixture.storeCut(startedAt: -405, cutAt: -400, deadline: -RecoveredCut.deadlineTolerance - 1)
        let before = try contents(fixture)

        recover(fixture, log)

        XCTAssertEqual(try contents(fixture), before)
        XCTAssertFalse(fixture.storedCutExists)
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut"), ["recovered_cut refused reason=ran_past_deadline"])
    }

    func testInvalidStoredCutsAreRemovedAndAHeldOneIsLeftAlone() throws {
        let now = Date()
        let other = try JSONEncoder().encode(PendingRecordingCut(stem: "other", cutAt: now, startedAt: now, deadline: now))
        for (stored, reason) in [(Data("not a record".utf8), "unreadable"), (other, "other_recording")] {
            let fixture = try makeFixture("invalid")
            let log = makeLog()
            try fixture.stoppedRecording()
            try stored.write(to: PendingRecordingCut.url(stem: fixture.stem, in: fixture.dir))
            let before = try contents(fixture)

            recover(fixture, log)

            XCTAssertEqual(try contents(fixture), before, reason)
            XCTAssertFalse(fixture.storedCutExists, reason)
            XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut"), ["recovered_cut refused reason=\(reason)"])
        }

        let fixture = try makeFixture("held")
        let log = makeLog()
        try fixture.stoppedRecording()
        try fixture.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)
        let before = try contents(fixture, RecordingFileSuffix.all + [RecordingFileSuffix.pendingCut])
        PendingRecordingCut.hold(fixture.stem)
        defer { PendingRecordingCut.release(fixture.stem) }

        recover(fixture, log)

        XCTAssertEqual(try contents(fixture, RecordingFileSuffix.all + [RecordingFileSuffix.pendingCut]), before)
        XCTAssertTrue(log.lines.isEmpty)
    }

    func testAStoredCutWithoutAMixWaitsForItsMarkerIsStaleWithoutAndCutsARestoredMix() throws {
        let waiting = try makeFixture("waiting")
        try waiting.marker()
        try waiting.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)
        let stale = try makeFixture("stale")
        try stale.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)
        let hidden = try makeFixture("hidden-mix")
        try hidden.stoppedRecording()
        try RecordingCut.rename(hidden.url(RecordingFileSuffix.mix), RecordingCut.backupURL(for: hidden.url(RecordingFileSuffix.mix)))
        try hidden.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)
        let logs = [makeLog(), makeLog(), makeLog()]

        for (fixture, log) in zip([waiting, stale, hidden], logs) {
            recover(fixture, log)
        }

        XCTAssertTrue(waiting.storedCutExists, "the re-mix may still succeed on a later pass")
        XCTAssertTrue(logs[0].lines.isEmpty)
        XCTAssertFalse(stale.storedCutExists)
        XCTAssertEqual(logs[1].lines(.notice, startingWith: "recovered_cut"), ["recovered_cut refused reason=stale"])
        for suffix in RecordingFileSuffix.all {
            XCTAssertEqual(try hidden.frames(suffix), byStart.frames, suffix)
        }
        XCTAssertEqual(logs[2].lines(.notice, startingWith: "recovered_cut"), ["recovered_cut applied removed_s=2 kept_s=8"])
        XCTAssertEqual(try hidden.hiddenFiles(), [])
    }

    // MARK: - A cut that fails

    func testACutThatFailsLeavesTheOriginalsAndQueuesTheRecordingUncut() throws {
        let fixture = try makeFixture("unreadable-track")
        let log = makeLog()
        try fixture.stoppedRecording()
        try Data("not audio".utf8).write(to: fixture.url(RecordingFileSuffix.mic))
        try fixture.setWritten(fixture.url(RecordingFileSuffix.mic), at: 0)
        try fixture.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)
        let before = try contents(fixture)

        recover(fixture, log)

        XCTAssertEqual(try contents(fixture), before)
        XCTAssertFalse(fixture.storedCutExists)
        XCTAssertEqual(log.lines(.warning, startingWith: "recovered_cut_failed domain=").count, 1)
        XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut").count, 0)
        XCTAssertEqual(try fixture.hiddenFiles(), [])
    }

    /// A rename that fails on the given calls, counted from one.
    private func renameFailing(on failing: Set<Int>) -> (URL, URL) throws -> Void {
        var calls = 0
        return { source, destination in
            calls += 1
            if failing.contains(calls) { throw POSIXError(.EIO) }
            try RecordingCut.rename(source, destination)
        }
    }

    /// The app track's swap fails, then putting the mix back fails, so the
    /// cut leaves the original mix under its hidden name; recovery moves it
    /// back and the recording is queued uncut.
    func testAnOriginalTheCutsRollbackLeftHiddenIsPutBack() throws {
        let fixture = try makeFixture("rollback")
        let log = makeLog()
        try fixture.stoppedRecording()
        try fixture.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)
        let before = try contents(fixture)

        let collected = RecoveredCut.collect(in: fixture.dir, diagnostics: log)
        RecoveredCut.apply(collected, in: fixture.dir, diagnostics: log, rename: renameFailing(on: [2, 3]))

        XCTAssertEqual(try contents(fixture), before, "every original back on its path")
        XCTAssertFalse(fixture.storedCutExists)
        XCTAssertEqual(log.lines(.warning, startingWith: "recovered_cut_failed"), ["recovered_cut_failed rollback_incomplete tracks_moved=1"])
        XCTAssertEqual(try fixture.hiddenFiles(), [])
    }

    /// The mix sits under its hidden name and cannot be renamed back: the
    /// recording is not judged stale, the stored cut stays, and the next
    /// complete pass with a working rename restores the mix and cuts it.
    func testAnOriginalThatCannotBePutBackKeepsTheStoredCutUntilALaterPassRestoresIt() throws {
        let fixture = try makeFixture("restore-fails")
        let log = makeLog()
        try fixture.stoppedRecording()
        let backup = RecordingCut.backupURL(for: fixture.url(RecordingFileSuffix.mix))
        try RecordingCut.rename(fixture.url(RecordingFileSuffix.mix), backup)
        try fixture.storeCut(startedAt: byStart.startedAt, cutAt: byStart.cutAt)

        let collected = RecoveredCut.collect(in: fixture.dir, diagnostics: log)
        RecoveredCut.apply(collected, in: fixture.dir, diagnostics: log, rename: renameFailing(on: Set(1 ... 10)))

        XCTAssertTrue(fixture.storedCutExists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url(RecordingFileSuffix.mix).path))
        XCTAssertEqual(log.lines(.warning, startingWith: "recovered_cut_failed"), [
            "recovered_cut_failed restore tracks_left=1 domain=NSPOSIXErrorDomain code=5",
        ])

        recover(fixture, log)

        for suffix in RecordingFileSuffix.all {
            XCTAssertEqual(try fixture.frames(suffix), byStart.frames, suffix)
        }
        XCTAssertFalse(fixture.storedCutExists)
        XCTAssertEqual(log.lines(.notice, startingWith: "recovered_cut"), ["recovered_cut applied removed_s=2 kept_s=8"])
        XCTAssertEqual(try fixture.hiddenFiles(), [])
    }
}
