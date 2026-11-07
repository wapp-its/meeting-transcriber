@testable import MeetingTranscriber
import XCTest

/// What the two single-meeting confirmations say (R5, R6). The whole text of each
/// case, so a line lost or reordered fails.
final class TrashConfirmationTextTests: XCTestCase {
    private typealias AudioOnDisk = RecordingAudioLine.AudioOnDisk
    private typealias TranscriptSource = RecordingRowActions.TranscriptSource
    private typealias Fixture = RetentionFixture

    private let title = "Budget review"
    private let voiceProfilesStay = "Voice profiles learned from it stay."
    private let audioLost =
        "Without the audio you cannot transcribe this meeting again or identify its speakers again. Voice profiles learned from it stay."
    private let threeFiles = "b_mix.wav\nb_app.wav\nb_mic.wav"
    private let everyTrack = ["b_mix.wav", "b_app.wav", "b_mic.wav"]

    private func audio(bytes: Int64 = 286_000_000, present: Int = 3, unreachable: Int = 0, gone: [String] = []) -> AudioOnDisk {
        AudioOnDisk(
            presentCount: present, unreachableCount: unreachable, totalCount: 3, bytes: bytes,
            gonePaths: Set(gone.map { Fixture.file(.mix, $0).path }),
        )
    }

    private func moveAudio(
        _ record: MeetingFileRecord, audio: AudioOnDisk? = nil, source: TranscriptSource = .transcriptFile,
    ) -> TrashConfirmationText {
        TrashConfirmationText.moveAudio(meetingTitle: title, record: record, audio: audio ?? self.audio(), transcriptSource: source)
    }

    private func moveMeeting(
        _ record: MeetingFileRecord, audio: AudioOnDisk? = nil, hasNotionPage: Bool = false, hasFailedExport: Bool = false,
    ) -> TrashConfirmationText {
        TrashConfirmationText.moveMeeting(
            meetingTitle: title, record: record, audio: audio ?? self.audio(),
            hasNotionPage: hasNotionPage, hasFailedExport: hasFailedExport,
        )
    }

    // MARK: - Move Audio (R5)

    func testMoveAudioSaysWhatGoesWhatStaysAndWhatIsLost() {
        let text = moveAudio(Fixture.record())
        XCTAssertEqual(text.title, "Move the audio of “Budget review” to the Trash?")
        XCTAssertEqual(text.lines, [
            "3 audio files (286 MB) go to the Trash. The transcript and the meeting notes stay, and Regenerate Notes keeps working.",
            audioLost,
            threeFiles,
        ])
        XCTAssertEqual(text.confirmButton, "Move to Trash")
    }

    func testMoveAudioOfOneFileIsSingular() {
        let record = Fixture.record { $0.files.removeAll { $0.role == .appTrack || $0.role == .micTrack } }
        let text = moveAudio(record, audio: audio(bytes: 48_000_000, present: 1))
        XCTAssertEqual(text.lines, [
            "1 audio file (48 MB) goes to the Trash. The transcript and the meeting notes stay, and Regenerate Notes keeps working.",
            audioLost,
            "b_mix.wav",
        ])
    }

