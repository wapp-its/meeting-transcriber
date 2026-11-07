@testable import MeetingTranscriber
import XCTest

/// Dates and records for the pure decisions of a meeting's files: paths only, with
/// no file behind them, as those decisions never look at the disk.
enum RetentionFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt
        return calendar
    }()

    /// Reads "15 Nov".
    static let locale = Locale(identifier: "en_GB")
    /// The running build, which created every record here unless a test says otherwise.
    static let thisBuild = "com.example.meetingtranscriber.this"
    /// A second build sharing the record file, as the development and the release build do.
    static let otherBuild = "com.example.meetingtranscriber.other"
    static let recorded = date(2026, 10, 16)
    /// Long past every due date.
    static let longAfter = date(2027, 6, 1)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    static func file(_ role: MeetingFile.Role, _ name: String, owned: Bool = true, state: MeetingFile.State = .present) -> MeetingFile {
        MeetingFile(role: role, path: "/output/recordings/\(name)", identity: nil, owned: owned, state: state)
    }

    /// A finished meeting with notes on disk: for a recording three tracks of its
    /// own, for an import the user's source, plus a transcript and a protocol.
    static func record(
        origin: MeetingFileRecord.Origin = .recorded,
        recordingDate: Date? = recorded,
        outcome: MeetingFileRecord.Outcome = .finished(protocolExpected: true),
        _ change: (inout MeetingFileRecord) -> Void = { _ in },
    ) -> MeetingFileRecord {
        let tracks = origin == .recorded
            ? [file(.mix, "b_mix.wav"), file(.appTrack, "b_app.wav"), file(.micTrack, "b_mic.wav")]
            : [file(.mix, "source.wav", owned: false)]
        var record = MeetingFileRecord(
            jobID: UUID(), origin: origin, recordingDate: recordingDate,
            files: tracks + [file(.transcript, "b.txt"), file(.protocol, "b.md")], outcome: outcome, createdBy: thisBuild,
        )
        change(&record)
        return record
    }
}

extension MeetingFileRecord {
    /// Set the state of every file in `role`, or take them out of the record with nil.
    mutating func setFiles(_ role: MeetingFile.Role, to state: MeetingFile.State?) {
        guard let state else {
            files.removeAll { $0.role == role }
            return
        }
        for index in files.indices where files[index].role == role {
            files[index].state = state
        }
    }

    mutating func setAudio(to state: MeetingFile.State) {
        for index in files.indices where files[index].role.isAudio {
            files[index].state = state
        }
    }
}

/// When a meeting's audio is due, and what the automatic check deletes now (R11).
final class RecordingRetentionRuleTests: XCTestCase {
    private typealias Fixture = RetentionFixture
    private let everyAudioFile = ["b_mix.wav", "b_app.wav", "b_mic.wav"]
    private let incomplete = MeetingFileRecord.DeletionFailure(reason: "r", paths: [], kind: .audioToTrash)

    private func audio(
        _ record: MeetingFileRecord, live: LiveMeetingState? = nil, retention: RecordingRetention = .days30,
        now: Date = RetentionFixture.longAfter, bundleID: String? = RetentionFixture.thisBuild,
    ) -> [String] {
        RecordingRetentionRule.audioToDelete(
            record: record, live: live, retention: retention, now: now, calendar: Fixture.calendar, bundleID: bundleID,
        ).map { URL(filePath: $0.path).lastPathComponent }
    }

    private func due(_ record: MeetingFileRecord, _ retention: RecordingRetention, bundleID: String? = RetentionFixture.thisBuild) -> Date? {
        RecordingRetentionRule.dueDate(record: record, retention: retention, calendar: Fixture.calendar, bundleID: bundleID)
    }

    // MARK: - The setting's values

    func testEachValueHasItsTitleAndItsDays() {
        let rows: [(RecordingRetention, String, Int?)] = [
            (.never, "Never", nil),
            (.afterProtocol, "Right after the notes", nil),
            (.days7, "After 7 days", 7),
            (.days30, "After 30 days", 30),
            (.days90, "After 90 days", 90),
        ]
        XCTAssertEqual(rows.map(\.0), RecordingRetention.allCases, "the picker lists them in this order")
        for (retention, title, days) in rows {
            XCTAssertEqual(retention.title, title)
            XCTAssertEqual(retention.days, days, "\(retention)")
        }
    }

    // MARK: - Due date

    func testNothingIsDueUnderNeverForAnImportAKeptMeetingOrWithoutARecordingDate() {
        let finished = Fixture.record()
        XCTAssertNil(due(finished, .never))
        for retention in RecordingRetention.allCases {
            XCTAssertNil(due(Fixture.record(origin: .imported), retention), "import, \(retention)")
            XCTAssertNil(due(Fixture.record { $0.keep = true }, retention), "kept, \(retention)")
            XCTAssertNil(due(Fixture.record(recordingDate: nil), retention), "no date, \(retention)")
            XCTAssertNil(due(Fixture.record { $0.excludedFromAutomaticDeletion = true }, retention), "excluded, \(retention)")
        }
    }

