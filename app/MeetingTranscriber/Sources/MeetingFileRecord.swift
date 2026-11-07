import Foundation

/// One meeting's files and what has happened to them, from the moment the
/// meeting enters processing. Keyed by the job's id and kept in
/// `MeetingFileStore`, apart from the finished-job list, which forgets a job
/// after 1000 newer ones.
///
/// Deleting a meeting's files reads this record and nothing else: a deletion
/// only ever touches a path listed here, never one derived from a file name or
/// a folder, so the record has to follow every file as the pipeline moves it.
struct MeetingFileRecord: Codable, Equatable, Sendable {
    /// How the meeting started, set once. Ownership of the source audio comes
    /// from this and never from where a file sits: an imported file the user
    /// placed inside the recordings folder is still theirs.
    enum Origin: String, Codable, Sendable {
        case recorded
        case imported

        /// Whether a file in `role` is the app's to delete. Only the source
        /// tracks can belong to someone else; every other role is a file the
        /// pipeline wrote itself, also for an import.
        func owns(_ role: MeetingFile.Role) -> Bool {
            !role.isSourceTrack || self == .recorded
        }
    }

    enum Outcome: Codable, Equatable, Sendable {
        case inProgress
        /// `protocolExpected` is whether protocol generation was on: a protocol
        /// that failed to generate or save still finishes the job, so a finished
        /// meeting alone does not mean there are notes.
        case finished(protocolExpected: Bool)
        case failed
        case leftUnfinished
    }

    /// When a meeting's audio went, and how.
    struct AudioDeletion: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case manual
            case automatic
        }

        let kind: Kind
        let at: Date
    }

    /// What a deletion was asked to do.
    enum DeletionKind: String, Codable, Sendable {
        case audioToTrash = "audio_to_trash"
        case meetingToTrash = "meeting_to_trash"
        case automatic
    }

    /// A manual deletion that could not remove every file, and how to retry it.
    struct DeletionFailure: Codable, Equatable, Sendable {
        let reason: String
        let paths: [String]
        let kind: DeletionKind
    }

    /// A deletion that was saved before it touched its first file, so a crash
    /// during it can be told from a deletion that never started.
    struct PendingDeletion: Codable, Equatable, Sendable {
        let kind: DeletionKind
        let paths: [String]
        /// Who is doing it: another running build's deletion is not an abandoned one.
        var process = DeletionProcess.current
    }

    let jobID: UUID
    let origin: Origin
    /// The recording start, or for a recording without one the time it entered
    /// processing, which only ever keeps its audio longer. Nil for an import,
    /// which is never deleted automatically. Written once, also not changed by
    /// a Retry.
    let recordingDate: Date?
    var files: [MeetingFile]
    var keep = false
    var outcome = Outcome.inProgress
    var audioDeletion: AudioDeletion?
    var incomplete: DeletionFailure?
    var pending: PendingDeletion?
    var excludedFromAutomaticDeletion = false
    var savedToNotion = false
    /// The bundle identifier of the build that created the record, written once when
    /// it is created and never changed. The development and the release build share
    /// the record file but each has its own retention setting, so the automatic
    /// deletion acts only on the records of its own build. Nil in a record from before
    /// this field, or from a build without an identifier: never deleted automatically.
    var createdBy: String?
}

extension MeetingFileRecord {
    /// A new record for a job entering processing, listing the source tracks it
    /// carries. `createdBy` is the running build's bundle identifier
    /// (`MeetingFileStore.bundleID`).
    init(job: PipelineJob, origin: Origin, createdBy: String?) {
        let tracks: [(role: MeetingFile.Role, url: URL?)] = [
            (.mix, job.mixPath), (.appTrack, job.appPath), (.micTrack, job.micPath),
        ]
        self.init(
            jobID: job.id,
            origin: origin,
            recordingDate: origin == .recorded ? job.artifactStartTime : nil,
            files: tracks.compactMap { track in
                track.url.map { MeetingFile(role: track.role, url: $0, owned: origin.owns(track.role)) }
            },
            createdBy: createdBy,
        )
    }

