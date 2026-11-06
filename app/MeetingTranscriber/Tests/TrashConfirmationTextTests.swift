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