    /// In the calendar, not in seconds: 30 days from 16 Oct cross the end of
    /// summer time and still land at the same hour of the day.
    func testTheDueDateCountsFromTheRecordingDateInTheCalendar() {
        let record = Fixture.record()
        XCTAssertEqual(due(record, .afterProtocol), Fixture.recorded)
        XCTAssertEqual(due(record, .days7), Fixture.date(2026, 10, 23))
        XCTAssertEqual(due(record, .days30), Fixture.date(2026, 11, 15))
        XCTAssertEqual(due(record, .days90), Fixture.date(2027, 1, 14))
    }

    // MARK: - What it returns

    func testAFinishedMeetingThatIsDueLosesItsAudioAndNothingElse() {
        XCTAssertEqual(audio(Fixture.record()), everyAudioFile)
    }

    /// Any role can list several files. Each path counts once, and one the record
    /// also lists as not owned stays out: it is the user's.
    func testItReturnsEachOwnedAudioFileStillMarkedPresentOnce() {
        let record = Fixture.record { record in
            record.files = [
                Fixture.file(.mix, "mix.wav"),
                Fixture.file(.mix, "mix-other-folder.wav"),
                Fixture.file(.appTrack, "app.wav", state: .gone),
                Fixture.file(.micTrack, "mic.wav", state: .deleting),
                Fixture.file(.mix16k, "mix16k.wav"),
                Fixture.file(.app16k, "mix16k.wav"),
                Fixture.file(.mic16k, "users.wav"),
                Fixture.file(.micTrack, "users.wav", owned: false),
                Fixture.file(.segments, "b.segments.json"),
                Fixture.file(.naming, "b.naming.json"),
                Fixture.file(.transcript, "b.txt"),
                Fixture.file(.protocol, "b.md"),
                Fixture.file(.previousProtocol, "b.previous.md"),
            ]
        }
        XCTAssertEqual(audio(record), ["mix.wav", "mix-other-folder.wav", "mix16k.wav"])
    }

    // MARK: - R11's error list

    func testEveryCaseOfTheErrorListReturnsNothing() {
        let rows: [(String, MeetingFileRecord)] = [
            ("still in progress", Fixture.record(outcome: .inProgress)),
            ("failed", Fixture.record(outcome: .failed)),
            ("left the queue unfinished", Fixture.record(outcome: .leftUnfinished)),
            ("the protocol failed, no file listed", Fixture.record { $0.setFiles(.protocol, to: nil) }),
            ("the protocol is gone", Fixture.record { $0.setFiles(.protocol, to: .gone) }),
            ("the protocol is being deleted", Fixture.record { $0.setFiles(.protocol, to: .deleting) }),
            ("kept", Fixture.record { $0.keep = true }),
            ("from before this feature", Fixture.record { $0.excludedFromAutomaticDeletion = true }),
            ("a deletion is incomplete", Fixture.record { $0.incomplete = self.incomplete }),
            ("a deletion is pending", Fixture.record { $0.pending = .init(kind: .automatic, paths: []) }),
            ("no recording date", Fixture.record(recordingDate: nil)),
            ("an import, with an owned copy of the app's", Fixture.record(origin: .imported) { record in
                record.files.append(Fixture.file(.mix16k, "source_16k.wav"))
            }),
            ("no audio left", Fixture.record { $0.setAudio(to: .gone) }),
        ]
        for (name, record) in rows {
            for retention in RecordingRetention.allCases {
                XCTAssertEqual(audio(record, retention: retention), [], "\(name), \(retention)")
            }
        }
    }

    // MARK: - The build that recorded it

    /// The development and the release build share the record file, each with a
    /// setting of its own: one build's setting never reaches the other's meetings,
    /// nor a record from before the field, nor anything when the build has no
    /// identifier. Due under this build's identifier, so only that one differs.
    func testOnlyTheBuildThatCreatedTheRecordDeletesItsAudio() {
        XCTAssertEqual(audio(Fixture.record()), everyAudioFile, "test premise: this build's own meeting goes")
        let rows: [(String, MeetingFileRecord, String?)] = [
            ("another build's meeting", Fixture.record { $0.createdBy = Fixture.otherBuild }, Fixture.thisBuild),
            ("a record from before the field", Fixture.record { $0.createdBy = nil }, Fixture.thisBuild),
            ("a build without an identifier", Fixture.record { $0.createdBy = nil }, nil),
        ]
        for (name, record, bundleID) in rows {
            XCTAssertFalse(RecordingRetentionRule.recordAllowsDeletion(record, bundleID: bundleID), name)
            for retention in RecordingRetention.allCases {
                XCTAssertNil(due(record, retention, bundleID: bundleID), "\(name), \(retention)")
                XCTAssertEqual(audio(record, retention: retention, bundleID: bundleID), [], "\(name), \(retention)")
            }
        }
        let theOthers = Fixture.record { $0.createdBy = Fixture.otherBuild }
        XCTAssertEqual(audio(theOthers, bundleID: Fixture.otherBuild), everyAudioFile, "the other build deletes its own")
    }

