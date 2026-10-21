// swiftlint:disable:this file_name - the task fixes this file for the regeneration types (target,
// files, file operations, regenerator), which change together; none of them is its single subject.
import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolRegeneration")

// MARK: - Errors

/// Why a protocol was not regenerated. No message carries transcript,
/// protocol or background text.
enum ProtocolRegenerationError: LocalizedError, Equatable {
    case noTranscript
    case providerOff
    case recordOnly
    case meetingBusy
    case filesChanged
    /// Carries no detail: a provider's error text can repeat what it was
    /// sent (`ProtocolError.httpError` holds the endpoint's error body).
    case generationFailed
    case writeFailed(String)
    /// The new file could not be put in place and the old one could not be
    /// moved back: it is kept under this name beside its path.
    case restoreFailed(keptAs: String)
    #if !APPSTORE
        /// The local model is held back for a recording: refused at start, or
        /// ended mid-run and not resumed (spec R11).
        case recording
        case lowMemory
        case noLocalModel
        /// Try Again on a notice while another regeneration runs.
        case regenerationRunning
    #endif

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            "No transcript was found for this meeting: there is no transcript file beside it, and its protocol has no Full Transcript section."

        case .providerOff:
            ProtocolDestination.off.notice

        case .recordOnly:
            "Record-only mode is on: no protocol is made on this Mac."

        case .meetingBusy:
            "This meeting is still being processed. Try again once it has finished."

        case .filesChanged:
            "The meeting's files changed while the protocol was being made, so nothing was replaced."

        case .generationFailed:
            "Protocol generation failed, so nothing was replaced."

        case let .writeFailed(reason):
            "The new protocol could not be saved, so the previous one was left in place: \(reason)"

        case let .restoreFailed(keptAs):
            "The new protocol could not be saved, and the previous one could not be put back. It is kept as \(keptAs)."

        #if !APPSTORE
            case .recording:
                "The protocol was not made because a recording is running. Start it again once the recording has ended."

            case .lowMemory:
                "There was not enough free memory for the local model, so nothing was replaced."

            case .noLocalModel:
                "No local model is chosen, or it cannot be reached, so nothing was replaced. Choose one in Settings → Output."

            case .regenerationRunning:
                "Another protocol is being made. Try again once it has finished."
        #endif
        }
    }
}

// MARK: - Files

/// The transcript a regeneration sends.
struct RegenerationTranscript: Equatable {
    let text: String
    /// Taken from the protocol's Full Transcript section, the only copy left
    /// when "Save raw transcript separately" was off.
    let fromProtocol: Bool
}

/// A meeting's `<basename>.txt` and `<basename>.md`, as read at one moment.
/// Compared byte for byte before a new protocol replaces anything, so a run
/// that rewrote either file meanwhile (a pipeline Retry) is never overwritten.
struct ProtocolRegenerationFiles: Equatable {
    /// Nil when there is no readable file.
    let transcriptFile: Data?
    let protocolFile: Data?

    /// The transcript file when it is UTF-8 and not blank, else the
    /// protocol's Full Transcript section, else nil.
    var transcript: RegenerationTranscript? {
        if let data = transcriptFile, let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RegenerationTranscript(text: text, fromProtocol: false)
        }
        guard let data = protocolFile, let document = String(data: data, encoding: .utf8),
              let text = ProtocolGenerator.fullTranscript(in: document)
        else { return nil }
        return RegenerationTranscript(text: text, fromProtocol: true)
    }
}

// MARK: - Target

/// The meeting a regeneration is for, resolved from a chosen protocol (`.md`)
/// or transcript (`.txt`) and the finished-job history.
struct ProtocolRegenerationTarget: Equatable {
    let folder: URL
    let basename: String
    let title: String
    /// Nil when no finished-job record knows the meeting: the protocol then
    /// shows its date as Unknown.
    let meetingStartTime: Date?
    let jobID: String?
    let files: ProtocolRegenerationFiles

    var transcriptURL: URL {
        folder.appendingPathComponent("\(basename).txt")
    }

    /// Where the new protocol goes, whether or not one is there now.
    var protocolURL: URL {
        folder.appendingPathComponent("\(basename).md")
    }

    var hasProtocol: Bool {
        files.protocolFile != nil
    }