    /// Every field after `jobID`, `origin` and `files` may be missing, so a field
    /// a later version adds never makes a whole record unreadable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            jobID: container.decode(UUID.self, forKey: .jobID),
            origin: container.decode(Origin.self, forKey: .origin),
            recordingDate: container.decodeIfPresent(Date.self, forKey: .recordingDate),
            files: container.decode([MeetingFile].self, forKey: .files),
            keep: container.decodeIfPresent(Bool.self, forKey: .keep) ?? false,
            outcome: container.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .inProgress,
            audioDeletion: container.decodeIfPresent(AudioDeletion.self, forKey: .audioDeletion),
            incomplete: container.decodeIfPresent(DeletionFailure.self, forKey: .incomplete),
            pending: container.decodeIfPresent(PendingDeletion.self, forKey: .pending),
            excludedFromAutomaticDeletion: container
                .decodeIfPresent(Bool.self, forKey: .excludedFromAutomaticDeletion) ?? false,
            savedToNotion: container.decodeIfPresent(Bool.self, forKey: .savedToNotion) ?? false,
            createdBy: container.decodeIfPresent(String.self, forKey: .createdBy),
        )
    }

    /// List `file` under its role. A write to a listed path replaces that entry,
    /// and any other file of the role leaves the record unless `keeping` names it.
    /// A role usually has one file; it has more when a run wrote to another output
    /// folder and the first still holds its file, which a deletion has to find.
    /// Whether that file is still there is for the caller to ask the disk
    /// (`MeetingFileStore.list`), as this runs under the store's lock.
    mutating func list(_ file: MeetingFile, keeping: Set<String> = []) {
        files.removeAll { $0.role == file.role && $0.path != file.path && !keeping.contains($0.path) }
        if let index = files.firstIndex(where: { $0.role == file.role && $0.path == file.path }) {
            files[index] = file
        } else {
            files.append(file)
        }
    }

    /// The files a deletion of `kind` covers: what the app owns of the meeting and
    /// has not seen go, each path once. A path this record also lists as not owned
    /// stays out: one file can sit under two roles, and it is the user's under either.
    func filesCovered(by kind: DeletionKind) -> [MeetingFile] {
        let notOwned = Set(files.filter { !$0.owned }.map(\.path))
        var seen = Set<String>()
        return files.filter { file in
            file.owned && file.state != .gone && !notOwned.contains(file.path)
                && (kind == .meetingToTrash || file.role.isAudio)
                && seen.insert(file.path).inserted
        }
    }

    /// What a launch makes of a deletion that stopped on its way, from the paths
    /// the disk answered are `gone`. A file marked as being deleted and still
    /// there, or out of reach, is listed as present again.
    ///
    /// True when only the record itself is left to remove: `pending` then stays, so
    /// a crash before the caller is through ends up here again at the next launch.
    mutating func settleInterrupted(_ pending: PendingDeletion, gone: Set<String>, at now: Date) -> Bool {
        for index in files.indices where files[index].state != .gone {
            if gone.contains(files[index].path) {
                files[index].state = .gone
            } else if files[index].state == .deleting {
                files[index].state = .present
            }
        }
        let left = files.filter { $0.state != .gone && pending.paths.contains($0.path) }.map(\.path)
        switch (pending.kind, left.isEmpty) {
        case (.meetingToTrash, true):
            return true

        case (.audioToTrash, true):
            audioDeletion = AudioDeletion(kind: .manual, at: now)
            incomplete = nil

        case (.automatic, true):
            audioDeletion = AudioDeletion(kind: .automatic, at: now)

        case (.automatic, false):
            break // The next check tries again; "incomplete" is for manual deletions.

        case (.audioToTrash, false), (.meetingToTrash, false):
            incomplete = DeletionFailure(reason: Self.interruptedReason, paths: left, kind: pending.kind)
        }
        self.pending = nil
        return false
    }

    static let interruptedReason = "the app quit before the deletion finished"

    /// Follow a file moved on disk: only its path changes. A rename within a
    /// folder keeps the file, so the recorded identity still names it.
    mutating func followMove(from source: String, to destination: String) {
        for index in files.indices where files[index].path == source {
            files[index].path = destination
        }
    }
}

/// One file of a meeting.
struct MeetingFile: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case mix
        case appTrack = "app_track"
        case micTrack = "mic_track"
        case mix16k = "mix_16k"
        case app16k = "app_16k"
        case mic16k = "mic_16k"
        case segments
        case naming
        case transcript
        case `protocol`
        case previousProtocol = "previous_protocol"

        /// The three tracks a job carries, which are the user's own on an import.
        var isSourceTrack: Bool {
            switch self {
            case .mix, .appTrack, .micTrack: true
            default: false
            }
        }

        var isAudio: Bool {
            switch self {
            case .mix, .appTrack, .micTrack, .mix16k, .app16k, .mic16k: true
            default: false
            }
        }
    }

    enum State: String, Codable, Sendable {
        case present
        case deleting
        case gone
    }

    let role: Role
    /// The full path, with symbolic links resolved when the file was recorded.
    var path: String
    /// The file on disk this entry means, taken when it was listed. Nil when
    /// nothing was there to read it from.
    var identity: FileIdentity?
    let owned: Bool
    var state: State
}

extension MeetingFile {
    /// `url` as it stands on disk right now.
    init(role: Role, url: URL, owned: Bool) {
        let path = Self.resolvedPath(url)
        self.init(role: role, path: path, identity: FileIdentity.of(path), owned: owned, state: .present)
    }

    /// The spelling a listed path is stored and compared in. Read it while the
    /// file exists: `resolvingSymlinksInPath()` strips a leading `/private` only
    /// from the name of an existing file, so the same path reads differently
    /// once the file has moved away.
    static func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
