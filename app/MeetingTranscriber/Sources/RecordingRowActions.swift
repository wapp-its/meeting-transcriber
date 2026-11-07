import Foundation

/// What one row of the All Recordings window offers: the one main button its
/// state calls for, and the items of its "…" menu, which the row's
/// right-click menu shows as well. Pure: the row's owner resolves which files
/// exist, what the regenerator could read and whether the pipeline would take
/// a retry, and hands those in, so the view only renders what this returns.
enum RecordingRowActions {
    /// The row's one visible button.
    enum MainAction {
        case cancel
        case nameSpeakers
        case openProtocol
        case openTranscript
        /// A finished job whose notes went only to Notion.
        case openInNotion
        case retry
        case remove
    }

    /// One item of the "…" menu, declared in the order the menu lists them.
    enum MenuItem: Equatable {
        case openProtocol
        case openTranscript
        /// The completed export's Notion page.
        case openInNotion
        /// Reveals the protocol, else the transcript.
        case showInFinder
        /// Sets the Additional Reports group apart.
        case separator
        /// "Additional Reports", which does nothing.
        case reportsHeading
        /// Opens one of the meeting's additional reports; `position` is its place
        /// among them, which its identifier carries instead of its name.
        case report(Report, position: Int)
        /// "Regenerate Notes…", disabled while the regenerator has no
        /// transcript to send.
        case regenerate(enabled: Bool)
        case retry
        case remove
        case dismiss
    }

    /// A row's main button, once its meeting's record is known.
    enum RowMainAction: Equatable {
        case action(MainAction)
        /// Runs the deletion that stopped again, over the files still there.
        case retryDeletion
    }

    /// One item of a row's menu, once its meeting's record is known: what any job
    /// lists, then the items acting on the meeting's files, declared in that order.
    enum RowMenuItem: Equatable {
        case item(MenuItem)
        /// "Keep (Never Delete Automatically)".
        case keep(checked: Bool, enabled: Bool)
        /// "Move Audio to Trash…".
        case moveAudioToTrash(enabled: Bool)
        /// "Move Meeting to Trash…".
        case moveMeetingToTrash(enabled: Bool)
    }

    /// What the row's record says, for the items acting on the meeting's files.
    struct Meeting {
        let record: MeetingFileRecord
        let notionExportRunning: Bool
        let audio: RecordingAudioLine.AudioOnDisk

        /// Whether the window's actions would take this meeting now, by the rule
        /// `PipelineController.actionableMeetingRecord` applies again when one runs,
        /// as a menu can go stale. A record not `.finished` covers another build's
        /// run; one with a pending mark can still be there after its row has left.
        func isActionable(in state: JobState) -> Bool {
            guard record.pending == nil, case .finished = record.outcome else { return false }
            return LiveMeetingState(state: state, notionExportRunning: notionExportRunning).isSettled
        }

        /// Any audio present or out of reach, of the files a deletion would cover.
        var hasAudioLeft: Bool {
            audio.isAnyLeft && !record.filesCovered(by: .audioToTrash).isEmpty
        }
    }

    /// The files the job recorded (`TranscriptionEntry.protocolURL` and
    /// `transcriptURL`), whether or not they are still on disk, and whether
    /// its Notion export completed with a page (`notionPageURL`).
    struct RecordedFiles {
        let hasProtocol: Bool
        let hasTranscript: Bool
        var hasNotionPage = false
    }

    /// What the regenerator would send as the transcript, by its own rule
    /// (`ProtocolRegenerationFiles.transcript`).
    enum TranscriptSource {
        /// The `.txt`, readable as UTF-8 and not blank.
        case transcriptFile
        /// No usable `.txt`, but the protocol holds the full transcript.
        case protocolOnly
        /// Nothing the regenerator could send.
        case none // swiftlint:disable:this discouraged_none_name
    }

    /// One of the meeting's additional reports, as its folder was read.
    struct Report: Equatable {
        let name: String
        let url: URL
    }

    /// The row's files as last found on disk.
    struct FilesOnDisk {
        let protocolExists: Bool
        /// True for a `.txt` that is blank or not UTF-8 too: it still opens.
        let transcriptExists: Bool
        let transcriptSource: TranscriptSource
        /// The meeting's additional reports in alphabetical order (`AdditionalReport`).
        /// None by default: a selection's plan never reads them, and a report never
        /// decides which items a selection offers.
        var reports: [Report] = []
    }

    /// Follows the recorded files rather than the disk, as the window's Open
    /// did, so a file deleted since still gets its button and fails with "The
    /// file was moved or deleted.". A finished job whose notes went only to
    /// Notion opens its page; the local files win where there are any, since
    /// the button names what it opens and the "…" menu offers the page. Nil
    /// for a finished job that recorded neither file nor page.
    static func mainAction(state: JobState, files: RecordedFiles, canRetry: Bool) -> MainAction? {
        switch state {
        case .waiting, .transcribing, .diarizing, .generatingProtocol:
            .cancel

        case .speakerNamingPending:
            .nameSpeakers

        case .done:
            if files.hasProtocol {
                .openProtocol
            } else if files.hasTranscript {
                .openTranscript
            } else {
                files.hasNotionPage ? .openInNotion : nil
            }

        case .error:
            canRetry ? .retry : .remove
        }
    }

