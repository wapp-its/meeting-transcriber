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
}

extension MeetingFileRecord {
    /// A new record for a job entering processing, listing the source tracks it
    /// carries.
    init(job: PipelineJob, origin: Origin) {
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
        )
    }

    /// List `file` under its role, in place of whatever that role listed: a role
    /// has one file at a time, and the newest write of it is the one on disk.
    mutating func list(_ file: MeetingFile) {
        if let index = files.firstIndex(where: { $0.role == file.role }) {
            files[index] = file
        } else {
            files.append(file)
        }
    }

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