    /// `<basename>.txt` and `<basename>.md` in `folder`, read now.
    static func readFiles(folder: URL, basename: String, read: (URL) -> Data?) -> ProtocolRegenerationFiles {
        ProtocolRegenerationFiles(
            transcriptFile: read(folder.appendingPathComponent("\(basename).txt")),
            protocolFile: read(folder.appendingPathComponent("\(basename).md")),
        )
    }

    /// The meeting `file` belongs to. Its title, start and job come from the
    /// newest finished-job record naming either of its two files; without one
    /// the title is the file name without its timestamp prefix.
    static func resolve(file: URL, records: [TerminalJobRecord], read: (URL) -> Data?) throws -> Self {
        let folder = file.deletingLastPathComponent()
        let basename = file.deletingPathExtension().lastPathComponent
        let files = readFiles(folder: folder, basename: basename, read: read)
        guard files.transcript != nil else { throw ProtocolRegenerationError.noTranscript }
        let candidates: Set = [
            normalizedPath(folder.appendingPathComponent("\(basename).txt")),
            normalizedPath(folder.appendingPathComponent("\(basename).md")),
        ]
        let record = records.last { record in
            [record.status.transcriptPath, record.status.protocolPath].contains { path in
                path.map { candidates.contains(normalizedPath(URL(fileURLWithPath: $0))) } ?? false
            }
        }
        return Self(
            folder: folder,
            basename: basename,
            title: record?.status.meetingTitle ?? ProtocolGenerator.stripExistingTimestampPrefix(basename),
            meetingStartTime: record?.meetingStartTime,
            jobID: record?.status.jobID,
            files: files,
        )
    }

    /// Whether `job` writes this meeting's files: the same job, basename or path.
    func isOwned(by job: PipelineJob) -> Bool {
        if job.id.uuidString == jobID || job.namingSlug == basename { return true }
        let own: Set = [Self.normalizedPath(transcriptURL), Self.normalizedPath(protocolURL)]
        return [job.transcriptPath, job.protocolPath].contains { url in
            url.map { own.contains(Self.normalizedPath($0)) } ?? false
        }
    }

    /// A path compared through symlinks (`/var` is `/private/var`). The folder
    /// is resolved on its own as well: `resolvingSymlinksInPath` leaves a path
    /// to a missing file as it is, and a record may name a deleted transcript.
    static func normalizedPath(_ url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(resolved.lastPathComponent).path
    }
}

// MARK: - File operations

/// Every file access a regeneration makes, so a test can make any single step
/// fail and never touches the real Trash.
struct ProtocolRegenerationFileOperations {
    /// Nil when nothing readable is there.
    var read: (URL) -> Data?
    var fileExists: (URL) -> Bool
    /// Creates an empty owner-only file, replacing one left by a crashed run.
    var createEmpty: (URL) throws -> Void
    var restrictToOwner: (URL) throws -> Void
    var write: (Data, URL) throws -> Void
    var move: (_ from: URL, _ to: URL) throws -> Void
    var remove: (URL) throws -> Void
    var trash: (URL) throws -> Void

