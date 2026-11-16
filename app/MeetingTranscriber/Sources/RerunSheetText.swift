import Foundation

/// What the Transcribe Again sheet says (spec R3, D6): its fixed lines word for word,
/// the four rows of what the re-run takes from Settings as Settings labels them, the
/// lines under "What happens" for the case at hand (A16) and the red line for a
/// click that queued nothing (A18, A27). Pure, so each case is tested on its own.
enum RerunSheetText {
    static let title = "Transcribe Again"
    static let actionButton = "Transcribe Again"
    static let fromSettings = "These come from Settings. To use others, change them in Settings first."
    static let whatHappensHeading = "What happens"

    private static let keptWithNotes = "The current transcript and notes stay as they are. When the new ones are saved, "
        + "they stay beside them as earlier versions, named with today's date and time."
    private static let keptWithoutNotes = "The current transcript stays as it is. When the new one is saved, "
        + "it stays beside it as an earlier version, named with today's date and time. No new notes are made, so the current notes stay."

    /// The meeting the sheet is for, as its row showed it when the item was chosen.
    struct Meeting: Equatable, Identifiable {
        /// The meeting's job id, which the re-run keeps.
        let id: UUID
        let title: String
        let date: Date?
        let duration: TimeInterval?
        /// The record lists the call audio and the microphone, which are diarized apart.
        let twoTracks: Bool
        /// From the row's last read of the meeting's folder.
        let hasReports: Bool
        let hasNotionPage: Bool
        /// The record lists the meeting's word timings (R7), which Identify Speakers
        /// Again labels again instead of transcribing.
        var hasWordTimings = false
    }

    /// What the sheet shows of Settings, as Settings holds it.
    struct Settings: Equatable {
        let engine: TranscriptionEngineSetting
        let whisperKitModel: WhisperKitModelSelection
        /// The language codes the two engines' pickers store.
        let whisperLanguage: String
        let parakeetLanguage: String
        let vocabulary: Bool
        let diarize: Bool
        let diarizerMode: DiarizerMode
        /// A protocol provider is set, so the re-run makes notes (A12).
        let makesNotes: Bool
        let notionExport: Bool
        /// Expected speakers; 0 is Auto.
        var numSpeakers = 0
    }

    /// One row of the white box: the label in grey, the value on the right.
    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// The grey line under the title: the meeting's title, date and time and length,
    /// in the formats of the row's own line, leaving out one the meeting lacks.
    static func meetingLine(_ meeting: Meeting) -> String {
        let date = meeting.date?.formatted(date: .abbreviated, time: .shortened)
        let length = meeting.duration.map { formattedTime($0) }
        return [meeting.title, date, length].compactMap(\.self).joined(separator: " · ")
    }

    static func rows(_ settings: Settings, meeting: Meeting) -> [Row] {
        [
            Row(label: "Engine and model", value: engineAndModel(settings)),
            Row(label: "Language", value: language(settings)),
            Row(label: "Vocabulary", value: settings.vocabulary ? "On" : "Off"),
            Row(label: "Speakers", value: speakers(settings, twoTracks: meeting.twoTracks)),
        ]
    }

    /// The three lines under "What happens", each with only the part that applies:
    /// no speakers to name without speaker identification, the transcript alone
    /// without notes, and the reports and the Notion page only where the meeting has
    /// them and the re-run touches them (a page is updated only with new notes).
    static func whatHappens(_ settings: Settings, meeting: Meeting) -> [String] {
        let run = settings.diarize
            ? "The meeting is transcribed again from its own audio, then you name the speakers."
            : "The meeting is transcribed again from its own audio."
        let kept = settings.makesNotes ? keptWithNotes : keptWithoutNotes
        let updatesPage = settings.makesNotes && settings.notionExport && meeting.hasNotionPage
        let result = ["The row shows the new result."]
            + (meeting.hasReports ? ["Additional reports stay."] : [])
            + (updatesPage ? ["The Notion page is updated, not duplicated."] : [])
        return [run, kept, result.joined(separator: " ")]
    }

    /// The red line above the buttons after a click that queued nothing.
    static func refusal(_ reason: RerunRefusal) -> String {
        switch reason {
        case .audioGone: "The meeting's audio is no longer there."
        case .audioUnreachable: "The meeting's audio is on a drive that is not connected."
        case .filesLeft: "Files of the last re-run could not be removed."
        case .notFinished: "The meeting is not finished."
        case .deletionPending: "A move of the meeting's files to the Trash is under way or did not finish."
        case .alreadyRerunning: "The meeting is already being transcribed again."
        case .meetingBusy: "The meeting is being processed or exported."
        case .audioHeldElsewhere: "The meeting's audio is in use by another job."
        case .recordNotSaved: "The meeting's list of files could not be saved."
        case .rerunFileUnreadable: "The app's saved jobs could not be read, so a re-run could not be resumed after a quit."
        }
    }

    // MARK: - Values as Settings labels them

