import Foundation
import Observation

/// The Trash confirmation the window is showing, if any: which action, on which
/// meetings, in what words. A reference type for the reason on
/// `TranscriptionsFileNotice`.
@Observable
@MainActor
final class TrashConfirmationPrompt {
    enum Action {
        case moveAudio
        case moveMeeting

        var kind: MeetingFileRecord.DeletionKind {
            switch self {
            case .moveAudio: .audioToTrash
            case .moveMeeting: .meetingToTrash
            }
        }
    }

    struct Request {
        let action: Action
        /// One row's meeting, or the meetings of a selection the action applies to.
        let entries: [TranscriptionEntry]
        let text: TrashConfirmationText
        /// Per meeting, the paths the dialog counted, which are all its confirmation
        /// answers for.
        let named: [UUID: Set<String>]
    }

    var request: Request?
}

/// The rows selected in the All Recordings window, by job id. A reference type for
/// the reason on `TranscriptionsFileNotice`: a test sets the selection here, as a
/// click on a `List(selection:)` row cannot be driven without a window.
///
/// `List(selection:)` keeps an id while its row is hidden by the search or gone from
/// the list, so what counts as selected is always read through `entries(in:)`.
@Observable
@MainActor
final class TranscriptionsSelection {
    var ids: Set<UUID> = []

    /// The selected rows of those shown, in the list's order: a row the search hides
    /// or that has left the list is never acted on and never counted.
    func entries(in shown: [TranscriptionEntry]) -> [TranscriptionEntry] {
        shown.filter { ids.contains($0.id) }
    }
}

/// What one Trash action does to several selected rows. Pure: each row's record and
/// what the disk answered for it come in, as the row read them.
///
/// A meeting is in the plan exactly when its own row's menu offers the action enabled
/// (`RecordingRowActions.menuItems`), which follows what the controller's action
/// accepts. While a regeneration runs, Move Meeting applies to none, as on a row.
struct TrashSelectionPlan {
    struct Selected {
        let entry: TranscriptionEntry
        /// Nil for a row without a record.
        let meeting: RecordingRowActions.Meeting?
    }

    /// A meeting the action applies to.
    struct Planned {
        let entry: TranscriptionEntry
        let meeting: RecordingRowActions.Meeting
    }

    let action: TrashConfirmationPrompt.Action
    /// In the order they were selected.
    let meetings: [Planned]
    /// Selected rows the action does not apply to.
    let leftOut: Int
    /// Per meeting, the paths of its additional reports as Move Meeting to Trash just
    /// found them, which the confirmation counts and answers for. Set by the window.
    var reports: [UUID: [String]] = [:]

    init(action: TrashConfirmationPrompt.Action, selected: [Selected], isRegenerating: Bool = false) {
        let planned = selected.compactMap { row -> Planned? in
            guard let meeting = row.meeting, Self.applies(action, to: row.entry, meeting: meeting, isRegenerating: isRegenerating) else {
                return nil
            }
            return Planned(entry: row.entry, meeting: meeting)
        }
        self.action = action
        meetings = planned
        leftOut = selected.count - planned.count
    }

    /// The files of a row never decide these two items, so none are handed in.
    private static func applies(
        _ action: TrashConfirmationPrompt.Action, to entry: TranscriptionEntry, meeting: RecordingRowActions.Meeting, isRegenerating: Bool,
    ) -> Bool {
        let noFiles = RecordingRowActions.FilesOnDisk(protocolExists: false, transcriptExists: false, transcriptSource: .none)
        let offered = RecordingRowActions.menuItems(state: entry.state, onDisk: noFiles, canRetry: false, meeting: meeting)
        switch action {
        case .moveAudio: return offered.contains(.moveAudioToTrash(enabled: true))
        case .moveMeeting: return !isRegenerating && offered.contains(.moveMeetingToTrash(enabled: true))
        }
    }

    /// Off when it applies to none.
    var isEnabled: Bool {
        !meetings.isEmpty
    }

    var keptTitles: [String] {
        meetings.filter(\.meeting.record.keep).map(\.entry.title)
    }

    var hasImports: Bool {
        meetings.contains { $0.meeting.record.origin == .imported }
    }

    /// Of the files on disk, the audio of recorded meetings: an import's audio is the
    /// user's, and a copy the pipeline made of it goes as one of its other files.
    var audioBytes: Int64 {
        meetings.filter { $0.meeting.record.origin == .recorded }.reduce(0) { $0 + $1.meeting.audio.bytes }
    }

    var audioSize: String {
        TranscriptionsFooter.size(audioBytes)
    }

    /// Per meeting, the paths the confirmation answers for, by the rule of the single
    /// dialogs: what the action covers, less what the disk answered gone, and its reports.
    var named: [UUID: Set<String>] {
        Dictionary(meetings.map { planned in
            let files = TrashConfirmationText.files(of: action.kind, record: planned.meeting.record, audio: planned.meeting.audio)
            return (planned.entry.id, Set(files.map(\.path) + (reports[planned.entry.id] ?? [])))
        }) { first, _ in first }
    }
}

/// The line under the All Recordings list: how many rows it shows, or how many of them
/// are selected, their audio on disk, and what the retention setting does.
enum TranscriptionsFooter {
    static func text(shown: Int, selected: Int, audioBytes: Int64, retention: RecordingRetentionSettings) -> String {
        let count = selected > 0 ? "\(selected) of \(shown) selected" : "\(shown) \(shown == 1 ? "recording" : "recordings")"
        let audio = audioBytes > 0 ? "audio \(size(audioBytes))" : "no audio"
        return [count, audio, deletion(retention)].compactMap(\.self).joined(separator: " · ")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func deletion(_ retention: RecordingRetentionSettings) -> String? {
        guard retention.enabled else { return nil }
        let when = switch retention.days {
        case ...0: "right after the notes"
        case 1: "after 1 day"
        default: "after \(retention.days) days"
        }
        return "recordings are deleted automatically \(when) (Settings → Output)"
    }
}
