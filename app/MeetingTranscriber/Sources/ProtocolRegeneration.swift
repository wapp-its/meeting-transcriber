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

    /// The newest finished meeting whose transcript or protocol is still on
    /// disk and still holds a transcript.
    static func latest(
        records: [TerminalJobRecord], fileExists: (URL) -> Bool, read: (URL) -> Data?,
    ) -> Self? {
        for record in records.reversed() {
            let paths = [record.status.transcriptPath, record.status.protocolPath].compactMap(\.self)
            guard let file = paths.map(URL.init(fileURLWithPath:)).first(where: fileExists) else { continue }
            if let target = try? resolve(file: file, records: records, read: read) { return target }
        }
        return nil
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
    }

    var isRunning: Bool {
        phase == .running
    }

    /// Forget a finished run's result, so a window opened later does not show it.
    func clearResult() {
        if !isRunning { phase = .idle }
    }

    func latestTarget() -> ProtocolRegenerationTarget? {
        withOutputScope {
            ProtocolRegenerationTarget.latest(
                records: environment.records(),
                fileExists: environment.fileOperations.fileExists,
                read: environment.fileOperations.read,
            )
        }
    }

    func target(for file: URL) throws -> ProtocolRegenerationTarget {
        try withOutputScope {
            try ProtocolRegenerationTarget.resolve(
                file: file, records: environment.records(), read: environment.fileOperations.read,
            )
        }
    }

    /// Generates, then replaces the meeting's protocol; the outcome lands in
    /// `phase` and a notification. Ignored while a run is going.
    func regenerate(_ target: ProtocolRegenerationTarget, options: MeetingProtocolOptions) async {
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
            let warnings = try await run(target, options: options)
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
        let protocolMarkdown: String
        do {
            protocolMarkdown = try await generator.generate(
                transcript: transcript.text,
                title: target.title,
                diarized: ProtocolGenerator.looksDiarized(transcript.text),
                meetingStartTime: target.meetingStartTime,
                instructions: instructions,
            )
        } catch {
            logger.warning("protocol_regeneration_provider_failed type=\(String(describing: type(of: error)), privacy: .public)")
            throw ProtocolRegenerationError.generationFailed
        }
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
        return [templateWarning, trashWarning].compactMap(\.self)
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