    // MARK: - Saved protocol

    func testAProtocolCountsAsSavedOnDiskInNotionOrWhenGenerationWasOff() {
        let rows: [(String, MeetingFileRecord)] = [
            ("a failed export with its Markdown on disk", Fixture.record()),
            ("a completed export whose local file was removed", Fixture.record { record in
                record.savedToNotion = true
                record.setFiles(.protocol, to: .gone)
            }),
            ("generation off (A1)", Fixture.record(outcome: .finished(protocolExpected: false)) { record in
                record.setFiles(.protocol, to: nil)
            }),
        ]
        for (name, record) in rows {
            XCTAssertEqual(audio(record, live: LiveMeetingState(state: .done, notionExportRunning: false)), everyAudioFile, name)
        }
    }

    /// A1: with generation off, the transcript is what has to be saved, as the record
    /// marks it. The check would keep the audio without one, so the rule must not
    /// select the meeting, or the row and the preview promise what never happens.
    func testWithNotesOffOnlyATranscriptMarkedPresentCountsAsSaved() {
        let notesOff = MeetingFileRecord.Outcome.finished(protocolExpected: false)
        let saved = Fixture.record(outcome: notesOff) { $0.setFiles(.protocol, to: nil) }
        XCTAssertEqual(audio(saved), everyAudioFile, "test premise: a transcript marked present is saved")
        let rows: [(String, MeetingFile.State?)] = [
            ("no transcript listed", nil), ("the transcript is gone", .gone), ("the transcript is being deleted", .deleting),
        ]
        for (name, state) in rows {
            let record = Fixture.record(outcome: notesOff) { record in
                record.setFiles(.protocol, to: nil)
                record.setFiles(.transcript, to: state)
            }
            XCTAssertFalse(RecordingRetentionRule.recordAllowsDeletion(record, bundleID: Fixture.thisBuild), name)
            for retention in RecordingRetention.allCases {
                XCTAssertEqual(audio(record, retention: retention), [], "\(name), \(retention)")
            }
        }
    }

    /// The page that export created before it failed holds only part of the notes.
    func testAFailedExportWithoutItsMarkdownHasNoProtocolSaved() {
        let record = Fixture.record { $0.setFiles(.protocol, to: .gone) }
        XCTAssertEqual(audio(record, live: LiveMeetingState(state: .done, notionExportRunning: false)), [])
    }

    // MARK: - The queue's view of the job

    /// A queue that no longer lists the job leaves the record to decide; one that
    /// lists it has to be through with it.
    func testOnlyADoneJobWithNoExportRunningLosesItsAudio() {
        XCTAssertEqual(audio(Fixture.record(), live: nil), everyAudioFile)
        let rows: [(JobState, [String])] = [
            (.waiting, []), (.transcribing, []), (.diarizing, []), (.generatingProtocol, []),
            (.speakerNamingPending, []), (.error, []), (.done, everyAudioFile),
        ]
        for (state, expected) in rows {
            XCTAssertEqual(audio(Fixture.record(), live: LiveMeetingState(state: state, notionExportRunning: false)), expected, "\(state)")
        }
    }

    /// The Markdown is on disk and still the meeting waits (A9).
    func testAnExportRunningHoldsTheAudioBackAlsoWithItsMarkdownOnDisk() {
        XCTAssertEqual(audio(Fixture.record(), live: LiveMeetingState(state: .done, notionExportRunning: true)), [])
    }

    // MARK: - Each value's boundary

    func testEachValueDeletesFromItsDueDateOnAndNotASecondBefore() {
        let rows: [(RecordingRetention, Date)] = [
            (.afterProtocol, Fixture.recorded),
            (.days7, Fixture.date(2026, 10, 23)),
            (.days30, Fixture.date(2026, 11, 15)),
            (.days90, Fixture.date(2027, 1, 14)),
        ]
        for (retention, dueDate) in rows {
            let record = Fixture.record()
            XCTAssertEqual(audio(record, retention: retention, now: dueDate.addingTimeInterval(-1)), [], "\(retention), before")
            XCTAssertEqual(audio(record, retention: retention, now: dueDate), everyAudioFile, "\(retention), at")
            XCTAssertEqual(audio(record, retention: retention, now: dueDate.addingTimeInterval(1)), everyAudioFile, "\(retention), after")
        }
        XCTAssertEqual(audio(Fixture.record(), retention: .never), [], "Never deletes nothing")
    }
}