    /// It only says what is there, and promises Regenerate Notes exactly when the
    /// regenerator has something to read, which can be the transcript the notes hold.
    func testMoveAudioNamesOnlyTheTextThatIsStillThere() {
        let rows: [(String, (inout MeetingFileRecord) -> Void, TranscriptSource, String)] = [
            ("no transcript", { $0.setFiles(.transcript, to: nil) }, .none, "The meeting notes stay."),
            ("transcript gone", { $0.setFiles(.transcript, to: .gone) }, .none, "The meeting notes stay."),
            (
                "notes holding the transcript",
                { $0.setFiles(.transcript, to: nil) },
                .protocolOnly,
                "The meeting notes stay, and Regenerate Notes keeps working.",
            ),
            (
                "transcript gone, notes holding it",
                { $0.setFiles(.transcript, to: .gone) },
                .protocolOnly,
                "The meeting notes stay, and Regenerate Notes keeps working.",
            ),
            ("no protocol", { $0.setFiles(.protocol, to: nil) }, .transcriptFile, "The transcript stays, and Regenerate Notes keeps working."),
            ("protocol gone", { $0.setFiles(.protocol, to: .gone) }, .transcriptFile, "The transcript stays, and Regenerate Notes keeps working."),
            ("blank transcript, no protocol", { $0.setFiles(.protocol, to: nil) }, .none, "The transcript stays."),
            ("blank transcript, notes not holding it", { _ in }, .none, "The transcript and the meeting notes stay."),
            ("blank transcript, notes holding it", { _ in }, .protocolOnly, "The transcript and the meeting notes stay, and Regenerate Notes keeps working."),
        ]
        for (name, change, source, stays) in rows {
            XCTAssertEqual(
                moveAudio(Fixture.record(change), source: source).lines.first, "3 audio files (286 MB) go to the Trash. \(stays)", name,
            )
        }
        let neither = Fixture.record { record in
            record.setFiles(.transcript, to: nil)
            record.setFiles(.protocol, to: nil)
        }
        for source: TranscriptSource in [.none, .protocolOnly, .transcriptFile] {
            XCTAssertEqual(moveAudio(neither, source: source).lines.first, "3 audio files (286 MB) go to the Trash.")
        }
    }

    /// A file removed by hand stays in the record until an action finds it gone. What
    /// the disk answered wins, so the number, the size and the names tell one story.
    func testMoveAudioLeavesOutWhatTheDiskAnsweredGone() {
        let text = moveAudio(Fixture.record(), audio: audio(bytes: 48_000_000, present: 1, gone: ["b_app.wav", "b_mic.wav"]))
        XCTAssertEqual(text.lines, [
            "1 audio file (48 MB) goes to the Trash. The transcript and the meeting notes stay, and Regenerate Notes keeps working.",
            audioLost,
            "b_mix.wav",
        ])
        XCTAssertEqual(
            moveAudio(Fixture.record(), audio: audio(gone: ["b.txt"]), source: .protocolOnly).lines.first,
            "3 audio files (286 MB) go to the Trash. The meeting notes stay, and Regenerate Notes keeps working.",
        )
        XCTAssertEqual(
            moveAudio(Fixture.record(), audio: audio(gone: ["b.md"])).lines.first,
            "3 audio files (286 MB) go to the Trash. The transcript stays, and Regenerate Notes keeps working.",
        )
    }

    /// Only files on disk add to the size, and a drive not connected adds none.
    func testMoveAudioOfFilesOutOfReachLeavesTheSizeOut() {
        XCTAssertEqual(
            moveAudio(Fixture.record(), audio: audio(bytes: 0, present: 0, unreachable: 3)).lines.first,
            "3 audio files go to the Trash. The transcript and the meeting notes stay, and Regenerate Notes keeps working.",
        )
    }

    /// The files listed are the ones the action moves: each path once, none gone.
    func testMoveAudioListsTheFilesTheActionCovers() {
        let record = Fixture.record { record in
            record.files = [
                Fixture.file(.mix, "mix.wav"),
                Fixture.file(.mix, "mix-other-folder.wav"),
                Fixture.file(.appTrack, "app.wav", state: .gone),
                Fixture.file(.mix16k, "mix16k.wav"),
                Fixture.file(.app16k, "mix16k.wav"),
                Fixture.file(.transcript, "b.txt"),
            ]
        }
        let text = moveAudio(record)
        XCTAssertEqual(text.lines.first, "3 audio files (286 MB) go to the Trash. The transcript stays, and Regenerate Notes keeps working.")
        XCTAssertEqual(text.lines.last, "mix.wav\nmix-other-folder.wav\nmix16k.wav")
    }

    // MARK: - Move Meeting (R6)

