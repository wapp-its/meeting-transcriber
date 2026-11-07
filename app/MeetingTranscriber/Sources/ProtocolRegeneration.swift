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
            "No transcript was found for this meeting: there is no transcript file beside it, and its meeting notes have no Full Transcript section."

        case .providerOff:
            ProtocolDestination.off.notice

        case .recordOnly:
            "Record-only mode is on: no meeting notes are made on this Mac."

        case .meetingBusy:
            "This meeting is still being processed. Try again once it has finished."

        case .filesChanged:
            "The meeting's files changed while the meeting notes were being made, so nothing was replaced."

        case .generationFailed:
            "Meeting notes generation failed, so nothing was replaced."

        case let .writeFailed(reason):
            "The new meeting notes could not be saved, so the previous ones were left in place: \(reason)"

        case let .restoreFailed(keptAs):
            "The new meeting notes could not be saved, and the previous ones could not be put back. They are kept as \(keptAs)."

        #if !APPSTORE
            case .recording:
                "The meeting notes were not made because a recording is running. Start it again once the recording has ended."

            case .lowMemory:
                "There was not enough free memory for the local model, so nothing was replaced."

            case .noLocalModel:
                "No local model is chosen, or it cannot be reached, so nothing was replaced. Choose one in Settings → Output."

            case .regenerationRunning:
                "Other meeting notes are being made. Try again once they are finished."
        #endif
        }
    }
}

// MARK: - File operations

