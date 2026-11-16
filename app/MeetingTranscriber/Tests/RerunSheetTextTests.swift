@testable import MeetingTranscriber
import XCTest

/// The Transcribe Again sheet's texts (spec D6, A16, A18, A27): the drawn case word
/// for word, each case the boards do not draw, and each value as Settings labels it.
/// That the sheet shows them is `TranscribeAgainSheetTests`.
final class RerunSheetTextTests: XCTestCase {
    private typealias Row = RerunSheetText.Row

    private static let start = Date(timeIntervalSinceReferenceDate: 784_000_000)
    private static let turbo = WhisperKitModelSelection(variant: "openai_whisper-large-v3-v20240930_turbo", origin: .stock)

    /// The boards' Settings: WhisperKit with its recommended model, German, vocabulary
    /// on, Standard, notes made and the Notion export on.
    private func settings(
        engine: TranscriptionEngineSetting = .whisperKit, model: WhisperKitModelSelection = turbo, whisperLanguage: String = "de",
        parakeetLanguage: String = "", vocabulary: Bool = true, diarize: Bool = true, mode: DiarizerMode = .offline,
        makesNotes: Bool = true, notionExport: Bool = true,
    ) -> RerunSheetText.Settings {
        RerunSheetText.Settings(
            engine: engine, whisperKitModel: model, whisperLanguage: whisperLanguage, parakeetLanguage: parakeetLanguage,
            vocabulary: vocabulary, diarize: diarize, diarizerMode: mode, makesNotes: makesNotes, notionExport: notionExport,
        )
    }

    /// The boards' meeting: a recorded call of 48 minutes with a report and a page.
    private func meeting(
        twoTracks: Bool = true, reports: Bool = true, page: Bool = true, date: Date? = start, duration: TimeInterval? = 2880,
    ) -> RerunSheetText.Meeting {
        RerunSheetText.Meeting(
            id: UUID(), title: "Weekly team sync", date: date, duration: duration, twoTracks: twoTracks, hasReports: reports,
            hasNotionPage: page,
        )
    }

    private static let drawnLines = [
        "The meeting is transcribed again from its own audio, then you name the speakers.",
        "The current transcript and notes stay as they are. When the new ones are saved, they stay beside them as earlier versions, "
            + "named with today's date and time.",
        "The row shows the new result. Additional reports stay. The Notion page is updated, not duplicated.",
    ]

    func testTheDrawnCaseWordForWord() {
        XCTAssertEqual(RerunSheetText.title, "Transcribe Again")
        XCTAssertEqual(RerunSheetText.meetingLine(meeting()), "Weekly team sync · \(Self.start.formatted(date: .abbreviated, time: .shortened)) · 48:00")
        XCTAssertEqual(RerunSheetText.rows(settings(), meeting: meeting()), [
            Row(label: "Engine and model", value: "WhisperKit (Whisper) · Large V3 Turbo (recommended)"),
            Row(label: "Language", value: "Deutsch"),
            Row(label: "Vocabulary", value: "On"),
            Row(label: "Speakers", value: "Standard · 2 tracks"),
        ])
        XCTAssertEqual(RerunSheetText.fromSettings, "These come from Settings. To use others, change them in Settings first.")
        XCTAssertEqual(RerunSheetText.whatHappensHeading, "What happens")
        XCTAssertEqual(RerunSheetText.whatHappens(settings(), meeting: meeting()), Self.drawnLines)
        XCTAssertEqual(RerunSheetText.actionButton, "Transcribe Again")
    }

    /// Each line shows only the part that applies (A16); the page is updated only
    /// with new notes, so notes off drops it too.
    func testEachCaseTheBoardsDoNotDraw() {
        let notesOff = "The current transcript stays as it is. When the new one is saved, it stays beside it as an earlier version, "
            + "named with today's date and time. No new notes are made, so the current notes stay."
        let rows: [(String, RerunSheetText.Settings, RerunSheetText.Meeting, [String])] = [
            ("no reports", settings(), meeting(reports: false), [
                Self.drawnLines[0], Self.drawnLines[1], "The row shows the new result. The Notion page is updated, not duplicated.",
            ]),
            ("no page", settings(), meeting(page: false), [Self.drawnLines[0], Self.drawnLines[1], "The row shows the new result. Additional reports stay."]),
            ("the export off", settings(notionExport: false), meeting(), [
                Self.drawnLines[0], Self.drawnLines[1], "The row shows the new result. Additional reports stay.",
            ]),
            ("neither", settings(), meeting(reports: false, page: false), [Self.drawnLines[0], Self.drawnLines[1], "The row shows the new result."]),
            ("notes off", settings(makesNotes: false), meeting(), [Self.drawnLines[0], notesOff, "The row shows the new result. Additional reports stay."]),
            ("speaker identification off", settings(diarize: false), meeting(), [
                "The meeting is transcribed again from its own audio.", Self.drawnLines[1], Self.drawnLines[2],
            ]),
        ]
        for (name, settings, meeting, lines) in rows {
            XCTAssertEqual(RerunSheetText.whatHappens(settings, meeting: meeting), lines, name)
        }
        XCTAssertEqual(RerunSheetText.speakers(settings(diarize: false), twoTracks: true), "Off")
        XCTAssertEqual(RerunSheetText.speakers(settings(), twoTracks: false), "Standard")
        XCTAssertEqual(RerunSheetText.speakers(settings(mode: .nemotron), twoTracks: true), "Nemotron 3 · 2 tracks")
        XCTAssertEqual(RerunSheetText.meetingLine(meeting(date: nil, duration: nil)), "Weekly team sync")
    }