    static var live: Self {
        Self(
            read: { try? Data(contentsOf: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createEmpty: { url in
                let created = FileManager.default.createFile(
                    atPath: url.path, contents: nil, attributes: [.posixPermissions: FileManager.ownerOnlyPermissions],
                )
                guard created else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            },
            restrictToOwner: { try FileManager.default.restrictToOwner($0) },
            write: { data, url in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
            },
            move: { try FileManager.default.moveItem(at: $0, to: $1) },
            remove: { try FileManager.default.removeItem(at: $0) },
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        )
    }
}

// MARK: - Regenerator

/// Makes a new protocol for a finished meeting from a chosen template and
/// background, one run at a time and outside the pipeline queue, and swaps it
/// in for the old one only once it exists (spec A7, A8).
@MainActor
@Observable
final class ProtocolRegenerator {
    enum Phase: Equatable {
        case idle
        case running
        case succeeded(URL, warnings: [String])
        case failed(String)
    }

    struct Environment {
        /// Nil when protocol generation is off.
        var generatorFactory: @MainActor () -> (any ProtocolGenerating)?
        var templateStore: ProtocolTemplateStore
        var includeFullTranscript: @MainActor () -> Bool
        var recordOnly: @MainActor () -> Bool
        /// The pipeline queue's jobs, for the busy check.
        var queuedJobs: @MainActor () -> [PipelineJob]
        var records: @MainActor () -> [TerminalJobRecord]
        /// Held under its security scope for the whole run.
        var outputDir: @MainActor () -> URL
        var notifier: any AppNotifying
        var fileOperations: ProtocolRegenerationFileOperations = .live
        var now: () -> Date = Date.init
    }

    static let succeededTitle = "Protocol Regenerated"
    static let failedTitle = "Protocol Not Regenerated"

    private static let previousStamp = DateFormatter.filenameStamp("yyyyMMdd_HHmmss")

    private(set) var phase: Phase = .idle
    @ObservationIgnored private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
        #if !APPSTORE
            environment.notifier.setLocalModelNoticeResponder(self)
        #endif
    }

    var isRunning: Bool {
        phase == .running
    }

    /// Forget a finished run's result, so a sheet opened later does not show it.
    func clearResult() {
        if !isRunning { phase = .idle }
    }

    func target(for file: URL) throws -> ProtocolRegenerationTarget {
        try withOutputScope {
            try ProtocolRegenerationTarget.resolve(
                file: file, records: environment.records(), read: environment.fileOperations.read,
            )
        }
    }

    /// The meeting of a row of the All Recordings window. Its files are the two
    /// beside the row's protocol, else beside its transcript, the same ones the
    /// row's menu read (`AllRecordingsActions.readFilesOnDisk`); its title,
    /// start and job are the row's own. The history is not asked: a failed job
    /// stays listed after the history dropped its record, and `resolve` would
    /// then take the title from the file name and know no start or job.
    func target(for entry: TranscriptionEntry) throws -> ProtocolRegenerationTarget {
        guard let file = entry.fileToOpen else { throw ProtocolRegenerationError.noTranscript }
        let folder = file.deletingLastPathComponent()
        let basename = file.deletingPathExtension().lastPathComponent
        let files = withOutputScope {
            ProtocolRegenerationTarget.readFiles(folder: folder, basename: basename, read: environment.fileOperations.read)
        }
        guard files.transcript != nil else { throw ProtocolRegenerationError.noTranscript }
        return ProtocolRegenerationTarget(
            folder: folder, basename: basename, title: entry.title,
            meetingStartTime: entry.meetingStartTime, jobID: entry.id.uuidString, files: files,
        )
    }

    /// Generates, then replaces the meeting's protocol; the outcome lands in
    /// `phase` and a notification. Ignored while a run is going. `notes` join
    /// a success's warnings.
    func regenerate(_ target: ProtocolRegenerationTarget, options: MeetingProtocolOptions, notes: [String] = []) async {
        guard !isRunning else { return }
        phase = .running
        let scope = environment.outputDir()
        let accessing = scope.startAccessingSecurityScopedResource()
        defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
        let backgroundPresence = options.background == nil ? "absent" : "present"
        logger.info(
            "protocol_regeneration_started job=\(target.jobID ?? "none", privacy: .public) background=\(backgroundPresence, privacy: .public)",
        )
        do {
            let warnings = try await run(target, options: options) + notes
            logger.info("protocol_regenerated job=\(target.jobID ?? "none", privacy: .public)")
            phase = .succeeded(target.protocolURL, warnings: warnings)
            environment.notifier.notify(title: Self.succeededTitle, body: ([target.title] + warnings).joined(separator: "\n"))
        } catch {
            let reason = error.localizedDescription
            logger.warning("protocol_regeneration_failed error=\(reason, privacy: .private)")
            phase = .failed(reason)
            environment.notifier.notify(title: Self.failedTitle, body: "\(target.title): \(reason)")
        }
    }

    private func run(_ target: ProtocolRegenerationTarget, options: MeetingProtocolOptions) async throws -> [String] {
        guard let generator = environment.generatorFactory() else { throw ProtocolRegenerationError.providerOff }
        guard !environment.recordOnly() else { throw ProtocolRegenerationError.recordOnly }
        guard !isBusy(target) else { throw ProtocolRegenerationError.meetingBusy }
        let files = ProtocolRegenerationTarget.readFiles(
            folder: target.folder, basename: target.basename, read: environment.fileOperations.read,
        )
        guard let transcript = files.transcript else { throw ProtocolRegenerationError.noTranscript }
        // The only copy of the transcript is never left in the Trash alone.
        let includeFullTranscript = environment.includeFullTranscript() || transcript.fromProtocol
        let (instructions, templateWarning) = environment.templateStore.instructions(
            for: options.template, background: options.background,
        )
        let (protocolMarkdown, incompleteWarning) = try await makeProtocol(
            with: generator, asJob: target.jobID.flatMap(UUID.init(uuidString:)),
            request: (transcript: transcript.text, title: target.title, meetingStartTime: target.meetingStartTime, instructions: instructions),
        )
        // A Retry may have started, or even finished and rewritten both
        // files, while the provider was working.
        guard !isBusy(target) else { throw ProtocolRegenerationError.meetingBusy }
        let current = ProtocolRegenerationTarget.readFiles(
            folder: target.folder, basename: target.basename, read: environment.fileOperations.read,
        )
        guard current == files else { throw ProtocolRegenerationError.filesChanged }
        let document = ProtocolGenerator.composeDocument(
            protocolMarkdown: protocolMarkdown, transcript: transcript.text, includeFullTranscript: includeFullTranscript,
        )
        let trashWarning = try replaceProtocol(of: target, with: Data(document.utf8), replacing: files.protocolFile != nil)
        return [templateWarning, incompleteWarning, trashWarning].compactMap(\.self)
    }

    /// The provider's protocol, and a warning when the local model stopped at
    /// its output limit. A local generation's other outcomes end the run with
    /// their own reasons (spec R11), and it does not start while the local
    /// model is held for a recording; every other failure is the generic one.
    private func makeProtocol(
        with generator: sending any ProtocolGenerating, asJob jobID: UUID?,
        request: (transcript: String, title: String, meetingStartTime: Date?, instructions: ProtocolInstructions),
    ) async throws -> (text: String, incompleteWarning: String?) {
        #if !APPSTORE
            let localGate = (generator as? LocalModelProtocolGenerator)?.gate
            // The gate would wait for the recording to end; a regeneration does not start.
            if localGate?.isRecordingActive == true { throw ProtocolRegenerationError.recording }
        #endif
        do {
            let text = try await Self.generate(with: generator, asJob: jobID, request: request)
            #if !APPSTORE
                if localGate != nil { environment.notifier.endLocalModelNoticeEpisodes() }
            #endif
            return (text, nil)
        } catch {
            #if !APPSTORE
                if let outcome = error as? LocalModelOutcome {
                    logger.warning("protocol_regeneration_local_outcome \(outcome.description, privacy: .public)")
                    guard case let .incomplete(text) = outcome else {
                        throw Self.regenerationError(for: outcome, recordOnly: environment.recordOnly())
                    }
                    environment.notifier.endLocalModelNoticeEpisodes()
                    return (text, LocalModelNotice.incompleteWarning)
                }
            #endif
            logger.warning("protocol_regeneration_provider_failed type=\(String(describing: type(of: error)), privacy: .public)")
            throw ProtocolRegenerationError.generationFailed
        }
    }

    /// The provider call. A local generation runs as the meeting's job
    /// (`target.jobID`), so the local model's gate records which job owns its
    /// helper (spec R10). Nothing asks again after a recording ended the
    /// helper: a regeneration is not resumed by itself (spec R11).
    private static func generate(
        with generator: sending any ProtocolGenerating, asJob jobID: UUID?,
        request: (transcript: String, title: String, meetingStartTime: Date?, instructions: ProtocolInstructions),
    ) async throws -> String {
        let diarized = ProtocolGenerator.looksDiarized(request.transcript)
        #if !APPSTORE
            if let local = generator as? LocalModelProtocolGenerator {
                return try await LocalModelGate.$jobID.withValue(jobID) {
                    try await local.generate(
                        transcript: request.transcript, title: request.title, diarized: diarized,
                        meetingStartTime: request.meetingStartTime, instructions: request.instructions,
                    )
                }
            }
        #endif
        return try await generator.generate(
            transcript: request.transcript, title: request.title, diarized: diarized,
            meetingStartTime: request.meetingStartTime, instructions: request.instructions,
        )
    }

    private func isBusy(_ target: ProtocolRegenerationTarget) -> Bool {
        environment.queuedJobs().contains { !$0.state.isTerminal && target.isOwned(by: $0) }
    }

    /// Writes an owner-only staging file, renames the old protocol aside,
    /// renames the staging file into place (renaming the old one back if that
    /// fails), and only then trashes the old one. Until the last rename the
    /// original stays at its path. Renames, not `replaceItemAt`, whose failure
    /// states are undocumented. Returns a warning when the Trash refused.
    private func replaceProtocol(of target: ProtocolRegenerationTarget, with data: Data, replacing: Bool) throws -> String? {
        let ops = environment.fileOperations
        let staging = target.folder.appendingPathComponent("\(target.basename).md.regenerating")
        do {
            try ops.createEmpty(staging)
        } catch {
            throw ProtocolRegenerationError.writeFailed(error.localizedDescription)
        }
        do {
            try ops.restrictToOwner(staging)
            try ops.write(data, staging)
        } catch {
            try? ops.remove(staging)
            throw ProtocolRegenerationError.writeFailed(error.localizedDescription)
        }
        var previous: URL?
        if replacing {
            let stamp = Self.previousStamp.string(from: environment.now())
            let aside = target.folder.appendingPathComponent("\(target.basename).previous-\(stamp).md")
            do {
                try ops.move(target.protocolURL, aside)
            } catch {
                try? ops.remove(staging)
                throw ProtocolRegenerationError.writeFailed(error.localizedDescription)
            }
            previous = aside
        }
        do {
            try ops.move(staging, target.protocolURL)
        } catch {
            try? ops.remove(staging)
            if let previous {
                do {
                    try ops.move(previous, target.protocolURL)
                } catch {
                    throw ProtocolRegenerationError.restoreFailed(keptAs: previous.lastPathComponent)
                }
            }
            throw ProtocolRegenerationError.writeFailed(error.localizedDescription)
        }
        guard let previous else { return nil }
        do {
            try ops.trash(previous)
            return nil
        } catch {
            return "The previous protocol could not be moved to the Trash and was kept as \(previous.lastPathComponent)."
        }
    }

    private func withOutputScope<T>(_ body: () throws -> T) rethrows -> T {
        let scope = environment.outputDir()
        let accessing = scope.startAccessingSecurityScopedResource()
        defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

#if !APPSTORE

    // MARK: - Local model

    extension ProtocolRegenerator: LocalModelNoticeResponding {
        static let backgroundLostNote = "The background info was not used: the app has restarted since the protocol was due."

        /// How a regeneration ends for a local outcome other than a protocol
        /// (spec R11). A recording ending the helper is not resumed; in
        /// record-only mode, which holds the local model the same way, that
        /// mode is the reason. A prompt too long, a deadline and any other
        /// failure stay the generic failure, as they are for a queued job.
        static func regenerationError(for outcome: LocalModelOutcome, recordOnly: Bool) -> ProtocolRegenerationError {
            switch outcome {
            case .deferredForRecording: recordOnly ? .recordOnly : .recording
            case .lowMemory: .lowMemory
            case .noModel: .noLocalModel
            case .incomplete, .promptTooLong, .deadline, .failure: .generationFailed
            }
        }

        /// Try Again on a local-model notice (spec R4): the meeting's protocol
        /// stage alone, as a regeneration with the template and background it
        /// was due with. A refusal (record-only mode, a recording, the meeting
        /// still in the queue) is that regeneration's failure notification.
        /// False only when the meeting's files are gone.
        func tryAgain(_ meeting: LocalModelNoticeMeeting) async -> Bool {
            guard let resolved = try? target(for: meeting.transcriptURL) else { return false }
            // A meeting without a finished-job record still runs as its job.
            let target = resolved.jobID != nil ? resolved : ProtocolRegenerationTarget(
                folder: resolved.folder, basename: resolved.basename, title: meeting.title,
                meetingStartTime: resolved.meetingStartTime, jobID: meeting.jobID.uuidString, files: resolved.files,
            )
            guard !isRunning else {
                let reason = ProtocolRegenerationError.regenerationRunning.localizedDescription
                environment.notifier.notify(title: Self.failedTitle, body: "\(target.title): \(reason)")
                return true
            }
            let options = MeetingProtocolOptions(template: meeting.template, rawBackground: meeting.background ?? "")
            let backgroundLost = meeting.hadBackground && meeting.background == nil
            await regenerate(target, options: options, notes: backgroundLost ? [Self.backgroundLostNote] : [])
            return true
        }
    }
#endif
