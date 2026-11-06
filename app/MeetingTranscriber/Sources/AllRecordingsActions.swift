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
    /// "Open in Notion": the row's Notion page, which no file check guards.
    var openInNotion: (URL) -> Void
    /// Opens the regenerate sheet: "Regenerate Notes…" on a row, with the
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

    // MARK: A meeting's files

    /// The meeting's file record; nil for a job from before records existed. Read
    /// on every redraw, so a row follows the store while the window is open.
    var meetingFiles: (UUID) -> MeetingFileRecord?
    /// The audio of the row's meeting as it is on disk now; nil without a record. It
    /// reads every listed file, so the window asks it through `RowAvailability`.
    var audioOnDisk: (TranscriptionEntry) -> RecordingAudioLine.AudioOnDisk?
    /// "Move Audio to Trash…", once confirmed.
    var moveAudioToTrash: (UUID) -> Void
    /// "Move Meeting to Trash…", once confirmed.
    var moveMeetingToTrash: (UUID) -> Void
    /// "Retry Deletion" on a row whose deletion is incomplete.
    var retryDeletion: (UUID) -> Void
    /// "Keep (Never Delete Automatically)", with the mark's new value.
    var setKeep: (UUID, Bool) -> Void
    /// The setting the audio line says what happens next by.
    var retention: () -> RecordingRetention

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

    /// Every action does nothing, no job can be retried or has a file record, no
    /// file is on disk, recordings are kept and protocol generation is off, so a
    /// test sets only what it asserts on.
    static let noop = Self(
        openProtocol: { _ in true },
        openTranscript: { _ in true },
        reveal: { _ in true },
        openInNotion: { _ in },
        regenerate: { _ in true },
        retry: { _ in },
        remove: { _ in },
        dismiss: { _ in },
        cancel: { _ in },
        nameSpeakers: { _ in },
        openProtocolsFolder: {},
        canRetry: { _ in false },
        filesOnDisk: { _ in FilesOnDisk(protocolExists: false, transcriptExists: false, transcriptSource: .none) },
        meetingFiles: { _ in nil },
        audioOnDisk: { _ in nil },
        moveAudioToTrash: { _ in },
        moveMeetingToTrash: { _ in },
        retryDeletion: { _ in },
        setKeep: { _, _ in },
        retention: { .never },
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

    /// "Open Notes Folder": creates the output folder when it is missing
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

    /// A meeting's audio as the disk answers for it, read inside the security scope
    /// of `scopeRoot`. Touches each listed file, so the window asks it through
    /// `RowAvailability`. A size is added only for a file that is there, and a file
    /// out of reach is neither there nor gone.
    ///
    /// `totalCount` is what "2 of 3 files moved" counts: every track the record lists,
    /// also one gone, as a file a deletion moved reads as gone, and a 16 kHz copy only
    /// while it is listed as there. The pipeline removes those copies itself once the
    /// speakers are named, which would otherwise read "5 of 6" for three tracks.
    static func readAudioOnDisk(of record: MeetingFileRecord, scopeRoot: URL) -> RecordingAudioLine.AudioOnDisk {
        let accessing = scopeRoot.startAccessingSecurityScopedResource()
        defer { if accessing { scopeRoot.stopAccessingSecurityScopedResource() } }
        // Move Meeting covers everything Move Audio does, so this is one probe per path.
        let presence = Dictionary(uniqueKeysWithValues: record.filesCovered(by: .meetingToTrash).map { file in
            (file.path, MeetingFilePresence.of(file.path))
        })
        let audio = record.filesCovered(by: .audioToTrash)
        let present = audio.filter { presence[$0.path] == .present }
        let notOwned = Set(record.files.filter { !$0.owned }.map(\.path))
        let counted = record.files.filter { file in
            file.owned && file.role.isAudio && !notOwned.contains(file.path) && (file.role.isSourceTrack || file.state != .gone)
        }
        return RecordingAudioLine.AudioOnDisk(
            presentCount: present.count,
            unreachableCount: audio.filter { presence[$0.path] == .unreachable }.count,
            totalCount: Set(counted.map(\.path)).count,
            bytes: present.reduce(0) { $0 + size(of: $1.path) },
            gonePaths: Set(presence.filter { $0.value == .gone }.keys),
        )
    }

    /// Zero for a file that went between the probe and this read.
    private static func size(of path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    private static func transcriptSource(_ transcript: RegenerationTranscript?) -> RecordingRowActions.TranscriptSource {
        guard let transcript else { return .none }
        return transcript.fromProtocol ? .protocolOnly : .transcriptFile
    }
}