    /// A18's two lines and A27's; every other refusal has a line of its own.
    func testEachRefusalHasItsLine() {
        XCTAssertEqual(RerunSheetText.refusal(.audioGone), "The meeting's audio is no longer there.")
        XCTAssertEqual(RerunSheetText.refusal(.audioUnreachable), "The meeting's audio is on a drive that is not connected.")
        XCTAssertEqual(RerunSheetText.refusal(.filesLeft), "Files of the last re-run could not be removed.")
        let all: [RerunRefusal] = [
            .notFinished, .deletionPending, .alreadyRerunning, .meetingBusy, .audioHeldElsewhere, .audioGone, .audioUnreachable,
            .recordNotSaved, .filesLeft, .rerunFileUnreadable,
        ]
        XCTAssertEqual(Set(all.map(RerunSheetText.refusal)).count, all.count)
    }

    /// The engine and model pickers' labels, a custom model by its name, and the
    /// language picker of the engine in use.
    func testEachValueAsSettingsLabelsIt() {
        let rows: [(String, RerunSheetText.Settings, engine: String, language: String)] = [
            ("Parakeet", settings(engine: .parakeet, parakeetLanguage: "pl"), "Parakeet TDT v3 (NVIDIA)", "Polski"),
            ("a stock model", settings(model: .init(variant: "openai_whisper-small", origin: .stock)), "WhisperKit (Whisper) · Small", "Deutsch"),
            (
                "a model of another repository", settings(model: .init(variant: "whisper-de-ch", origin: .hub(repoID: "acme/models"))),
                "WhisperKit (Whisper) · whisper-de-ch", "Deutsch",
            ),
            (
                "a model folder", settings(model: .init(variant: "dialect", origin: .localFolder(path: "/m/dialect", bookmark: nil))),
                "WhisperKit (Whisper) · dialect", "Deutsch",
            ),
            (
                "a variant the picker does not list", settings(model: .init(variant: "openai_whisper-medium", origin: .stock), whisperLanguage: ""),
                "WhisperKit (Whisper) · openai_whisper-medium", "Auto-detect",
            ),
            (
                "a language the picker does not list", settings(whisperLanguage: "xx"),
                "WhisperKit (Whisper) · Large V3 Turbo (recommended)", "xx",
            ),
        ]
        for (name, settings, engine, language) in rows {
            XCTAssertEqual(RerunSheetText.engineAndModel(settings), engine, name)
            XCTAssertEqual(RerunSheetText.language(settings), language, name)
        }
        XCTAssertEqual(RerunSheetText.rows(settings(vocabulary: false), meeting: meeting())[2].value, "Off")
    }

    func testTheSettingsAreReadAsSettingsHoldThem() throws {
        let suite = "RerunSheetTextTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "fr"
        settings.whisperLanguage = "it"
        settings.customVocabularyEnabled = true
        settings.diarize = false
        settings.diarizerMode = .sortformer
        settings.protocolProvider = .none
        settings.notionExportEnabled = true

        XCTAssertEqual(RerunSheetText.Settings(settings: settings), RerunSheetText.Settings(
            engine: .parakeet, whisperKitModel: settings.whisperKitModelSelection, whisperLanguage: "it", parakeetLanguage: "fr",
            vocabulary: true, diarize: false, diarizerMode: .sortformer, makesNotes: false, notionExport: true,
        ))
        settings.protocolProvider = .openAICompatible
        XCTAssertTrue(RerunSheetText.Settings(settings: settings).makesNotes)
    }

    /// Two tracks while the record lists both, the reports from the row's read, the
    /// page from the row.
    func testTheMeetingIsWhatTheRowShowed() {
        var job = PipelineJob(
            meetingTitle: "Retro", appName: "Teams", mixPath: URL(fileURLWithPath: "/rec/m.wav"), appPath: nil, micPath: nil, micDelay: 0,
            meetingStartTime: Self.start,
        )
        job.audioDuration = 65
        job.recordNotionPage(NotionPageResult(pageID: "page"), databaseID: "database")
        let entry = TranscriptionEntry(job: job, finishOrder: nil)
        let report = RecordingRowActions.Report(name: "Short", url: URL(fileURLWithPath: "/out/r (Short).md"))
        let onDisk = RecordingRowActions.FilesOnDisk(protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile, reports: [report])

        let call = RerunSheetText.Meeting(entry: entry, record: RetentionFixture.record(), onDisk: onDisk)
        XCTAssertEqual(call, RerunSheetText.Meeting(
            id: job.id, title: "Retro", date: Self.start, duration: 65, twoTracks: true, hasReports: true, hasNotionPage: true,
        ))
        let micGone = RetentionFixture.record { $0.setFiles(.micTrack, to: .gone) }
        XCTAssertFalse(RerunSheetText.Meeting(entry: entry, record: micGone, onDisk: onDisk).twoTracks)
        XCTAssertFalse(RerunSheetText.Meeting(entry: entry, record: RetentionFixture.record(origin: .imported), onDisk: onDisk).twoTracks)
        let none = RecordingRowActions.FilesOnDisk(protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile)
        XCTAssertFalse(RerunSheetText.Meeting(entry: entry, record: RetentionFixture.record(), onDisk: none).hasReports)
    }
}
