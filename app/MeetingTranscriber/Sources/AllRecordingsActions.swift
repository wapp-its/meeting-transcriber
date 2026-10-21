import AppKit

/// What the All Recordings window's controls do, handed to `TranscriptionsView`
/// as one value, the way `MenuActions` serves the menu. Built in
/// `MeetingTranscriberApp.allRecordingsActions`.
@MainActor
struct AllRecordingsActions {
    typealias FilesOnDisk = RecordingRowActions.FilesOnDisk

    /// Open and Show in Finder return false when the file is gone, so the
    /// window can say "The file was moved or deleted.".
    var openProtocol: (URL) -> Bool
    var openTranscript: (URL) -> Bool
    var reveal: (URL) -> Bool
    /// Opens the regenerate sheet: "Regenerate Protocol…" on a row, with the
    /// row's meeting, and "Regenerate from File…" in the toolbar, with none.
    /// False when the row's files are gone, like Open.
    var regenerate: (TranscriptionEntry?) -> Bool
    var retry: (UUID) -> Void
    /// Remove on a failed job: off the list and out of the history for good.
    var remove: (UUID) -> Void
    /// Dismiss on a job waiting for speaker names.
    var dismiss: (UUID) -> Void
    /// Cancel on a job that waits or runs.
    var cancel: (UUID) -> Void
    /// Opens the naming window on this job.
    var nameSpeakers: (UUID) -> Void
    var openProtocolsFolder: () -> Void
    /// Whether the pipeline would accept a retry of this job now.
    var canRetry: (UUID) -> Bool
    /// The row's files as they are on disk now. It reads both files, so the
    /// window asks it through `RowAvailability`, never on each redraw.
    var filesOnDisk: (TranscriptionEntry) -> FilesOnDisk

    // MARK: Regenerate sheet

    /// Read when the sheet opens, so templates added in Finder since are listed.
    var templateChoices: () -> ProtocolTemplateChoices
    /// Read on every redraw of the sheet, so it follows a change in Settings.
    var optionsUse: () -> ProtocolOptionsUse
    /// "Choose File…": the open panel.
    var chooseFile: () -> URL?
    /// The meeting a chosen protocol or transcript belongs to.
    var resolveFile: (URL) throws -> ProtocolRegenerationTarget
    /// Generate: starts the run, which reports its outcome in the sheet and
    /// as a notification.
    var generate: (ProtocolRegenerationTarget, MeetingProtocolOptions) -> Void

    /// Every action does nothing, no job can be retried, no file is on disk
    /// and protocol generation is off, so a test sets only what it asserts on.
    static let noop = Self(
        openProtocol: { _ in true },
        openTranscript: { _ in true },
        reveal: { _ in true },
        regenerate: { _ in true },
        retry: { _ in },
        remove: { _ in },
        dismiss: { _ in },
        cancel: { _ in },
        nameSpeakers: { _ in },
        openProtocolsFolder: {},
        canRetry: { _ in false },
        filesOnDisk: { _ in FilesOnDisk(protocolExists: false, transcriptExists: false, transcriptSource: .none) },
        templateChoices: { ProtocolTemplateChoices(templates: [.builtIn], defaultTemplate: .builtIn) },
        optionsUse: { ProtocolOptionsUse(destination: .off, recordOnly: false) },
        chooseFile: { nil },
        resolveFile: { _ in throw ProtocolRegenerationError.noTranscript },
        generate: { _, _ in },
    )

    // MARK: - Production

    /// Open, inside the security scope of `scopeRoot`, the output folder, like
    /// a job line's Open in the menu. False when the file is gone.
    static func openFile(_ url: URL, scopeRoot: URL) -> Bool {
        TranscriptionFileOpener.perform(url, scopeRoot: scopeRoot) { file in
            NSWorkspace.shared.open(file)
        }
    }

    /// Show in Finder, under the same rule as Open.
    static func revealFile(_ url: URL, scopeRoot: URL) -> Bool {
        TranscriptionFileOpener.perform(url, scopeRoot: scopeRoot) { file in
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    /// "Open Protocols Folder": creates the output folder when it is missing
    /// and opens it, saying nothing when it cannot be opened.
    static func openFolder(_ protocols: URL) {
        let accessing = protocols.startAccessingSecurityScopedResource()
        defer { if accessing { protocols.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    /// The entry's files on disk, read inside the security scope of
    /// `scopeRoot`. Whether there is a transcript to regenerate from is the
    /// regenerator's own rule, applied to the two files beside the protocol,
    /// else beside the transcript (`ProtocolRegenerationFiles.transcript`), so
    /// the row and the regenerator cannot disagree: a blank or non-UTF-8
    /// `.txt` counts only when the protocol holds the full transcript.
    static func readFilesOnDisk(of entry: TranscriptionEntry, scopeRoot: URL) -> FilesOnDisk {
        let accessing = scopeRoot.startAccessingSecurityScopedResource()
        defer { if accessing { scopeRoot.stopAccessingSecurityScopedResource() } }
        let disk = ProtocolRegenerationFileOperations.live
        let transcript = entry.fileToOpen.flatMap { file in
            ProtocolRegenerationTarget.readFiles(
                folder: file.deletingLastPathComponent(),
                basename: file.deletingPathExtension().lastPathComponent,
                read: disk.read,
            ).transcript
        }
        return FilesOnDisk(
            protocolExists: entry.protocolURL.map(disk.fileExists) ?? false,
            transcriptExists: entry.transcriptURL.map(disk.fileExists) ?? false,
            transcriptSource: transcriptSource(transcript),
        )
    }

    private static func transcriptSource(_ transcript: RegenerationTranscript?) -> RecordingRowActions.TranscriptSource {
        guard let transcript else { return .none }
        return transcript.fromProtocol ? .protocolOnly : .transcriptFile
    }
}