    func testMoveMeetingSaysWhatGoesAndThatTheMeetingLeaves() {
        let text = moveMeeting(Fixture.record())
        XCTAssertEqual(text.title, "Move “Budget review” to the Trash?")
        XCTAssertEqual(text.lines, [
            "Its audio (286 MB), transcript and meeting notes go to the Trash, and the meeting leaves this list.",
            voiceProfilesStay,
            "b_mix.wav\nb_app.wav\nb_mic.wav\nb.txt\nb.md",
        ])
        XCTAssertEqual(text.confirmButton, "Move to Trash")
    }

    /// "As far as they are still on disk", with the verb following what is left.
    func testMoveMeetingNamesOnlyWhatIsStillThere() {
        let noAudio = audio(bytes: 0, present: 0)
        let rows: [(String, MeetingFileRecord, AudioOnDisk, String)] = [
            (
                "audio and transcript",
                Fixture.record { $0.setFiles(.protocol, to: .gone) }, audio(),
                "Its audio (286 MB) and transcript go to the Trash, and the meeting leaves this list.",
            ),
            (
                "only audio",
                Fixture.record { record in
                    record.setFiles(.protocol, to: nil)
                    record.setFiles(.transcript, to: nil)
                }, audio(),
                "Its audio (286 MB) goes to the Trash, and the meeting leaves this list.",
            ),
            (
                "audio moved earlier",
                Fixture.record { $0.setAudio(to: .gone) }, noAudio,
                "Its transcript and meeting notes go to the Trash, and the meeting leaves this list.",
            ),
            (
                "audio removed by hand, not noticed by the record",
                Fixture.record { $0.setFiles(.protocol, to: nil) }, audio(bytes: 0, present: 0, gone: everyTrack),
                "Its transcript goes to the Trash, and the meeting leaves this list.",
            ),
            (
                "only notes",
                Fixture.record { record in
                    record.setAudio(to: .gone)
                    record.setFiles(.transcript, to: nil)
                }, noAudio,
                "Its meeting notes go to the Trash, and the meeting leaves this list.",
            ),
            (
                "audio out of reach",
                Fixture.record(), audio(bytes: 0, present: 0, unreachable: 3),
                "Its audio, transcript and meeting notes go to the Trash, and the meeting leaves this list.",
            ),
            (
                "only a naming file",
                Fixture.record { $0.files = [Fixture.file(.naming, "b.naming.json")] }, noAudio,
                "Its remaining files go to the Trash, and the meeting leaves this list.",
            ),
        ]
        for (name, record, audio, expected) in rows {
            XCTAssertEqual(moveMeeting(record, audio: audio).lines.first, expected, name)
        }
    }

    /// The same for the meeting: what the disk answered gone is neither named nor listed.
    func testMoveMeetingLeavesOutWhatTheDiskAnsweredGone() {
        let partOfTheAudio = moveMeeting(Fixture.record(), audio: audio(bytes: 48_000_000, present: 1, gone: ["b_app.wav", "b_mic.wav"]))
        XCTAssertEqual(partOfTheAudio.lines, [
            "Its audio (48 MB), transcript and meeting notes go to the Trash, and the meeting leaves this list.",
            voiceProfilesStay,
            "b_mix.wav\nb.txt\nb.md",
        ])
        let theTranscript = moveMeeting(Fixture.record(), audio: audio(gone: ["b.txt"]))
        XCTAssertEqual(theTranscript.lines, [
            "Its audio (286 MB) and meeting notes go to the Trash, and the meeting leaves this list.",
            voiceProfilesStay,
            "b_mix.wav\nb_app.wav\nb_mic.wav\nb.md",
        ])
        let everything = moveMeeting(Fixture.record(), audio: audio(bytes: 0, present: 0, gone: everyTrack + ["b.txt", "b.md"]))
        XCTAssertEqual(everything.lines, ["No file of this meeting is left to move, so it only leaves this list.", voiceProfilesStay])
    }

    func testAMeetingWithNoLocalFileLeftOnlyLeavesTheList() {
        let record = Fixture.record { $0.files = $0.files.map { MeetingFile(role: $0.role, path: $0.path, identity: nil, owned: $0.owned, state: .gone) } }
        XCTAssertEqual(moveMeeting(record, audio: audio(bytes: 0, present: 0)).lines, [
            "No file of this meeting is left to move, so it only leaves this list.",
            voiceProfilesStay,
        ])
    }

