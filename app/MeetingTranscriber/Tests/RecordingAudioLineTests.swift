@testable import MeetingTranscriber
import XCTest

/// The row's audio line and Keep badge for every meeting state (R2), and what an
/// incomplete deletion shows (R5, R6). A meeting recorded on 16 Oct, read on 1 Nov.
final class RecordingAudioLineTests: XCTestCase {
    private typealias Fixture = RetentionFixture
    private typealias AudioOnDisk = RecordingAudioLine.AudioOnDisk

    private let beforeDue = RetentionFixture.date(2026, 11, 1)
    /// All three files present.
    private let mb286 = AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 286_000_000)
    private let nothingLeft = AudioOnDisk(presentCount: 0, unreachableCount: 0, totalCount: 3, bytes: 0)
    private let unplugged = AudioOnDisk(presentCount: 0, unreachableCount: 3, totalCount: 3, bytes: 0)
    /// The decimal separator is the machine's, as `ByteCountFormatter` has no locale.
    private let gb1point1 = ByteCountFormatter.string(fromByteCount: 1_100_000_000, countStyle: .file)

    private static let after30Days = RecordingRetentionSettings(enabled: true, days: 30)
    private static let off = RecordingRetentionSettings(enabled: false, days: 30)
    private static let rightAfterTheNotes = RecordingRetentionSettings(enabled: true, days: 0)
    private static let everySetting = [after30Days, off, rightAfterTheNotes]

    /// How this build's retention registry lists the meeting.
    private enum Listing {
        /// Relocated here, and its notes are written.
        case eligible
        /// Relocated here, with no notes written yet.
        case awaitingNotes
        /// Not at all: an import, a record-only recording, another build's meeting
        /// or one from before the registry.
        case unlisted
    }

    private func line(
        _ record: MeetingFileRecord?, live: LiveMeetingState? = nil, audio: AudioOnDisk? = nil,
        retention: RecordingRetentionSettings = after30Days, listed: Listing = .eligible, now: Date? = nil,
        calendar: Calendar = RetentionFixture.calendar, locale: Locale = RetentionFixture.locale,
    ) -> RecordingAudioLine {
        let retained: RetainedRecording? = switch listed {
        case .unlisted:
            nil

        case .eligible, .awaitingNotes:
            RetainedRecording(
                jobID: record?.jobID ?? UUID(), paths: [], root: URL(fileURLWithPath: "/output"),
                recordedAt: Fixture.recorded, eligibleAt: listed == .eligible ? Fixture.recorded : nil, outputPath: nil,
            )
        }
        return RecordingAudioLine.resolve(
            record: record, live: live, audio: audio ?? mb286, retention: retention, retained: retained,
            bundleID: Fixture.thisBuild, now: now ?? beforeDue, calendar: calendar, locale: locale,
        )
    }

    private func live(_ state: JobState, exporting: Bool = false) -> LiveMeetingState {
        LiveMeetingState(state: state, notionExportRunning: exporting)
    }

    // MARK: - No line

    func testARowWithoutARecordShowsNothing() {
        XCTAssertEqual(
            line(nil, live: live(.done)),
            RecordingAudioLine(text: nil, showsKeepBadge: false, incompleteText: nil),
        )
    }

    func testAMeetingStillBeingProcessedShowsNoLine() {
        for state in [JobState.waiting, .transcribing, .diarizing, .generatingProtocol] {
            XCTAssertNil(line(Fixture.record(outcome: .inProgress), live: live(state)).text, "\(state)")
        }
        XCTAssertNil(line(Fixture.record(outcome: .inProgress)).text, "another build's run")
        XCTAssertNil(line(Fixture.record(outcome: .inProgress), live: live(.done)).text, "no outcome on the record yet")
    }

    // MARK: - R2's lines

    func testWhileNamingIsOpenTheAudioIsKeptUntilTheSpeakersAreNamed() {
        let audio = AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 412_000_000)
        for retention in Self.everySetting {
            XCTAssertEqual(
                line(Fixture.record(outcome: .inProgress), live: live(.speakerNamingPending), audio: audio, retention: retention).text,
                "Audio · 412 MB · kept until the speakers are named", "\(retention)",
            )
        }
    }

    func testAMeetingThatIsDueLaterNamesItsDate() {
        XCTAssertEqual(line(Fixture.record()).text, "Audio · 286 MB · deleted automatically on 15 Nov")
        XCTAssertEqual(line(Fixture.record(), live: live(.done)).text, "Audio · 286 MB · deleted automatically on 15 Nov")
    }

    func testADatePassedOrReachedReadsAsTheNextCheck() {
        let passed = "Audio · 286 MB · deleted automatically at the next check"
        XCTAssertEqual(line(Fixture.record(), now: Fixture.date(2026, 11, 15)).text, passed, "at the due date")
        XCTAssertEqual(line(Fixture.record(), now: Fixture.longAfter).text, passed)
        XCTAssertEqual(line(Fixture.record(), retention: Self.rightAfterTheNotes).text, passed, "right after the notes")
    }

    func testAKeptMeetingIsKeptInEveryStateAndCarriesTheBadge() {
        let audio = AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 1_100_000_000)
        let kept = Fixture.record { $0.keep = true }
        let expected = "Audio · \(gb1point1) · kept, never deleted automatically"
        let rows: [(LiveMeetingState?, RecordingRetentionSettings)] = [
            (nil, Self.after30Days), (nil, Self.off), (live(.speakerNamingPending), Self.after30Days), (live(.error), Self.after30Days),
            (live(.done, exporting: true), Self.after30Days),
        ]
        for (live, retention) in rows {
            let line = line(kept, live: live, audio: audio, retention: retention)
            XCTAssertEqual(line.text, expected, "\(String(describing: live)), \(retention)")
            XCTAssertTrue(line.showsKeepBadge)
        }
        XCTAssertFalse(self.line(Fixture.record()).showsKeepBadge)
    }

    /// True in every state and whatever is on disk, unlike a line about waiting.
    func testAnImportIsTheUsersFileInEveryState() {
        let expected = "Audio · your imported file, never deleted by the app"
        let rows: [(LiveMeetingState?, AudioOnDisk)] = [
            (nil, mb286), (nil, nothingLeft), (nil, unplugged), (live(.speakerNamingPending), mb286), (live(.error), mb286),
        ]
        for (live, audio) in rows {
            for retention in Self.everySetting {
                let line = line(Fixture.record(origin: .imported), live: live, audio: audio, retention: retention, listed: .unlisted)
                XCTAssertEqual(line.text, expected, "\(String(describing: live)), \(audio), \(retention)")
                XCTAssertFalse(line.showsKeepBadge)
            }
        }
        XCTAssertNil(line(Fixture.record(origin: .imported), live: live(.transcribing)).text, "still being processed")
    }

    func testAFailedMeetingKeepsItsAudio() {
        let audio = AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 48_000_000)
        let expected = "Audio · 48 MB · kept while the meeting has failed"
        for retention in Self.everySetting {
            XCTAssertEqual(line(Fixture.record(outcome: .inProgress), live: live(.error), audio: audio, retention: retention).text, expected)
            XCTAssertEqual(line(Fixture.record(outcome: .failed), audio: audio, retention: retention).text, expected)
        }
    }

    func testADeletionNamesItsKindAndDate() {
        let date = Fixture.date(2026, 10, 20)
        let rows: [(MeetingFileRecord.AudioDeletion.Kind, String)] = [
            (.manual, "Audio moved to the Trash on 20 Oct"),
            (.automatic, "Audio deleted automatically on 20 Oct"),
        ]
        for (kind, expected) in rows {
            for retention in Self.everySetting {
                let record = Fixture.record { $0.audioDeletion = .init(kind: kind, at: date) }
                XCTAssertEqual(line(record, audio: nothingLeft, retention: retention).text, expected, "\(retention)")
            }
        }
    }

    /// The registry entry, not the record, says whether notes were written: the
    /// pass keeps an entry until they are, so the line promises no date.
    func testAListedMeetingWithoutWrittenNotesSaysSo() {
        XCTAssertEqual(line(Fixture.record(), listed: .awaitingNotes).text, "Audio · 286 MB · kept, no notes were saved")
        XCTAssertEqual(line(Fixture.record(), retention: Self.off, listed: .awaitingNotes).text, "Audio · 286 MB", "off promises nothing")
    }

    /// The export uploads the notes, not the audio, so the pass does not wait for it.
    /// The pass waits for a running export, so the line does too.
    func testARunningExportHoldsTheLineUnlessTheSettingIsOff() {
        XCTAssertEqual(line(Fixture.record(), live: live(.done, exporting: true)).text, "Audio · 286 MB · kept until the Notion export ends")
        XCTAssertEqual(line(Fixture.record(), live: live(.done, exporting: true), retention: Self.off).text, "Audio · 286 MB")
        XCTAssertEqual(line(Fixture.record(), live: live(.done)).text, "Audio · 286 MB · deleted automatically on 15 Nov")
    }

    func testSwitchedOffAFinishedMeetingShowsItsSizeOnly() {
        XCTAssertEqual(line(Fixture.record(), retention: Self.off).text, "Audio · 286 MB")
        XCTAssertEqual(line(Fixture.record { $0.setFiles(.protocol, to: nil) }, retention: Self.off).text, "Audio · 286 MB", "no notes")
    }

    /// Notes written elsewhere (Notion, or the transcript with no provider) count as
    /// the registry counts them.
    func testAMeetingWithoutALocalProtocolCanStillBeDue() {
        let due = "Audio · 286 MB · deleted automatically on 15 Nov"
        XCTAssertEqual(line(Fixture.record(outcome: .finished(protocolExpected: false)) { $0.setFiles(.protocol, to: nil) }).text, due)
        XCTAssertEqual(line(Fixture.record { record in
            record.savedToNotion = true
            record.setFiles(.protocol, to: .gone)
        }).text, due)
    }

    /// The pass never reaches these, so no date may be promised.
    func testAMeetingThePassNeverDeletesShowsItsSizeOnly() {
        XCTAssertEqual(line(Fixture.record { $0.excludedFromAutomaticDeletion = true }).text, "Audio · 286 MB", "from before the records")
        XCTAssertEqual(line(Fixture.record(), listed: .unlisted).text, "Audio · 286 MB", "not in this build's registry")
        XCTAssertEqual(line(Fixture.record { $0.createdBy = Fixture.otherBuild }).text, "Audio · 286 MB", "another build's meeting")
        XCTAssertEqual(line(Fixture.record { $0.createdBy = nil }).text, "Audio · 286 MB", "a record from before the field")
        XCTAssertEqual(line(Fixture.record(outcome: .leftUnfinished)).text, "Audio · 286 MB", "left the queue unfinished")
        XCTAssertEqual(
            line(Fixture.record { $0.pending = .init(kind: .audioToTrash, paths: []) }).text, "Audio · 286 MB",
            "a deletion of the user's under way",
        )
    }

    /// Nor a reason to wait, which would say the audio goes afterwards.
    func testAMeetingThePassNeverDeletesNamesNoWaitEither() {
        let rows: [(String, MeetingFileRecord, Listing)] = [
            ("not listed, notes not saved", Fixture.record { $0.setFiles(.protocol, to: nil) }, .unlisted),
            ("from before the records, notes not written", Fixture.record { $0.excludedFromAutomaticDeletion = true }, .awaitingNotes),
        ]
        for (name, record, listed) in rows {
            XCTAssertEqual(line(record, listed: listed).text, "Audio · 286 MB", name)
        }
    }

    // MARK: - What the disk answered

    func testAudioConfirmedGoneReadsNotFoundInEveryLaterState() {
        let rows: [(MeetingFileRecord, LiveMeetingState?)] = [
            (Fixture.record(), nil),
            (Fixture.record { $0.keep = true }, nil),
            (Fixture.record(outcome: .failed), nil),
            (Fixture.record(outcome: .inProgress), live(.speakerNamingPending)),
        ]
        for (record, live) in rows {
            XCTAssertEqual(line(record, live: live, audio: nothingLeft).text, "Audio not found")
        }
        let noneListed = AudioOnDisk(presentCount: 0, unreachableCount: 0, totalCount: 0, bytes: 0)
        XCTAssertEqual(line(Fixture.record { $0.files = [] }, audio: noneListed).text, "Audio not found")
    }

    /// Never "Audio not found": the drive may come back.
    func testAudioOnlyOutOfReachReadsNotConnected() {
        let oneOfThree = AudioOnDisk(presentCount: 0, unreachableCount: 1, totalCount: 3, bytes: 0)
        let rows: [(MeetingFileRecord, LiveMeetingState?, AudioOnDisk)] = [
            (Fixture.record(), nil, unplugged),
            (Fixture.record(), nil, oneOfThree),
            (Fixture.record { $0.keep = true }, nil, unplugged),
            (Fixture.record(outcome: .failed), nil, unplugged),
            (Fixture.record(outcome: .inProgress), live(.speakerNamingPending), unplugged),
        ]
        for (record, live, audio) in rows {
            XCTAssertEqual(line(record, live: live, audio: audio).text, "Audio · on a drive that is not connected", "\(audio)")
        }
    }

    func testTheSizeCountsOnlyFilesPresentOnDisk() {
        let audio = AudioOnDisk(presentCount: 1, unreachableCount: 2, totalCount: 3, bytes: 48_000_000)
        XCTAssertEqual(line(Fixture.record(), audio: audio).text, "Audio · 48 MB · deleted automatically on 15 Nov")
    }

    // MARK: - An incomplete deletion

    private func incomplete(reason: String = "r", kind: MeetingFileRecord.DeletionKind = .meetingToTrash) -> MeetingFileRecord.DeletionFailure {
        .init(reason: reason, paths: [], kind: kind)
    }

    /// The reason is the one the deletion recorded, counted there.
    func testAnIncompleteDeletionShowsTheRecordedReason() {
        let unreachable = MeetingFileRemover.FileOutcome(path: "/a", result: .failed(.unreachable))
        let rows: [([MeetingFileRemover.FileOutcome], String)] = [
            ([unreachable], "Deletion incomplete: 1 file is on a drive or in a folder that is not available"),
            ([unreachable, unreachable], "Deletion incomplete: 2 files are on a drive or in a folder that is not available"),
        ]
        for (outcomes, expected) in rows {
            let reason = MeetingFileRemover.failureReason(of: outcomes) ?? ""
            XCTAssertEqual(line(Fixture.record { $0.incomplete = self.incomplete(reason: reason) }).incompleteText, expected)
        }
        XCTAssertNil(line(Fixture.record()).incompleteText)
        XCTAssertNil(line(Fixture.record { $0.audioDeletion = .init(kind: .manual, at: Fixture.recorded) }).incompleteText)
    }

    func testAnIncompleteDeletionCountsTheFilesMoved() {
        let rows: [(AudioOnDisk, String)] = [
            (AudioOnDisk(presentCount: 0, unreachableCount: 1, totalCount: 3, bytes: 0), "Audio · 2 of 3 files moved to the Trash"),
            (AudioOnDisk(presentCount: 1, unreachableCount: 0, totalCount: 3, bytes: 48_000_000), "Audio · 2 of 3 files moved to the Trash"),
            (unplugged, "Audio · 0 of 3 files moved to the Trash"),
            (nothingLeft, "Audio · 3 of 3 files moved to the Trash"),
            (AudioOnDisk(presentCount: 1, unreachableCount: 0, totalCount: 1, bytes: 1000), "Audio · 0 of 1 file moved to the Trash"),
        ]
        for (audio, expected) in rows {
            for kind in [MeetingFileRecord.DeletionKind.audioToTrash, .meetingToTrash] {
                let record = Fixture.record { $0.incomplete = self.incomplete(kind: kind) }
                XCTAssertEqual(line(record, audio: audio, retention: Self.off).text, expected, "\(kind)")
            }
        }
    }

    /// Move Meeting stopped at the transcript, after the audio had already gone.
    func testAnEarlierDeletionKeepsItsLineThroughAnIncompleteOne() {
        let record = Fixture.record { record in
            record.audioDeletion = .init(kind: .automatic, at: Fixture.date(2026, 10, 20))
            record.incomplete = self.incomplete()
        }
        let line = line(record, audio: nothingLeft)
        XCTAssertEqual(line.text, "Audio deleted automatically on 20 Oct")
        XCTAssertEqual(line.incompleteText, "Deletion incomplete: r")
    }

    func testAnIncompleteDeletionOfAnImportKeepsItsLine() {
        let line = line(Fixture.record(origin: .imported) { $0.incomplete = self.incomplete() }, audio: nothingLeft)
        XCTAssertEqual(line.text, "Audio · your imported file, never deleted by the app")
        XCTAssertEqual(line.incompleteText, "Deletion incomplete: r")
    }

    // MARK: - Locale and calendar

    func testDatesFollowTheLocaleAndTheCalendarsTimeZone() {
        XCTAssertEqual(line(Fixture.record(), locale: Locale(identifier: "en_US")).text, "Audio · 286 MB · deleted automatically on Nov 15")

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        let lateEvening = Fixture.date(2026, 10, 20, hour: 22)
        let record = Fixture.record { $0.audioDeletion = .init(kind: .manual, at: lateEvening) }
        XCTAssertEqual(line(record, audio: nothingLeft).text, "Audio moved to the Trash on 20 Oct")
        XCTAssertEqual(line(record, audio: nothingLeft, calendar: tokyo).text, "Audio moved to the Trash on 21 Oct")
    }
}
