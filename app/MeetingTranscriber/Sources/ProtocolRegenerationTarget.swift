import Foundation

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
    /// The folder as it was read for the meeting's additional reports, which the
    /// sheet counts and checks the chosen template's report name against. Nil
    /// when it was not read or could not be listed.
    var reportFolder: MeetingReportFolder?

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

    /// The meeting's additional reports as its folder was read.
    var reports: [AdditionalReport.Listed] {
        reportFolder?.reports ?? []
    }

    /// Where `template`'s additional report would go, by the folder as it was read.
    func reportSlot(for template: ProtocolTemplateID) -> MeetingReportFolder.Slot {
        let name = AdditionalReport.name(of: template)
        return reportFolder?.slot(forReportNamed: name)
            ?? .free(fileName: AdditionalReport.fileName(basename: basename, name: name))
    }

    /// The same meeting with its two files and its reports read again.
    func readAgain(
        read: (URL) -> Data?,
        list: (URL) -> [String]?, // swiftlint:disable:this discouraged_optional_collection
    ) -> Self {
        Self(
            folder: folder, basename: basename, title: title, meetingStartTime: meetingStartTime, jobID: jobID,
            files: Self.readFiles(folder: folder, basename: basename, read: read),
            reportFolder: MeetingReportFolder.read(folder: folder, basename: basename, list: list, read: read),
        )
    }

    /// `<basename>.txt` and `<basename>.md` in `folder`, read now.
    static func readFiles(folder: URL, basename: String, read: (URL) -> Data?) -> ProtocolRegenerationFiles {
        ProtocolRegenerationFiles(
            transcriptFile: read(folder.appendingPathComponent("\(basename).txt")),
            protocolFile: read(folder.appendingPathComponent("\(basename).md")),
        )
    }

    /// The meeting `file` belongs to. An additional report belongs to the meeting
    /// the ownership rule gives it to (`AdditionalReport.owner`), any other file to
    /// its own name. Its title, start and job come from the newest finished-job
    /// record naming either of the meeting's two files; without one the title is
    /// the meeting's file name without its timestamp prefix.
    static func resolve(
        // swiftlint:disable:next discouraged_optional_collection
        file: URL, records: [TerminalJobRecord], read: (URL) -> Data?, list: (URL) -> [String]? = { _ in nil },
    ) throws -> Self {
        let folder = file.deletingLastPathComponent()
        let basename = meetingBasename(of: file, read: read, list: list)
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
            reportFolder: MeetingReportFolder.read(folder: folder, basename: basename, list: list, read: read),
        )
    }

    /// The name of the meeting a chosen file stands for: a Markdown file with no
    /// transcript file of its own, whose name the ownership rule gives to a meeting
    /// with a transcript, stands for that meeting; every other file for itself. The
    /// folder's listing tells whether that transcript file is there, so one that
    /// cannot be read still makes the file a meeting; without a listing, reading it
    /// tells.
    static func meetingBasename(
        // swiftlint:disable:next discouraged_optional_collection
        of file: URL, read: (URL) -> Data?, list: (URL) -> [String]? = { _ in nil },
    ) -> String {
        let folder = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent
        let transcriptName = MeetingReportFolder.folded("\(stem).txt")
        let hasTranscriptFile = list(folder).map { $0.contains { MeetingReportFolder.folded($0) == transcriptName } }
            ?? (read(folder.appendingPathComponent("\(stem).txt")) != nil)
        guard file.pathExtension == "md", !hasTranscriptFile,
              let owner = AdditionalReport.owner(ofStem: stem, hasTranscript: { meeting in
                  AdditionalReport.hasTranscript(folder: folder, stem: meeting, read: read)
              })
        else { return stem }
        return owner.meeting
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