    /// The engine picker's label, and for WhisperKit the model picker's: a stock
    /// variant by its label, a custom model by its variant or folder name.
    static func engineAndModel(_ settings: Settings) -> String {
        switch settings.engine {
        case .whisperKit:
            let model = settings.whisperKitModel
            // The model picker lists `WhisperKitStockModel.all` by these labels.
            let stock = model.origin == .stock ? WhisperKitStockModel.model(for: model.variant)?.label : nil
            return "\(settings.engine.label) · \(stock ?? model.variant)"

        case .parakeet:
            // The engine's label names its one model.
            return settings.engine.label
        }
    }

    /// The language picker's label of the engine in use; a code the picker does not
    /// list as it is stored.
    static func language(_ settings: Settings) -> String {
        let (code, picker) = switch settings.engine {
        case .whisperKit: (settings.whisperLanguage, PickerLanguages.whisperKit)
        case .parakeet: (settings.parakeetLanguage, PickerLanguages.parakeet)
        }
        return picker.first { $0.code == code }?.label ?? code
    }

    /// "Off" without speaker identification; the method, and " · 2 tracks" for a
    /// recorded call whose two tracks are diarized apart.
    static func speakers(_ settings: Settings, twoTracks: Bool) -> String {
        guard settings.diarize else { return "Off" }
        return settings.diarizerMode.displayName + (twoTracks ? " · 2 tracks" : "")
    }
}

extension RerunSheetText {
    /// What the Identify Speakers Again sheet says (spec R9, D7): its fixed lines word
    /// for word, what stands under the method list (A17) and the lines under "What
    /// happens" for the case at hand (A16, A21). The meeting line and the red line are
    /// the Transcribe Again sheet's.
    enum IdentifySpeakersAgain {
        static let title = "Identify Speakers Again"
        static let actionButton = "Identify Speakers"
        static let methodHeading = "Speaker method"
        static let countLabel = "Expected speakers"
        /// In orange, in the place of "The text stays." (A21).
        static let noWordTimings = "This meeting has no saved word timings, so its audio is transcribed again first "
            + "with the current transcription settings."

        /// One line under "What happens".
        struct Line: Equatable {
            let text: String
            /// Shown in orange: the meeting's audio is transcribed again first.
            var isWarning = false
        }

        /// What stands under the method list, indented to the names (A17).
        enum UnderTheList: Equatable {
            /// "Expected speakers" with its number, while Standard is picked, and for a
            /// recorded call the naming dialog's note on the microphone under it.
            case count(note: String?)
            /// The naming dialog's hint for a method that counts the speakers itself.
            case hint(String)
        }

        /// Settings' expected speakers, 2 for Auto, which the naming dialog's count
        /// does not offer.
        static func startingCount(_ numSpeakers: Int) -> Int {
            numSpeakers == 0 ? 2 : numSpeakers
        }

        @MainActor
        static func underTheList(_ method: DiarizerMode, twoTracks: Bool) -> UnderTheList {
            if let hint = SpeakerNamingView.rerunMethodHint(mode: method, isDualSource: twoTracks) { return .hint(hint) }
            return .count(note: twoTracks ? SpeakerNamingView.micSideNote : nil)
        }

        /// "The text stays." only where the run labels the kept word timings again;
        /// without them the orange line in its place (A21). Without notes nothing is
        /// said about notes made again, and the current notes stay (A16).
        static func whatHappens(_ settings: Settings, meeting: Meeting) -> [Line] {
            let split = settings.makesNotes
                ? "The speakers are split again with this method, you name them, and the notes are made again."
                : "The speakers are split again with this method, and you name them."
            let kept = settings.makesNotes
                ? "The current transcript and notes stay beside the new ones as earlier versions, named with today's date and time."
                : "The current transcript stays beside the new one as an earlier version, named with today's date and time. "
                + "No new notes are made, so the current notes stay."
            let run = meeting.hasWordTimings
                ? [Line(text: "The text stays. " + split)]
                : [Line(text: noWordTimings, isWarning: true), Line(text: split)]
            return run + [Line(text: kept)]
        }
    }
}

extension RerunSheetText.Meeting {
    /// The row's meeting as the row showed it: its reports from the row's last read.
    init(entry: TranscriptionEntry, record: MeetingFileRecord, onDisk: RecordingRowActions.FilesOnDisk) {
        let tracks = record.rerunSourceTracks
        self.init(
            id: entry.id, title: entry.title, date: entry.date, duration: entry.audioDuration,
            twoTracks: tracks.app != nil && tracks.mic != nil, hasReports: !onDisk.reports.isEmpty, hasNotionPage: entry.hasNotionPage,
            hasWordTimings: record.keptWordTimings != nil,
        )
    }
}

extension RerunSheetText.Settings {
    init(settings: AppSettings) {
        self.init(
            engine: settings.transcriptionEngine, whisperKitModel: settings.whisperKitModelSelection,
            whisperLanguage: settings.whisperLanguage, parakeetLanguage: settings.parakeetLanguage,
            vocabulary: settings.customVocabularyEnabled, diarize: settings.diarize, diarizerMode: settings.diarizerMode,
            makesNotes: ProtocolOptionsUse(settings: settings).destination != .off, notionExport: settings.notionExportEnabled,
            numSpeakers: settings.numSpeakers,
        )
    }
}
