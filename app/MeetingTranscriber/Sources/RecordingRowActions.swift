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
        case retry
        case remove
    }

    /// One item of the "…" menu, declared in the order the menu lists them.
    enum MenuItem: Equatable {
        case openProtocol
        case openTranscript
        /// Reveals the protocol, else the transcript.
        case showInFinder
        /// "Regenerate Protocol…", disabled while the regenerator has no
        /// transcript to send.
        case regenerate(enabled: Bool)
        case retry
        case remove
        case dismiss
    }

    /// The files the job recorded (`TranscriptionEntry.protocolURL` and
    /// `transcriptURL`), whether or not they are still on disk.
    struct RecordedFiles {
        let hasProtocol: Bool
        let hasTranscript: Bool
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

    /// The row's files as last found on disk.
    struct FilesOnDisk {
        let protocolExists: Bool
        /// True for a `.txt` that is blank or not UTF-8 too: it still opens.
        let transcriptExists: Bool
        let transcriptSource: TranscriptSource
    }

    /// Follows the recorded files rather than the disk, as the window's Open
    /// did, so a file deleted since still gets its button and fails with "The
    /// file was moved or deleted.". Nil for a finished job that recorded
    /// neither file.
    static func mainAction(state: JobState, files: RecordedFiles, canRetry: Bool) -> MainAction? {
        switch state {
        case .waiting, .transcribing, .diarizing, .generatingProtocol:
            .cancel

        case .speakerNamingPending:
            .nameSpeakers

        case .done:
            if files.hasProtocol { .openProtocol } else if files.hasTranscript { .openTranscript } else { nil }

        case .error:
            canRetry ? .retry : .remove
        }
    }

    /// Only the items that apply, in `MenuItem`'s order, each at most once.
    /// The main button's action is listed again where it is one of these, so
    /// the right-click menu stands on its own. A waiting or running job lists
    /// nothing: the transcript stage 1 may already have written is a draft
    /// without speaker names that a later stage rewrites.
    static func menuItems(state: JobState, onDisk: FilesOnDisk, canRetry: Bool) -> [MenuItem] {
        let hasSource = onDisk.transcriptSource != .none
        return switch state {
        case .waiting, .transcribing, .diarizing, .generatingProtocol:
            []

        case .speakerNamingPending:
            fileItems(onDisk) + [.dismiss]

        case .done:
            fileItems(onDisk) + [.regenerate(enabled: hasSource)]

        case .error:
            fileItems(onDisk) + (hasSource ? [.regenerate(enabled: true)] : [])
                + (canRetry ? [.retry] : []) + [.remove]
        }
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
