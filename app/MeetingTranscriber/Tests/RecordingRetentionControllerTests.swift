@testable import MeetingTranscriber
import XCTest

/// The automatic check (R11, R12, R14): every condition that keeps audio is tested
/// on its own, as this deletes for good with no way back. The rule's own decisions
/// are in `RecordingRetentionRuleTests`; this is what the check adds, on real files
/// in a temp folder, with a remover that only ever unlinks inside it.
@MainActor
final class RecordingRetentionControllerTests: XCTestCase {
    private typealias Fixture = RetentionFixture

    private func days(_ count: Int, after date: Date) -> Date {
        Fixture.calendar.date(byAdding: .day, value: count, to: date) ?? date
    }

    // MARK: - What goes and what stays

    func testNeverDeletesNothing() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        bed.clock = Fixture.longAfter
        let record = try bed.meeting()

        await bed.check()

        try bed.assertUntouched(record)
        XCTAssertEqual(bed.removed, [])
    }

    /// Tracks and 16 kHz copies go for good; transcript, protocol and the rest stay.
    func testAfterThirtyDaysAMeetingLosesItsAudioForGoodAndKeepsEverythingElse() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        bed.clock = days(31, after: Fixture.recorded)

        await bed.check()

        try bed.assertAudioWent(record)
        XCTAssertEqual(bed.removed.count, 6, "three tracks and three 16 kHz copies")
        XCTAssertEqual(try bed.current(record).files.filter { !$0.role.isAudio }.map(\.state), record.files.filter { !$0.role.isAudio }.map(\.state))
    }

    func testAMeetingKeepsItsAudioUntilTheClockPassesTheDueDate() async throws {
        let bed = try makeRetentionCheckBed()
        let cases: [(RecordingRetention, Int)] = [(.days7, 7), (.days30, 30), (.days90, 90)]
        for (retention, count) in cases {
            bed.settings.recordingRetention = retention
            let record = try bed.meeting()
            bed.clock = days(count - 1, after: Fixture.recorded)

            await bed.check()
            try bed.assertUntouched(record, "\(retention) a day early")

            bed.clock = days(count, after: Fixture.recorded)
            await bed.check()
            try bed.assertAudioWent(record, "\(retention) on the dot")
        }
    }

    func testRightAfterTheNotesDeletesAtOnce() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .afterProtocol
        let record = try bed.meeting()
        bed.clock = Fixture.recorded

        await bed.check()

        try bed.assertAudioWent(record)
    }

    /// Seven days cross the night the clocks go back, so seven calendar days are an
    /// hour longer than a week in Zurich and exactly a week at a fixed offset.
    func testTheDueDateComesFromTheInjectedCalendar() async throws {
        let recorded = Fixture.date(2026, 10, 20)
        let fixed: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600) ?? .gmt
            return calendar
        }()
        let between = recorded.addingTimeInterval(7 * 24 * 3600 + 1800)
        let cases: [(Calendar, Bool)] = [(Fixture.calendar, false), (fixed, true)]
        for (calendar, due) in cases {
            let bed = try makeRetentionCheckBed()
            bed.settings.recordingRetention = .days7
            bed.calendar = calendar
            bed.clock = between
            let record = try bed.meeting(recorded: recorded)

            await bed.check()

            if due { try bed.assertAudioWent(record, "\(calendar.timeZone)") } else { try bed.assertUntouched(record, "\(calendar.timeZone)") }
        }
    }

    /// The two builds share the record file, and a meeting of the other one counts.
    func testACheckGoesByWhatTheRecordFileSaysNow() async throws {
        let bed = try makeRetentionCheckBed()
        let otherBuild = MeetingFileStore(path: bed.harness.recordPath)
        let record = try bed.meeting(writtenBy: otherBuild)
        XCTAssertNil(bed.store.record(for: record.jobID), "test premise")

        await bed.check()

        try bed.assertAudioWent(record)
    }

    // MARK: - Meetings it never touches

    /// All in one pass, beside one that goes to show the pass ran.
    func testMeetingsTheCheckNeverTouches() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .afterProtocol
        bed.clock = Fixture.longAfter
        let otherProcess = DeletionProcess(pid: getpid(), launchTime: .distantPast)
        let manualFailure = MeetingFileRecord.DeletionFailure(reason: "refused", paths: [], kind: .audioToTrash)
        let records: [(String, MeetingFileRecord)] = try [
            ("import inside the recordings folder", bed.meeting(origin: .imported, recorded: nil)),
            ("import with a date", bed.meeting(origin: .imported)),
            ("failed", bed.meeting(outcome: .failed)),
            ("left the queue unfinished", bed.meeting(outcome: .leftUnfinished)),
            ("in progress", bed.meeting(outcome: .inProgress)),
            ("no recording date", bed.meeting(recorded: nil)),
            ("protocol failed, nothing listed", bed.meeting { $0.files.removeAll { $0.role == .protocol } }),
            ("protocol failed, marked gone", bed.meeting { $0.setFiles(.protocol, to: .gone) }),
            ("kept", bed.meeting { $0.keep = true }),
            ("recovered from before this feature", bed.meeting { $0.excludedFromAutomaticDeletion = true }),
            ("a manual deletion left unfinished", bed.meeting { $0.incomplete = manualFailure }),
            ("pending in another process", bed.meeting { record in
                record.pending = .init(kind: .automatic, paths: bed.audioPaths(record), process: otherProcess)
            }),
        ]
        let due = try bed.meeting()

        await bed.check()

        for (name, record) in records {
            try bed.assertUntouched(record, name)
        }
        try bed.assertAudioWent(due)
    }

    /// An import's copy is the app's to delete by hand, and no check ever does.
    func testAnImportIsNotTouchedAlsoWithSixteenKilohertzCopiesOfItsOwn() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .afterProtocol
        let record = try bed.meeting(origin: .imported)
        XCTAssertTrue(record.files.contains { $0.role == .mix16k && $0.owned }, "test premise")

        await bed.check()

        try bed.assertUntouched(record)
        XCTAssertEqual(bed.removed, [])
    }

    /// A file on disk with a row and no record: a record-only recording, or a meeting
    /// the record store never heard of. Paths come from records and nowhere else.
    func testAFileWithoutARecordIsNeverTouched() async throws {
        let bed = try makeRetentionCheckBed()
        let stray = bed.harness.recordings.appendingPathComponent("20261016_0900_stray_mix.wav")
        try Data("stray".utf8).write(to: stray)
        let due = try bed.meeting()

        await bed.check()

        XCTAssertTrue(bed.isOnDisk(stray.path))
        try bed.assertAudioWent(due)
    }

    func testAMeetingTheQueueIsNotThroughWithKeepsItsAudio() async throws {
        let bed = try makeRetentionCheckBed()
        let states: [(JobState, Bool)] = [
            (.waiting, false), (.transcribing, false), (.diarizing, false), (.generatingProtocol, false),
            (.speakerNamingPending, false), (.error, false), (.done, true),
        ]
        var records: [(LiveMeetingState, MeetingFileRecord)] = []
        for (state, exporting) in states {
            let record = try bed.meeting()
            let live = LiveMeetingState(state: state, notionExportRunning: exporting)
            bed.live[record.jobID] = live
            records.append((live, record))
        }

        await bed.check()

        for (live, record) in records {
            try bed.assertUntouched(record, "\(live)")
        }
        XCTAssertEqual(bed.removed, [])
    }

    // MARK: - Notes

    /// R11, A8, A9: a completed export or Markdown on disk counts as saved. A failed
    /// export without Markdown has none, also when it created its page first.
    func testNotionExportsDecideTheWayTheSpecSays() async throws {
        let bed = try makeRetentionCheckBed()
        let running = LiveMeetingState(state: .done, notionExportRunning: true)
        let finished = LiveMeetingState(state: .done, notionExportRunning: false)
        let cases: [(String, LiveMeetingState?, Bool, (inout MeetingFileRecord) -> Void)] = [
            ("running, with Markdown on disk", running, false, { _ in }),
            ("running, a re-export over a saved one", running, false, { $0.savedToNotion = true }),
            ("completed, Markdown removed", finished, true, { record in
                record.savedToNotion = true
                record.setFiles(.protocol, to: .gone)
            }),
            ("completed, Markdown removed, job gone", nil, true, { record in
                record.savedToNotion = true
                record.setFiles(.protocol, to: .gone)
            }),
            ("completed, Markdown on disk", finished, true, { $0.savedToNotion = true }),
            ("failed, Markdown on disk", finished, true, { _ in }),
            ("failed, no Markdown, page created", finished, false, { $0.setFiles(.protocol, to: .gone) }),
        ]
        var outcomes: [(String, Bool, MeetingFileRecord)] = []
        for (name, live, goes, change) in cases {
            let record = try bed.meeting(change)
            if let live { bed.live[record.jobID] = live }
            outcomes.append((name, goes, record))
        }

        await bed.check()

        for (name, goes, record) in outcomes {
            if goes { try bed.assertAudioWent(record, name) } else { try bed.assertUntouched(record, name) }
        }
    }

    /// "Saved" is what the disk answers, not what the record last marked: the notes
    /// are the only copy once the audio is gone.
    func testNotesRemovedBehindTheAppKeepTheAudioAndGetMarked() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()
        try bed.removeBehindTheApp(XCTUnwrap(record.files.first { $0.role == .protocol }?.path))

        await bed.check()
        await bed.check()

        XCTAssertEqual(bed.removed, [])
        let now = try bed.current(record)
        XCTAssertEqual(now.files.first { $0.role == .protocol }?.state, .gone)
        XCTAssertNil(now.audioDeletion)
        XCTAssertNil(now.pending)
        for path in bed.audioPaths(record) {
            XCTAssertTrue(bed.isOnDisk(path))
        }
    }

    /// One of two protocols is enough: a run into another folder lists both.
    func testOneOfTwoListedProtocolsOnDiskIsSaved() async throws {
        let bed = try makeRetentionCheckBed()
        let elsewhere = bed.harness.root.appendingPathComponent("earlier", isDirectory: true)
        let record = try bed.meeting { record in
            try record.files.append(bed.file(.protocol, "earlier.md", in: elsewhere))
        }
        try bed.removeBehindTheApp(XCTUnwrap(record.files.first { $0.role == .protocol }?.path))

        await bed.check()

        XCTAssertEqual(bed.removed.count, 6)
        XCTAssertNotNil(try bed.current(record).audioDeletion)
    }

    /// A1: with generation off, the transcript is what has to be saved.
    func testWithNotesOffTheTranscriptHasToBeOnDisk() async throws {
        let bed = try makeRetentionCheckBed()
        let notesOff = MeetingFileRecord.Outcome.finished(protocolExpected: false)
        let saved = try bed.meeting(outcome: notesOff) { $0.files.removeAll { $0.role == .protocol } }
        let removed = try bed.meeting(outcome: notesOff) { $0.files.removeAll { $0.role == .protocol } }
        let transcript = try XCTUnwrap(removed.files.first { $0.role == .transcript }?.path)
        try bed.removeBehindTheApp(transcript)

        await bed.check()
        await bed.check()

        try bed.assertAudioWent(saved)
        XCTAssertEqual(try bed.current(removed).files.first { $0.role == .transcript }?.state, .gone)
        XCTAssertNil(try bed.current(removed).audioDeletion)
        for path in bed.audioPaths(removed) {
            XCTAssertTrue(bed.isOnDisk(path), "the audio is the last copy of what was said")
        }
    }

    // MARK: - A change after selection

    /// Each changes the record from another build's store between the selection and
    /// the deletion, which the check must find when it reads the record again.
    func testARecordChangedAfterSelectionIsSkipped() async throws {
        let bed = try makeRetentionCheckBed()
        let otherBuild = MeetingFileStore(path: bed.harness.recordPath)
        let extra = try bed.file(.previousProtocol, "another.md")
        let cases: [(String, (inout MeetingFileRecord) -> Void)] = [
            ("Keep", { $0.keep = true }),
            ("Retry", { $0.outcome = .inProgress }),
            ("failed", { $0.outcome = .failed }),
            ("a manual deletion started", { $0.pending = .init(kind: .audioToTrash, paths: []) }),
            ("a file was added", { $0.files.append(extra) }),
            ("export restarted", { $0.savedToNotion.toggle() }),
        ]
        for (name, change) in cases {
            let record = try bed.meeting()
            bed.onLiveLookup = { id, count in
                guard id == record.jobID, count == 1 else { return }
                otherBuild.reload()
                XCTAssertTrue(otherBuild.update(jobID: id, change), "test premise")
            }

            await bed.check()

            XCTAssertEqual(bed.removed, [], name)
            XCTAssertNil(try bed.current(record).audioDeletion, name)
            for path in bed.audioPaths(record) {
                XCTAssertTrue(bed.isOnDisk(path), name)
            }
            otherBuild.reload()
            otherBuild.update(jobID: record.jobID) { now in
                now.keep = true
                now.pending = nil
            }
            bed.onLiveLookup = { _, _ in }
        }
    }

    func testAMeetingWhoseQueueStateChangedAfterSelectionIsSkipped() async throws {
        let bed = try makeRetentionCheckBed()
        let changes: [(String, LiveMeetingState)] = [
            ("reopened naming", .init(state: .speakerNamingPending, notionExportRunning: false)),
            ("a Retry", .init(state: .waiting, notionExportRunning: false)),
            ("an export started", .init(state: .done, notionExportRunning: true)),
        ]
        for (name, changed) in changes {
            let record = try bed.meeting()
            bed.live[record.jobID] = .init(state: .done, notionExportRunning: false)
            // The first look is the selection, the next one the read before deleting.
            bed.onLiveLookup = { id, count in
                if id == record.jobID, count == 2 { bed.live[id] = changed }
            }

            await bed.check()

            try bed.assertUntouched(record, name)
            XCTAssertEqual(bed.removed, [], name)
            bed.onLiveLookup = { _, _ in }
        }
    }

    /// The setting changed while the check was on its way to the disk: Never wins at
    /// once, as a longer period does.
    func testASettingChangedAfterSelectionIsObeyed() async throws {
        let bed = try makeRetentionCheckBed()
        let changes: [RecordingRetention] = [.never, .days90]
        for changed in changes {
            bed.settings.recordingRetention = .days30
            let record = try bed.meeting()
            bed.onLiveLookup = { id, count in
                if id == record.jobID, count == 1 { bed.settings.recordingRetention = changed }
            }

            await bed.check()

            try bed.assertUntouched(record, "\(changed)")
            bed.onLiveLookup = { _, _ in }
            bed.store.update(jobID: record.jobID) { $0.keep = true }
        }
    }

    /// The last look happens under the store's lock, so a change landing right after
    /// the check's own read still stops the deletion before its mark is written.
    func testTheDeletionMarkIsRefusedForARecordThatChangedSinceItWasRead() throws {
        let bed = try makeRetentionCheckBed()
        let read = try bed.meeting()
        let otherBuild = MeetingFileStore(path: bed.harness.recordPath)
        otherBuild.update(jobID: read.jobID) { $0.keep = true }

        XCTAssertFalse(bed.store.beginDeletion(jobID: read.jobID, kind: .automatic, paths: bed.audioPaths(read), unchangedFrom: read))

        XCTAssertNil(try bed.current(read).pending)
        let fresh = try bed.current(read)
        XCTAssertTrue(bed.store.beginDeletion(jobID: read.jobID, kind: .automatic, paths: bed.audioPaths(read), unchangedFrom: fresh))
        XCTAssertNotNil(try bed.current(read).pending)
    }

    // MARK: - An interrupted deletion

    /// The launch reconcile clears what a crash left, and the next check finishes
    /// the rest. It does not date a deletion with files still to go.
    func testADeletionACrashInterruptedIsFinishedByTheNextCheck() async throws {
        let bed = try makeRetentionCheckBed()
        let dead = DeletionProcess(pid: getpid(), launchTime: .distantPast)
        let record = try bed.meeting()
        let audio = bed.audioPaths(record)
        try bed.removeBehindTheApp(audio[0])
        bed.store.update(jobID: record.jobID) { now in
            now.pending = .init(kind: .automatic, paths: audio, process: dead)
            for index in now.files.indices where now.files[index].path == audio[0] || now.files[index].path == audio[1] {
                now.files[index].state = .deleting
            }
        }

        bed.harness.controller().reconcileInterruptedDeletions { _ in false }

        let settled = try bed.current(record)
        XCTAssertNil(settled.pending)
        XCTAssertNil(settled.audioDeletion, "files are still to go")
        XCTAssertEqual(settled.files.filter(\.role.isAudio).map(\.state)[0 ... 1], [.gone, .present])

        await bed.check()

        try bed.assertAudioWent(record)
        XCTAssertEqual(bed.removed.count, audio.count - 1)
    }

    /// Another running build's deletion is not an abandoned one.
    func testADeletionOfAnotherLiveProcessSurvivesTheReconcileAndTheCheck() async throws {
        let bed = try makeRetentionCheckBed()
        let live = DeletionProcess(pid: getpid(), launchTime: .distantPast)
        let record = try bed.meeting { record in
            record.pending = .init(kind: .automatic, paths: bed.audioPaths(record), process: live)
        }

        bed.harness.controller().reconcileInterruptedDeletions { _ in true }
        await bed.check()

        try bed.assertUntouched(record)
    }
}
