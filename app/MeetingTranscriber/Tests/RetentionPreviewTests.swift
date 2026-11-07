@testable import MeetingTranscriber
import XCTest

/// What a retention value would delete now (R10, R14). The pure part on records with
/// no file behind them, the controller's part on real files in a temp folder.
@MainActor
final class RetentionPreviewTests: XCTestCase {
    private typealias Fixture = RetentionFixture
    private typealias FileOnDisk = RetentionPreview.FileOnDisk

    private let skipLine = "Meetings marked Keep, failed meetings and imported files are skipped. "
        + "Recordings made before this feature existed are not touched."

    private func selection(
        _ records: [MeetingFileRecord], live: [UUID: LiveMeetingState] = [:], retention: RecordingRetention = .days30,
        now: Date = Fixture.longAfter,
    ) -> RetentionPreview.Selection {
        RetentionPreview.Selection(
            records: records, live: { live[$0] }, retention: retention, bundleID: Fixture.thisBuild, now: now, calendar: Fixture.calendar,
        )
    }

    private func preview(
        _ records: [MeetingFileRecord], live: [UUID: LiveMeetingState] = [:], retention: RecordingRetention = .days30,
        now: Date = Fixture.longAfter, onDisk: (MeetingFile) -> FileOnDisk = { _ in .present(bytes: 100) },
    ) -> RetentionPreview {
        RetentionPreview(selection(records, live: live, retention: retention, now: now), onDisk: onDisk)
    }

    private func days(_ count: Int, after date: Date) -> Date {
        Fixture.calendar.date(byAdding: .day, value: count, to: date) ?? date
    }

    /// A meeting in each state the rule tells apart.
    private func recordsInEveryState() -> [MeetingFileRecord] {
        [
            Fixture.record(),
            Fixture.record { $0.keep = true },
            Fixture.record(origin: .imported, recordingDate: nil),
            Fixture.record(outcome: .failed),
            Fixture.record(outcome: .leftUnfinished),
            Fixture.record(outcome: .inProgress),
            Fixture.record(outcome: .finished(protocolExpected: false)) { $0.setFiles(.protocol, to: nil) },
            Fixture.record { $0.setFiles(.protocol, to: nil) },
            Fixture.record { $0.excludedFromAutomaticDeletion = true },
            Fixture.record { $0.setAudio(to: .gone) },
            Fixture.record(recordingDate: nil),
            Fixture.record { $0.createdBy = Fixture.otherBuild },
            Fixture.record { $0.createdBy = nil },
        ]
    }

    // MARK: - The rule's answer

    func testEachValueCountsAMeetingFromItsDueDateOn() {
        let cases: [(RecordingRetention, Int)] = [(.afterProtocol, 0), (.days7, 7), (.days30, 30), (.days90, 90)]
        for (retention, count) in cases {
            let due = days(count, after: Fixture.recorded)
            let early = preview([Fixture.record()], retention: retention, now: due.addingTimeInterval(-1))
            let onTheDot = preview([Fixture.record()], retention: retention, now: due)

            XCTAssertEqual(early.meetingCount, 0, "\(retention) a second early")
            XCTAssertEqual(onTheDot.meetingCount, 1, "\(retention) on the dot")
            XCTAssertEqual(onTheDot.bytes, 300, "\(retention): three tracks")
            XCTAssertEqual(onTheDot.retention, retention)
        }
        XCTAssertTrue(preview([Fixture.record()], retention: .never).isEmpty)
    }

    /// What the preview promises and what the check's rule selects are one answer, for
    /// every state and value, also when the clock has not reached the due date.
    func testThePreviewSelectsExactlyWhatTheRuleDeletes() {
        let records = recordsInEveryState()
        let running = records[0].jobID
        let live = [running: LiveMeetingState(state: .done, notionExportRunning: true)]
        for retention in RecordingRetention.allCases {
            for now in [Fixture.recorded, days(8, after: Fixture.recorded), Fixture.longAfter] {
                for queue in [[:], live] {
                    let expected = records.map { record in
                        RecordingRetentionRule.audioToDelete(
                            record: record, live: queue[record.jobID], retention: retention, now: now, calendar: Fixture.calendar,
                            bundleID: Fixture.thisBuild,
                        )
                    }.filter { !$0.isEmpty }

                    XCTAssertEqual(selection(records, live: queue, retention: retention, now: now).meetings, expected, "\(retention) at \(now)")
                }
            }
        }
    }

