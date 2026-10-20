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

    /// One item of the "…" menu.
    enum MenuItem: Equatable {
        case openProtocol
        case openTranscript
        case showInFinder
        case regenerate(enabled: Bool)
        case retry
        case remove
        case dismiss
    }

    /// The files the job recorded.
    struct RecordedFiles {
        let hasProtocol: Bool
        let hasTranscript: Bool
    }

    /// What the regenerator could send as the transcript.
    enum TranscriptSource {
        case transcriptFile
        case protocolOnly
        case none // swiftlint:disable:this discouraged_none_name
    }

    /// The row's files as last found on disk.
    struct FilesOnDisk {
        let protocolExists: Bool
        let transcriptExists: Bool
        let transcriptSource: TranscriptSource
    }

    static func mainAction(state _: JobState, files _: RecordedFiles, canRetry _: Bool) -> MainAction? {
        nil
    }

    static func menuItems(state _: JobState, onDisk _: FilesOnDisk, canRetry _: Bool) -> [MenuItem] {
        []
    }
}