    /// Only the items that apply, in `MenuItem`'s order, each at most once.
    /// The main button's action is listed again where it is one of these, so
    /// the right-click menu stands on its own. A waiting or running job lists
    /// nothing: the transcript stage 1 may already have written is a draft
    /// without speaker names that a later stage rewrites. A finished job with
    /// a Notion page lists "Open in Notion" after its files. The meeting's
    /// additional reports follow under their heading, set apart by a separator
    /// on each side, before "Regenerate Notes…" (spec D3).
    static func menuItems(
        state: JobState, onDisk: FilesOnDisk, canRetry: Bool, hasNotionPage: Bool = false,
    ) -> [MenuItem] {
        let hasSource = onDisk.transcriptSource != .none
        return switch state {
        case .waiting, .transcribing, .diarizing, .generatingProtocol:
            []

        case .speakerNamingPending:
            fileItems(onDisk) + [.dismiss]

        case .done:
            reportGroup(after: fileItems(onDisk) + (hasNotionPage ? [.openInNotion] : []), onDisk) + [.regenerate(enabled: hasSource)]

        case .error:
            reportGroup(after: fileItems(onDisk), onDisk) + (hasSource ? [.regenerate(enabled: true)] : [])
                + (canRetry ? [.retry] : []) + [.remove]
        }
    }

    /// `items`, then the reports under their heading, with a separator before them
    /// only when items precede it; an item always follows the group. Nothing for a
    /// meeting without reports.
    private static func reportGroup(after items: [MenuItem], _ onDisk: FilesOnDisk) -> [MenuItem] {
        guard !onDisk.reports.isEmpty else { return items }
        let reports = onDisk.reports.enumerated().map { MenuItem.report($0.element, position: $0.offset) }
        return items + (items.isEmpty ? [] : [.separator]) + [.reportsHeading] + reports + [.separator]
    }

    /// Retry Deletion wins over every other button while a deletion is incomplete and
    /// the retry would run. Otherwise the row keeps its usual one, as a button that
    /// does nothing would hide "Name Speakers" or "Retry" from a meeting that moved on.
    static func mainAction(state: JobState, files: RecordedFiles, canRetry: Bool, meeting: Meeting?) -> RowMainAction? {
        if let meeting, let kind = meeting.record.incomplete?.kind, kind != .automatic, meeting.isActionable(in: state) {
            return .retryDeletion
        }
        return mainAction(state: state, files: files, canRetry: canRetry).map(RowMainAction.action)
    }

    /// What the row lists for any job, then Keep and the two Trash items.
    static func menuItems(
        state: JobState, onDisk: FilesOnDisk, canRetry: Bool, meeting: Meeting?, hasNotionPage: Bool = false,
    ) -> [RowMenuItem] {
        menuItems(state: state, onDisk: onDisk, canRetry: canRetry, hasNotionPage: hasNotionPage).map(RowMenuItem.item)
            + meetingFileItems(state: state, meeting: meeting)
    }

    /// None without a record, or for a meeting that failed or left the queue unfinished:
    /// it keeps today's Retry and Remove and its audio. Listed but disabled while the
    /// meeting's state stops the actions, so the menu says the items exist. Keep and
    /// Move Audio have nothing to act on for an import or with no audio left.
    private static func meetingFileItems(state: JobState, meeting: Meeting?) -> [RowMenuItem] {
        guard let meeting, state != .error else { return [] }
        switch meeting.record.outcome {
        case .failed, .leftUnfinished: return []
        case .inProgress, .finished: break
        }
        let enabled = meeting.isActionable(in: state)
        var items: [RowMenuItem] = []
        if meeting.record.origin == .recorded, meeting.hasAudioLeft {
            items.append(.keep(checked: meeting.record.keep, enabled: enabled))
            // A half-moved meeting goes on with Retry: its action refuses here, as
            // finishing the audio would replace the record of what is left of it.
            items.append(.moveAudioToTrash(enabled: enabled && meeting.record.incomplete?.kind != .meetingToTrash))
        }
        items.append(.moveMeetingToTrash(enabled: enabled))
        return items
    }

    /// An item per file found on disk, and Show in Finder while either is.
    private static func fileItems(_ onDisk: FilesOnDisk) -> [MenuItem] {
        var items: [MenuItem] = []
        if onDisk.protocolExists { items.append(.openProtocol) }
        if onDisk.transcriptExists { items.append(.openTranscript) }
        if onDisk.protocolExists || onDisk.transcriptExists { items.append(.showInFinder) }
        return items
    }
}