    func testEverySkipReasonLeavesTheMeetingOutAndIsCounted() {
        typealias Skipped = RetentionPreview.Skipped
        let plain = Fixture.record()
        let cases: [(String, MeetingFileRecord, [UUID: LiveMeetingState], Skipped)] = [
            ("kept", Fixture.record { $0.keep = true }, [:], Skipped(kept: 1)),
            ("imported", Fixture.record(origin: .imported, recordingDate: nil), [:], Skipped(imported: 1)),
            ("failed", Fixture.record(outcome: .failed), [:], Skipped(failed: 1)),
            ("from before", Fixture.record { $0.excludedFromAutomaticDeletion = true }, [:], Skipped(fromBeforeThisFeature: 1)),
        ]
        for (name, record, live, skipped) in cases {
            let result = preview([record, plain], live: live)

            XCTAssertEqual(result.meetingCount, 1, "\(name): only the plain meeting")
            XCTAssertEqual(result.skipped, skipped, name)
        }
        // Finished as far as the record knows, and the queue says it failed since.
        let failedAgain = Fixture.record()
        let queue = [failedAgain.jobID: LiveMeetingState(state: .error, notionExportRunning: false)]
        XCTAssertEqual(preview([failedAgain], live: queue).skipped, Skipped(failed: 1))
        XCTAssertTrue(preview([failedAgain], live: queue).isEmpty)
    }

    /// A skip says something about audio that exists. A meeting whose audio already
    /// went has nothing to skip.
    func testAMeetingWithoutAudioLeftIsNoSkip() {
        let result = preview([
            Fixture.record { record in
                record.keep = true
                record.setAudio(to: .gone)
            },
        ])

        XCTAssertEqual(result.skipped, RetentionPreview.Skipped())
    }

    /// Each waits for something and is judged again later, so it is neither counted now
    /// nor among what the setting skips.
    func testAMeetingThatHasToWaitIsNeitherCountedNorSkipped() {
        let exporting = Fixture.record()
        let naming = Fixture.record()
        let running = Fixture.record()
        let cases: [(String, MeetingFileRecord, LiveMeetingState?)] = [
            ("Notion export running", exporting, LiveMeetingState(state: .done, notionExportRunning: true)),
            ("speakers not named", naming, LiveMeetingState(state: .speakerNamingPending, notionExportRunning: false)),
            ("in the queue", running, LiveMeetingState(state: .transcribing, notionExportRunning: false)),
            ("no notes saved", Fixture.record { $0.setFiles(.protocol, to: nil) }, nil),
            ("still in progress", Fixture.record(outcome: .inProgress), nil),
            ("left the queue", Fixture.record(outcome: .leftUnfinished), nil),
            ("a deletion under way", Fixture.record { $0.pending = .init(kind: .audioToTrash, paths: []) }, nil),
            ("a deletion left incomplete", Fixture.record { $0.incomplete = .init(reason: "x", paths: [], kind: .audioToTrash) }, nil),
        ]
        for (name, record, live) in cases {
            let queue = live.map { [record.jobID: $0] } ?? [:]
            let result = preview([record], live: queue)

            XCTAssertTrue(result.isEmpty, name)
            XCTAssertEqual(result.skipped, RetentionPreview.Skipped(), name)
        }
    }

    /// The rule settles most on the record alone and asking the queue can read a file,
    /// so it is asked only about a meeting that could go.
    func testTheQueueIsAskedOnlyAboutAMeetingTheRecordWouldLetGo() {
        let plain = Fixture.record()
        var asked: [UUID] = []

        _ = RetentionPreview.Selection(
            records: [plain, Fixture.record { $0.keep = true }, Fixture.record(outcome: .failed)],
            live: { id in
                asked.append(id)
                return nil
            },
            retention: .days30, bundleID: Fixture.thisBuild, now: Fixture.longAfter, calendar: Fixture.calendar,
        )

        XCTAssertEqual(asked, [plain.jobID])
    }

    // MARK: - What the disk answered