    /// The imported file is the user's, and an audio size would count it as going (A4).
    func testMoveMeetingOfAnImportSaysTheImportedFileStays() {
        XCTAssertEqual(moveMeeting(Fixture.record(origin: .imported)).lines, [
            "Its transcript and meeting notes go to the Trash, and the meeting leaves this list.",
            "The imported file stays where it is.",
            voiceProfilesStay,
            "b.txt\nb.md",
        ])
    }

    /// The imported file is still there, so "no file is left" has to mean the app's own.
    func testMoveMeetingOfAnImportWithNothingOfTheAppsLeft() {
        let record = Fixture.record(origin: .imported) { record in
            record.setFiles(.transcript, to: nil)
            record.setFiles(.protocol, to: nil)
        }
        XCTAssertEqual(moveMeeting(record, audio: audio(bytes: 0, present: 0)).lines, [
            "No file of this meeting is left to move, so it only leaves this list.",
            "The imported file stays where it is.",
            voiceProfilesStay,
        ])
    }

    /// A copy the pipeline made is the app's to move and no reason to speak of audio.
    func testMoveMeetingOfAnImportWithOnlyItsCopyLeft() {
        let record = Fixture.record(origin: .imported) { record in
            record.setFiles(.transcript, to: nil)
            record.setFiles(.protocol, to: nil)
            record.files.append(Fixture.file(.mix16k, "source_16k.wav"))
        }
        XCTAssertEqual(moveMeeting(record).lines, [
            "Its remaining files go to the Trash, and the meeting leaves this list.",
            "The imported file stays where it is.",
            voiceProfilesStay,
            "source_16k.wav",
        ])
    }

    func testMoveMeetingSaysWhatHappensInNotion() {
        let page = "The page in Notion stays."
        let export = "The failed Notion export can no longer be retried."
        let rows: [(Bool, Bool, [String])] = [(true, false, [page]), (false, true, [export]), (true, true, [page, export])]
        for (hasPage, hasFailedExport, expected) in rows {
            XCTAssertEqual(
                moveMeeting(Fixture.record(), hasNotionPage: hasPage, hasFailedExport: hasFailedExport).lines,
                ["Its audio (286 MB), transcript and meeting notes go to the Trash, and the meeting leaves this list."]
                    + expected + [voiceProfilesStay, "b_mix.wav\nb_app.wav\nb_mic.wav\nb.txt\nb.md"],
            )
        }
    }
}

// MARK: - Several meetings (R7)

/// What the one confirmation for several selected meetings says, also when one meeting
/// is left for the action.
extension TrashConfirmationTextTests {
    private typealias Selected = TrashSelectionPlan.Selected

    private enum Several {
        static let everyFileGoes = "Their audio (700 MB), transcripts and meeting notes go to the Trash, and the meetings leave this list."
        static let theirAudioGoes = "Their audio (700 MB) goes to the Trash. Their transcripts and meeting notes stay."
        static let voiceProfilesStay = "Voice profiles learned from these meetings stay."
        static let audioLost = "Without the audio you cannot transcribe these meetings again or identify their speakers again. "
            + "Voice profiles learned from these meetings stay."
        static let oneLeftOut = "1 selected meeting is left out, as this action does not apply to it."
    }

    /// Where a meeting's Notion export stands.
    private enum Notion {
        case notExported
        case completed
        case failed
        case failedAfterMakingItsPage
    }