/// Every file access a regeneration makes, so a test can make any single step
/// fail and never touches the real Trash.
struct ProtocolRegenerationFileOperations {
    /// Nil when nothing readable is there.
    var read: (URL) -> Data?
    var fileExists: (URL) -> Bool
    /// A folder's file names; nil when it cannot be listed.
    var list: (URL) -> [String]? // swiftlint:disable:this discouraged_optional_collection
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
            list: { try? FileManager.default.contentsOfDirectory(atPath: $0.path) },
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

/// What "Save as:" chose in the regenerate sheet.
enum ProtocolRegenerationOutput: Equatable {
    /// The meeting's main protocol, replaced as before.
    case mainProtocol
    /// The chosen template's additional report beside it, which the main protocol
    /// and every other report outlive (`AdditionalReport`).
    case additionalReport
}

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
        /// Called after a run replaced the notes of a meeting that has a job,
        /// with the template the run was asked for: a retried Notion export
        /// reads those notes and titles its page by that template's rule
        /// (`ProtocolGenerator.aiTitle`).
        var regenerated: @MainActor (_ jobID: UUID, _ template: ProtocolTemplateID) -> Void = { _, _ in }
        /// Called with what a run left on disk for a meeting that has a job, for
        /// its file record (`MeetingFileStore.noteProtocolReplaced`). The rename
        /// into place gives the path a new file, which the record has to name, or
        /// a later deletion refuses the app's own file as replaced.
        var protocolReplaced: @MainActor (_ jobID: UUID, _ current: URL?, _ keptPrevious: URL?) -> Void = { _, _, _ in }
        /// Called with an old additional report a run kept on disk under a name of
        /// its own (the Trash refused it, or it could not be put back), for the
        /// meeting's file record (`MeetingFileStore.noteKeptFile`): Move Meeting to
        /// Trash finds it there, as no report rule names it any more. A report run
        /// calls neither hook above: its file is no protocol of the meeting.
        var reportKept: @MainActor (_ jobID: UUID, _ kept: URL) -> Void = { _, _ in }
    }

    static let succeededTitle = "Meeting Notes Regenerated"
    static let failedTitle = "Meeting Notes Not Regenerated"

    private static let previousStamp = DateFormatter.filenameStamp("yyyyMMdd_HHmmss")

    private(set) var phase: Phase = .idle
    @ObservationIgnored let environment: Environment

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
                list: environment.fileOperations.list,
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
        let ops = environment.fileOperations
        let (files, reportFolder) = withOutputScope {
            (
                ProtocolRegenerationTarget.readFiles(folder: folder, basename: basename, read: ops.read),
                MeetingReportFolder.read(folder: folder, basename: basename, list: ops.list, read: ops.read),
            )
        }
        guard files.transcript != nil else { throw ProtocolRegenerationError.noTranscript }
        return ProtocolRegenerationTarget(
            folder: folder, basename: basename, title: entry.title,
            meetingStartTime: entry.meetingStartTime, jobID: entry.id.uuidString, files: files, reportFolder: reportFolder,
        )
    }

    /// Generates, then replaces the meeting's protocol, or writes the template's
    /// additional report beside it; the outcome lands in `phase` and a
    /// notification. Ignored while a run is going. `notes` join a success's
    /// warnings. Only a run that wrote the main protocol tells the job its
    /// template: a retried Notion export titles the page by it and sends the
    /// main protocol (spec A7).
    func regenerate(
        _ target: ProtocolRegenerationTarget, options: MeetingProtocolOptions,
        saveAs: ProtocolRegenerationOutput = .mainProtocol, notes: [String] = [],
    ) async {
        guard !isRunning else { return }
        phase = .running
        let scope = environment.outputDir()
        let accessing = scope.startAccessingSecurityScopedResource()
        defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
        let backgroundPresence = options.background == nil ? "absent" : "present"
        let output = saveAs == .additionalReport ? "report" : "notes"
        logger.info(
            "protocol_regeneration_started job=\(target.jobID ?? "none", privacy: .public) background=\(backgroundPresence, privacy: .public) output=\(output, privacy: .public)",
        )
        do {
            let (written, runWarnings) = try await run(target, options: options, saveAs: saveAs)
            let warnings = runWarnings + notes
            logger.info("protocol_regenerated job=\(target.jobID ?? "none", privacy: .public)")
            if written == target.protocolURL, let jobID = target.jobID.flatMap(UUID.init(uuidString:)) {
                environment.regenerated(jobID, options.template)
            }
            phase = .succeeded(written, warnings: warnings)
            environment.notifier.notify(title: Self.succeededTitle, body: ([target.title] + warnings).joined(separator: "\n"))
        } catch {
            let reason = error.localizedDescription
            logger.warning("protocol_regeneration_failed error=\(reason, privacy: .private)")
            phase = .failed(reason)
            environment.notifier.notify(title: Self.failedTitle, body: "\(target.title): \(reason)")
        }
    }

    /// The file written, and the run's warnings.
    private func run(
        _ target: ProtocolRegenerationTarget, options: MeetingProtocolOptions, saveAs: ProtocolRegenerationOutput,
    ) async throws -> (written: URL, warnings: [String]) {
        guard let generator = environment.generatorFactory() else { throw ProtocolRegenerationError.providerOff }
        guard !environment.recordOnly() else { throw ProtocolRegenerationError.recordOnly }
        guard !isBusy(target) else { throw ProtocolRegenerationError.meetingBusy }
        let read = environment.fileOperations.read
        let files = ProtocolRegenerationTarget.readFiles(folder: target.folder, basename: target.basename, read: read)
        guard let transcript = files.transcript else { throw ProtocolRegenerationError.noTranscript }
        // A meeting without notes gets them as its main protocol, whatever was chosen.
        let reportName = saveAs == .additionalReport && files.protocolFile != nil ? AdditionalReport.name(of: options.template) : nil
        let report = reportName.map { target.folder.appendingPathComponent(AdditionalReport.fileName(basename: target.basename, name: $0)) }
        // The report the run would write counts among the meeting's files.
        let reportBefore = report.flatMap(read)
        // The only copy of the transcript is never left in the Trash alone.
        let includeFullTranscript = environment.includeFullTranscript() || transcript.fromProtocol
        let (instructions, _, templateWarning) = environment.templateStore.instructions(
            for: options.template, background: options.background,
        )
        let (protocolMarkdown, incompleteWarning) = try await makeProtocol(
            with: generator, asJob: target.jobID.flatMap(UUID.init(uuidString:)),
            request: (transcript: transcript.text, title: target.title, meetingStartTime: target.meetingStartTime, instructions: instructions),
        )
        // A Retry may have started, or even finished and rewritten both
        // files, while the provider was working.
        guard !isBusy(target) else { throw ProtocolRegenerationError.meetingBusy }
        let current = ProtocolRegenerationTarget.readFiles(folder: target.folder, basename: target.basename, read: read)
        guard current == files else { throw ProtocolRegenerationError.filesChanged }
        if let report, let reportName {
            guard read(report) == reportBefore else { throw ProtocolRegenerationError.filesChanged }
            try checkReportIsTheMeetings(reportName, of: target)
        }
        let document = Data(ProtocolGenerator.composeDocument(
            protocolMarkdown: protocolMarkdown, transcript: transcript.text, includeFullTranscript: includeFullTranscript,
        ).utf8)
        let trashWarning = if let report {
            try replaceReport(report, of: target, with: document, replacing: reportBefore != nil)
        } else {
            try replaceProtocol(of: target, with: document, replacing: files.protocolFile != nil)
        }
        return (report ?? target.protocolURL, [templateWarning, incompleteWarning, trashWarning].compactMap(\.self))
    }

    /// The last look before a report is written: a meeting that took its name
    /// during the run (its own transcript, or a longer meeting name claiming the
    /// file) stops it, as any other change of the meeting's files does.
    private func checkReportIsTheMeetings(_ name: String, of target: ProtocolRegenerationTarget) throws {
        let ops = environment.fileOperations
        guard let folder = MeetingReportFolder.read(folder: target.folder, basename: target.basename, list: ops.list, read: ops.read) else {
            throw ProtocolRegenerationError.writeFailed("the folder of the meeting notes could not be read")
        }
        if case .otherMeeting = folder.slot(forReportNamed: name) { throw ProtocolRegenerationError.filesChanged }
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

    /// Puts new notes at the meeting's protocol path. Returns a warning when the
    /// Trash refused the old ones.
    private func replaceProtocol(of target: ProtocolRegenerationTarget, with data: Data, replacing: Bool) throws -> String? {
        let kept = try replaceFile(at: target.protocolURL, with: data, replacing: replacing) { current, kept in
            reportProtocolFiles(of: target, current: current, keptPrevious: kept)
        }
        return kept.map { "The previous meeting notes could not be moved to the Trash and were kept as \($0.lastPathComponent)." }
    }

    /// Puts an additional report in place, replacing the template's earlier one
    /// the way new notes replace the old ones; the main protocol is never touched.
    /// An old report kept under its `.previous-<stamp>` name is no report by the
    /// ownership rule, so the record learns of it instead.
    private func replaceReport(_ report: URL, of target: ProtocolRegenerationTarget, with data: Data, replacing: Bool) throws -> String? {
        let kept = try replaceFile(at: report, with: data, replacing: replacing) { _, kept in
            guard let kept, let jobID = target.jobID.flatMap(UUID.init(uuidString:)) else { return }
            environment.reportKept(jobID, kept)
        }
        return kept.map { "The previous report could not be moved to the Trash and was kept as \($0.lastPathComponent)." }
    }

    /// Writes an owner-only staging file, renames the old file aside, renames the
    /// staging file into place (renaming the old one back if that fails), and only
    /// then trashes the old one. Until the last rename the original stays at its
    /// path. Renames, not `replaceItemAt`, whose failure states are undocumented.
    /// `noteFiles` hears what a write left on disk: the file at `destination` (nil
    /// when neither the new nor the old one is there), and an old one kept beside
    /// it. Returns that old one when the Trash refused it.
    private func replaceFile(
        at destination: URL, with data: Data, replacing: Bool, noteFiles: (_ current: URL?, _ keptPrevious: URL?) -> Void,
    ) throws -> URL? {
        let ops = environment.fileOperations
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent("\(destination.lastPathComponent).regenerating")
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
            let aside = folder.appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent).previous-\(stamp).md")
            do {
                try ops.move(destination, aside)
            } catch {
                try? ops.remove(staging)
                throw ProtocolRegenerationError.writeFailed(error.localizedDescription)
            }
            previous = aside
        }
        do {
            try ops.move(staging, destination)
        } catch {
            try? ops.remove(staging)
            if let previous {
                do {
                    try ops.move(previous, destination)
                } catch {
                    noteFiles(nil, previous)
                    throw ProtocolRegenerationError.restoreFailed(keptAs: previous.lastPathComponent)
                }
            }
            throw ProtocolRegenerationError.writeFailed(error.localizedDescription)
        }
        guard let previous else {
            noteFiles(destination, nil)
            return nil
        }
        do {
            try ops.trash(previous)
            noteFiles(destination, nil)
            return nil
        } catch {
            noteFiles(destination, previous)
            return previous
        }
    }

    /// A hand-picked file has no job, and so no record to tell.
    private func reportProtocolFiles(of target: ProtocolRegenerationTarget, current: URL?, keptPrevious: URL?) {
        guard let jobID = target.jobID.flatMap(UUID.init(uuidString:)) else { return }
        environment.protocolReplaced(jobID, current, keptPrevious)
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
        static let backgroundLostNote = "The background info was not used: the app has restarted since the meeting notes were due."

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