    func testTheDiskAnswerDecidesWhatCountsAndItsSize() {
        let record = Fixture.record()
        let mix = record.files[0].path
        let cases: [(String, (MeetingFile) -> FileOnDisk, expected: (count: Int, bytes: Int64, unreachable: Int))] = [
            ("all there", { _ in .present(bytes: 100) }, (1, 300, 0)),
            ("one removed by hand", { $0.path == mix ? .gone : .present(bytes: 100) }, (1, 200, 0)),
            ("all removed by hand", { _ in .gone }, (0, 0, 0)),
            ("one out of reach", { $0.path == mix ? .unreachable : .present(bytes: 100) }, (1, 200, 1)),
            ("all out of reach", { _ in .unreachable }, (1, 0, 3)),
            ("one out of reach, the rest removed", { $0.path == mix ? .unreachable : .gone }, (1, 0, 1)),
        ]
        for (name, onDisk, expected) in cases {
            let result = preview([record], onDisk: onDisk)

            XCTAssertEqual(result.meetingCount, expected.count, name)
            XCTAssertEqual(result.bytes, expected.bytes, name)
            XCTAssertEqual(result.unreachableFiles, expected.unreachable, name)
        }
    }

    func testAPathTwoMeetingsListIsCountedOnce() {
        let shared = Fixture.file(.mix, "shared.wav")
        let records = (0 ..< 2).map { _ in Fixture.record { $0.files = [shared, Fixture.file(.protocol, "n.md")] } }

        let result = preview(records)

        XCTAssertEqual(result.meetingCount, 2)
        XCTAssertEqual(result.bytes, 100)
    }