    /// A finished recorded meeting of three tracks, a transcript and notes, each
    /// meeting 350 MB unless told otherwise.
    private func selected(
        _ title: String = "Meeting", bytes: Int64 = 350_000_000, gone: [String] = [], origin: MeetingFileRecord.Origin = .recorded,
        notion: Notion = .notExported, record: (inout MeetingFileRecord) -> Void = { _ in },
    ) -> Selected {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/\(title)_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        if notion == .completed || notion == .failedAfterMakingItsPage {
            job.recordNotionPage(NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"), databaseID: "db")
        }
        if notion != .notExported {
            job.beginNotionExport(speakerNames: [])
            job.finishNotionExport(succeeded: notion == .completed)
        }
        let audio = AudioOnDisk(
            presentCount: bytes > 0 ? 3 : 0, unreachableCount: bytes > 0 ? 0 : 3, totalCount: 3, bytes: bytes,
            gonePaths: Set(gone.map { Fixture.file(.mix, $0).path }),
        )
        return Selected(
            entry: TranscriptionEntry(job: job, finishOrder: nil),
            meeting: .init(record: Fixture.record(origin: origin, record), notionExportRunning: false, audio: audio),
        )
    }

    private func text(_ action: TrashConfirmationPrompt.Action, _ selected: [Selected]) -> TrashConfirmationText {
        .forSelection(TrashSelectionPlan(action: action, selected: selected))
    }

    private var leftOut: Selected {
        Selected(entry: selected("No record").entry, meeting: nil)
    }

    private func kept(_ title: String, bytes: Int64 = 350_000_000) -> Selected {
        selected(title, bytes: bytes) { $0.keep = true }
    }

    // MARK: - The two variants

    /// The accepted mockup, word for word but for the numbers.
    func testSeveralMeetingsReadAsInTheMockup() {
        let text = text(.moveMeeting, [
            kept("Strategy offsite", bytes: 300_000_000),
            selected("Retro", bytes: 200_000_000),
            selected("Standup", bytes: 200_000_000),
        ])
        XCTAssertEqual(text.title, "Move 3 meetings to the Trash?")
        XCTAssertEqual(text.lines, [
            Several.everyFileGoes,
            "“Strategy offsite” is marked Keep. Keep only stops automatic deletion, so it goes too.",
            Several.voiceProfilesStay,
        ])
        XCTAssertEqual(text.confirmButton, "Move to Trash")
    }

    /// The audio variant says that the text stays and what is lost with the audio.
    func testTheAudioOfSeveralSaysWhatStaysAndWhatIsLost() {
        let text = text(.moveAudio, [selected("One"), selected("Two")])
        XCTAssertEqual(text.title, "Move the audio of 2 meetings to the Trash?")
        XCTAssertEqual(text.lines, [Several.theirAudioGoes, Several.audioLost])
        XCTAssertEqual(text.confirmButton, "Move to Trash")
    }

    // MARK: - R7's lines

    /// Every kept meeting by name, in each variant, with the verb following the number.
    func testEveryKeptMeetingIsNamed() {
        let rows: [(selected: [Selected], names: String, meeting: String, audio: String)] = [
            ([kept("A"), selected("Plain")], "“A” is marked Keep.", "it goes too", "its audio goes too"),
            ([kept("A"), kept("B")], "“A” and “B” are marked Keep.", "they go too", "their audio goes too"),
            (
                [kept("A", bytes: 200_000_000), kept("B", bytes: 250_000_000), kept("C", bytes: 250_000_000)],
                "“A”, “B” and “C” are marked Keep.", "they go too", "their audio goes too",
            ),
        ]
        for row in rows {
            let keep = "\(row.names) Keep only stops automatic deletion, so"
            XCTAssertEqual(text(.moveMeeting, row.selected).lines, [Several.everyFileGoes, "\(keep) \(row.meeting).", Several.voiceProfilesStay])
            XCTAssertEqual(text(.moveAudio, row.selected).lines, [Several.theirAudioGoes, "\(keep) \(row.audio).", Several.audioLost])
        }
    }

    /// How many were left out, in each variant, after what goes and the Keep line.
    func testItSaysHowManyWereLeftOut() {
        let two = [selected("One"), kept("Two")]
        let keep = "“Two” is marked Keep. Keep only stops automatic deletion, so"
        XCTAssertEqual(
            text(.moveMeeting, two + [leftOut]).lines, [Several.everyFileGoes, "\(keep) it goes too.", Several.oneLeftOut, Several.voiceProfilesStay],
        )
        XCTAssertEqual(text(.moveMeeting, two + [leftOut, leftOut]).lines, [
            Several.everyFileGoes, "\(keep) it goes too.", "2 selected meetings are left out, as this action does not apply to them.",
            Several.voiceProfilesStay,
        ])
        XCTAssertEqual(text(.moveAudio, two + [leftOut]).lines, [Several.theirAudioGoes, "\(keep) its audio goes too.", Several.oneLeftOut, Several.audioLost])
    }

    /// An import's own file stays, and it is no reason to speak of its audio (A4).
    func testSeveralMeetingsSayImportedFilesStay() {
        let withImport = text(.moveMeeting, [selected("One", bytes: 700_000_000), selected("Talk", origin: .imported)])
        XCTAssertEqual(withImport.lines, [Several.everyFileGoes, "Imported files stay where they are.", Several.voiceProfilesStay])
        let onlyImports = text(.moveMeeting, [selected("Talk", origin: .imported), selected("Other", origin: .imported)])
        XCTAssertEqual(onlyImports.lines.first, "Their transcripts and meeting notes go to the Trash, and the meetings leave this list.")
    }

    /// A page stays and a failed export's retry ends, as in the single dialog (A10).
    func testSeveralMeetingsSayWhatHappensInNotion() {
        let exported = selected("Exported", notion: .completed)
        let failed = selected("Failed", notion: .failed)
        XCTAssertEqual(text(.moveMeeting, [exported, failed]).lines, [
            Several.everyFileGoes, "Pages in Notion stay.", "Failed Notion exports can no longer be retried.", Several.voiceProfilesStay,
        ])
        XCTAssertEqual(text(.moveAudio, [exported, failed]).lines, [Several.theirAudioGoes, Several.audioLost])
    }

    // MARK: - As far as the files are still there

    /// Over all of the meetings: a kind of file goes unnamed only when no meeting has
    /// one left, and the verb follows what is named.
    func testSeveralMeetingsNameOnlyWhatIsStillThere() {
        let noText: (inout MeetingFileRecord) -> Void = { record in
            record.setFiles(.transcript, to: nil)
            record.setFiles(.protocol, to: nil)
        }
        let noAudio: (inout MeetingFileRecord) -> Void = { $0.setAudio(to: .gone) }
        let onlyNotes: (inout MeetingFileRecord) -> Void = { record in
            record.setAudio(to: .gone)
            record.setFiles(.transcript, to: nil)
        }
        let rows: [(String, [Selected], String)] = [
            ("one has no notes", [selected("A") { $0.setFiles(.protocol, to: .gone) }, selected("B")], Several.everyFileGoes),
            (
                "no notes at all",
                [selected("A") { $0.setFiles(.protocol, to: .gone) }, selected("B") { $0.setFiles(.protocol, to: nil) }],
                "Their audio (700 MB) and transcripts go to the Trash, and the meetings leave this list.",
            ),
            (
                "only audio", [selected("A", record: noText), selected("B", record: noText)],
                "Their audio (700 MB) goes to the Trash, and the meetings leave this list.",
            ),
            (
                "no audio", [selected("A", bytes: 0, record: noAudio), selected("B", bytes: 0, record: noAudio)],
                "Their transcripts and meeting notes go to the Trash, and the meetings leave this list.",
            ),
            (
                "the disk answered every track gone",
                [selected("A", bytes: 0, gone: everyTrack), selected("B", bytes: 0, gone: everyTrack)],
                "Their transcripts and meeting notes go to the Trash, and the meetings leave this list.",
            ),
            (
                "audio out of reach", [selected("A", bytes: 0), selected("B", bytes: 0)],
                "Their audio, transcripts and meeting notes go to the Trash, and the meetings leave this list.",
            ),
            (
                "only notes",
                [selected("A", bytes: 0, record: onlyNotes), selected("B", bytes: 0, record: onlyNotes)],
                "Their meeting notes go to the Trash, and the meetings leave this list.",
            ),
            (
                "only naming files",
                [
                    selected("A", bytes: 0) { $0.files = [Fixture.file(.naming, "a.naming.json")] },
                    selected("B", bytes: 0) { $0.files = [Fixture.file(.naming, "b.naming.json")] },
                ],
                "Their remaining files go to the Trash, and the meetings leave this list.",
            ),
            (
                "nothing left",
                [selected("A", bytes: 0) { $0.files = [] }, selected("B", bytes: 0, gone: everyTrack + ["b.txt", "b.md"])],
                "No file of these meetings is left to move, so they only leave this list.",
            ),
        ]
        for (name, selected, expected) in rows {
            XCTAssertEqual(text(.moveMeeting, selected).lines.first, expected, name)
        }
    }

    /// The same for what stays when only their audio goes.
    func testTheAudioOfSeveralNamesOnlyTheTextStillThere() {
        let noText: (inout MeetingFileRecord) -> Void = { record in
            record.setFiles(.transcript, to: nil)
            record.setFiles(.protocol, to: .gone)
        }
        let rows: [(String, (inout MeetingFileRecord) -> Void, String)] = [
            ("no transcripts", { $0.setFiles(.transcript, to: .gone) }, "Their audio (700 MB) goes to the Trash. Their meeting notes stay."),
            ("no notes", { $0.setFiles(.protocol, to: nil) }, "Their audio (700 MB) goes to the Trash. Their transcripts stay."),
            ("no text", noText, "Their audio (700 MB) goes to the Trash."),
        ]
        for (name, change, expected) in rows {
            XCTAssertEqual(text(.moveAudio, [selected("A", record: change), selected("B", record: change)]).lines.first, expected, name)
        }
        XCTAssertEqual(
            text(.moveAudio, [selected("A", gone: ["b.txt"]), selected("B", gone: ["b.txt"])]).lines.first,
            "Their audio (700 MB) goes to the Trash. Their meeting notes stay.",
        )
        XCTAssertEqual(
            text(.moveAudio, [selected("A", bytes: 0), selected("B", bytes: 0)]).lines.first,
            "Their audio goes to the Trash. Their transcripts and meeting notes stay.",
        )
    }

    // MARK: - One meeting left

    /// Several rows selected and one left for the action: the same dialog, in the singular.
    func testASelectionLeavingOneMeetingReadsInTheSingular() {
        let one = kept("Kept", bytes: 286_000_000)

        let meeting = text(.moveMeeting, [one, leftOut])
        XCTAssertEqual(meeting.title, "Move 1 meeting to the Trash?")
        XCTAssertEqual(meeting.lines, [
            "Its audio (286 MB), transcript and meeting notes go to the Trash, and the meeting leaves this list.",
            "“Kept” is marked Keep. Keep only stops automatic deletion, so it goes too.",
            Several.oneLeftOut,
            "Voice profiles learned from it stay.",
        ])

        let audio = text(.moveAudio, [one, leftOut])
        XCTAssertEqual(audio.title, "Move the audio of 1 meeting to the Trash?")
        XCTAssertEqual(audio.lines, [
            "Its audio (286 MB) goes to the Trash. Its transcript and meeting notes stay.",
            "“Kept” is marked Keep. Keep only stops automatic deletion, so its audio goes too.",
            Several.oneLeftOut,
            "Without the audio you cannot transcribe this meeting again or identify its speakers again. Voice profiles learned from it stay.",
        ])

        let exportedImport = selected("Talk", origin: .imported, notion: .failedAfterMakingItsPage)
        XCTAssertEqual(text(.moveMeeting, [exportedImport, leftOut]).lines, [
            "Its transcript and meeting notes go to the Trash, and the meeting leaves this list.",
            Several.oneLeftOut,
            "The imported file stays where it is.",
            "The page in Notion stays.",
            "The failed Notion export can no longer be retried.",
            "Voice profiles learned from it stay.",
        ])
    }
}