    func testNoRecordsAffectNothing() {
        let result = preview([])

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.meetingCount, 0)
    }

    // MARK: - The texts

    func testTheTextsSayTheCountTheSizeAndTheValue() {
        let goes = "It is deleted for good within the next minute. Transcripts and meeting notes stay."
        let cases: [(RecordingRetention, count: Int, first: String)] = [
            (.days30, 14, "With “After 30 days”, 14 meetings recorded more than 30 days ago still have their audio (420 MB). \(goes)"),
            (.days7, 14, "With “After 7 days”, 14 meetings recorded more than 7 days ago still have their audio (420 MB). \(goes)"),
            (.days90, 1, "With “After 90 days”, 1 meeting recorded more than 90 days ago still has its audio (30 MB). \(goes)"),
            (.afterProtocol, 14, "With “Right after the notes”, 14 finished meetings still have their audio (420 MB). \(goes)"),
            (.afterProtocol, 1, "With “Right after the notes”, 1 finished meeting still has its audio (30 MB). \(goes)"),
        ]
        for (retention, count, first) in cases {
            let records = (0 ..< count).map { _ in
                Fixture.record { record in
                    record.files = record.files.map { file in
                        var unique = file
                        unique.path += "-\(record.jobID)"
                        return unique
                    }
                }
            }
            let result = preview(records, retention: retention) { _ in .present(bytes: 10_000_000) }

            XCTAssertEqual(result.title, count == 1 ? "Delete the audio of 1 meeting?" : "Delete the audio of \(count) meetings?")
            XCTAssertEqual(result.message, first + "\n\n" + skipLine)
            XCTAssertEqual(result.confirmButton, count == 1 ? "Delete Audio of 1 Meeting" : "Delete Audio of \(count) Meetings")
        }
    }

    /// Audio out of reach is still in the count, and it does not go within the minute.
    func testTheTextSaysWhatIsOutOfReach() {
        let record = Fixture.record()
        let mix = record.files[0].path
        let partly = preview([record]) { $0.path == mix ? .unreachable : .present(bytes: 15_000_000) }
        let wholly = preview([record]) { _ in .unreachable }

        XCTAssertEqual(
            partly.message,
            "With “After 30 days”, 1 meeting recorded more than 30 days ago still has its audio (at least 30 MB). "
                + "It is deleted for good within the next minute, and what is on a drive that is not connected once that drive is back. "
                + "Transcripts and meeting notes stay.\n\n" + skipLine,
        )
        XCTAssertEqual(
            wholly.message,
            "With “After 30 days”, 1 meeting recorded more than 30 days ago still has its audio, on a drive that is not connected. "
                + "It is deleted for good once that drive is back. Transcripts and meeting notes stay.\n\n" + skipLine,
        )
    }

    // MARK: - Which value asks

    func testValuesAreOrderedByHowSoonTheyDelete() {
        let soonestFirst: [RecordingRetention] = [.afterProtocol, .days7, .days30, .days90, .never]
        XCTAssertEqual(Set(soonestFirst).count, RecordingRetention.allCases.count, "every value is in the order")
        for (first, earlier) in soonestFirst.enumerated() {
            for (second, later) in soonestFirst.enumerated() {
                XCTAssertEqual(earlier.deletesSooner(than: later), first < second, "\(earlier) against \(later)")
            }
        }
    }

    // MARK: - The controller, on real files

    /// The bed's controller with this task's two seams in the test's hands.
    private func controller(
        _ bed: RetentionCheckBed, settingChangeDelay: Duration = RecordingRetentionController.settingChangeDelay,
        readFile: @escaping @Sendable (String) -> FileOnDisk = FileOnDisk.read,
    ) -> RecordingRetentionController {
        RecordingRetentionController(
            settings: bed.settings,
            store: bed.store,
            remover: MeetingFileRemover { url in
                XCTFail("the automatic check moved \(url.lastPathComponent) to the Trash")
            },
            liveState: { bed.live[$0] },
            isListed: { bed.listed.contains($0) },
            securityScope: bed.harness.scopes.access,
            calendar: bed.calendar,
            now: { bed.clock },
            settingChangeDelay: settingChangeDelay,
            readFile: readFile,
        )
    }

    /// The answer of a controller whose records and queue read, as they do here.
    private func told(by sut: RecordingRetentionController) async throws -> RetentionPreview {
        let answer = await sut.preview(for: .days30)
        return try XCTUnwrap(answer)
    }

    private func audioBytes(of records: [MeetingFileRecord], in bed: RetentionCheckBed) throws -> Int64 {
        try records.flatMap(bed.audioPaths).reduce(0) { total, path in
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
            return try total + XCTUnwrap(size)
        }
    }

    /// Counted and measured from the disk, changing nothing there, and the check that
    /// follows the confirmation deletes exactly what was counted.
    func testThePreviewCountsWhatTheCheckThenDeletes() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        bed.clock = days(31, after: Fixture.recorded)
        let due = try [bed.meeting(), bed.meeting()]
        let held = try [
            bed.meeting { $0.keep = true },
            bed.meeting(outcome: .failed),
            bed.meeting(origin: .imported, recorded: nil),
            bed.meeting(recorded: days(30, after: Fixture.recorded)),
        ]
        let sut = controller(bed, settingChangeDelay: .milliseconds(1))

        let result = try await told(by: sut)

        XCTAssertEqual(result.meetingCount, 2)
        XCTAssertEqual(result.bytes, try audioBytes(of: due, in: bed))
        XCTAssertEqual(result.skipped, RetentionPreview.Skipped(kept: 1, failed: 1, imported: 1))
        XCTAssertEqual(bed.settings.recordingRetention, .never, "a preview is no decision")
        for record in due + held {
            try bed.assertUntouched(record, "after the preview")
        }

        sut.apply(.days30)

        await waitFor {
            !sut.isChecking && due.allSatisfy { record in bed.audioPaths(record).allSatisfy { !bed.isOnDisk($0) } }
        }
        for record in due {
            try bed.assertAudioWent(record)
        }
        for record in held {
            try bed.assertUntouched(record, "after the check")
        }
    }

    /// A drive that is not connected answers like a removed folder to a plain look, and
    /// the audio on it goes once the drive is back, so saying nothing would be wrong.
    func testAFolderOutOfReachIsNotNoAudio() async throws {
        let bed = try makeRetentionCheckBed()
        let drive = bed.harness.root.appendingPathComponent("drive", isDirectory: true)
        let record = try bed.meeting(audioFolder: drive)
        try FileManager.default.moveItem(at: drive, to: bed.harness.root.appendingPathComponent("unplugged", isDirectory: true))

        let result = try await told(by: controller(bed))

        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.meetingCount, 1)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.unreachableFiles, 6)
        XCTAssertEqual(try bed.current(record), record, "a file out of reach changes nothing")
    }

    func testAudioRemovedByHandIsNotCountedAndNotMarked() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        for path in bed.audioPaths(record) {
            try bed.removeBehindTheApp(path)
        }

        let result = try await told(by: controller(bed))

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(try bed.current(record), record, "only an action writes down what it found")
    }

    /// Other parts of the app write through a store of their own, and the check reads
    /// what they wrote, so the preview has to as well.
    func testAKeepWrittenThroughAnotherStoreCounts() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        let elsewhere = MeetingFileStore(path: bed.harness.root.appendingPathComponent("logs/meeting_files.json"))
        XCTAssertTrue(elsewhere.setKeep(true, jobID: record.jobID))

        let result = try await told(by: controller(bed))

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.skipped, RetentionPreview.Skipped(kept: 1))
    }

    /// Picking a value in Settings must not wait for a slow volume on the main actor.
    func testTheDiskIsReadOffTheMainActorAndTheWindowGoesOn() async throws {
        let bed = try makeRetentionCheckBed()
        try bed.meeting()
        let probe = BlockedRead()
        let sut = controller(bed) { _ in
            probe.enter()
            return .present(bytes: 7)
        }

        let answer = Task { await sut.preview(for: .days30) }
        await waitFor { probe.hasEntered }

        // This test runs on the main actor, and the read is still held.
        XCTAssertTrue(probe.hasEntered)
        XCTAssertFalse(probe.sawMainThread)
        probe.release()
        let result = await answer.value
        XCTAssertEqual(result?.bytes, 42)
    }

    func testTheChosenFoldersScopeIsOpenWhileTheDiskIsReadAndClosedAfter() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.setCustomOutputDir(bed.harness.outputDir)
        let root = try XCTUnwrap(bed.settings.customOutputDir, "test premise")
        try bed.meeting()
        let scopes = bed.harness.scopes
        let openDuringReads = LockedInts()
        let sut = controller(bed) { path in
            openDuringReads.append(scopes.opened.count - scopes.closed.count)
            return FileOnDisk.read(path)
        }

        let result = try await told(by: sut)

        XCTAssertEqual(result.meetingCount, 1)
        XCTAssertEqual(Set(openDuringReads.values), [1])
        XCTAssertEqual(scopes.opened.map(\.path), [root.path])
        XCTAssertEqual(scopes.closed.map(\.path), [root.path], "left open")
    }

    func testNothingToReadOpensNoScopeAndReadsNothing() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.setCustomOutputDir(bed.harness.outputDir)
        try bed.meeting { $0.keep = true }
        let reads = LockedInts()
        let sut = controller(bed) { _ in
            reads.append(1)
            return .gone
        }

        let result = try await told(by: sut)

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(reads.values, [])
        XCTAssertEqual(bed.harness.scopes.opened, [])
    }

    // MARK: - Applying

    /// Saved at once; the check comes after the delay, and that delay is inside the
    /// minute the preview promises (R12). That the check then comes is
    /// `testThePreviewCountsWhatTheCheckThenDeletes`.
    func testApplySavesAtOnceAndHoldsTheCheckBackForItsDelay() async throws {
        XCTAssertLessThan(RecordingRetentionController.settingChangeDelay, .seconds(60))
        XCTAssertGreaterThan(RecordingRetentionController.settingChangeDelay, .zero)
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        let record = try bed.meeting()
        let sut = controller(bed, settingChangeDelay: .seconds(3600))

        sut.apply(.days30)

        XCTAssertEqual(bed.settings.recordingRetention, .days30)
        try await Task.sleep(for: .milliseconds(30))
        try bed.assertUntouched(record)
    }

    /// The user can go back during the delay: the check obeys what is stored then.
    func testNeverChosenDuringTheDelayKeepsTheAudio() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        let record = try bed.meeting()
        let sut = controller(bed, settingChangeDelay: .milliseconds(20))

        sut.apply(.days30)
        bed.settings.recordingRetention = .never
        try await Task.sleep(for: .milliseconds(120))
        await sut.checkNow()

        try bed.assertUntouched(record)
    }
}

/// Holds a read until the test lets it go, and tells on which thread it ran.
private final class BlockedRead: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    private var onMainThread = false

    var hasEntered: Bool {
        lock.withLock { entered }
    }

    var sawMainThread: Bool {
        lock.withLock { onMainThread }
    }

    func enter() {
        lock.withLock {
            entered = true
            onMainThread = onMainThread || Thread.isMainThread
        }
        // Bounded, so a read wrongly on the main thread fails the test instead of
        // hanging it: the releasing test would never get to run.
        _ = gate.wait(timeout: .now() + 5)
    }

    func release() {
        // More than one file is read, and each waits here.
        for _ in 0 ..< 16 {
            gate.signal()
        }
    }
}

private final class LockedInts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    var values: [Int] {
        lock.withLock { stored }
    }

    func append(_ value: Int) {
        lock.withLock { stored.append(value) }
    }
}
