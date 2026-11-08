import Foundation

/// A meeting's additional reports as Move Meeting to Trash finds them on disk: the
/// files the ownership rule (`AdditionalReport`) gives the name of a transcript or
/// notes file its record lists, in that file's folder. They are found by name, as no
/// record lists a report the regenerator wrote, and enter the record when the
/// deletion is saved (`MeetingFileStore.beginDeletion`), so a crash or a retry
/// carries them like every other file.
struct MeetingReportScan: Equatable {
    /// What the scan asks the disk; a test hands in its own answers.
    struct Disk {
        var presence: (String) -> MeetingFilePresence = MeetingFilePresence.of
        // swiftlint:disable:next discouraged_optional_collection
        var list: (URL) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }
        var read: (URL) -> Data? = { try? Data(contentsOf: $0) }
        /// The identity of a regular file at the path, nil for anything else: a
        /// report-named symbolic link or folder is never a report to move.
        var regularFile: (String) -> FileIdentity? = { path in
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
        }
    }

    /// The row's text when a folder could not be read (spec A12).
    static let unreadableFolderReason = "the notes folder could not be read to look for additional reports"

    /// Each report found, as the record lists it once the deletion is saved: owned,
    /// under `previousProtocol`, with the identity it has now.
    var reports: [MeetingFile] = []
    /// A folder of the meeting's notes that is there but could not be listed, or is
    /// out of reach: Move Meeting to Trash then moves nothing, as it cannot tell
    /// which reports would stay behind.
    var unreadableFolder = false

    var paths: [String] {
        reports.map(\.path)
    }

    /// A folder that is gone holds no report. One the record names that now
    /// resolves elsewhere (replaced by a link, moved) counts as unreadable and is
    /// not looked into, as gh-97's remover refuses a file in such a folder.
    static func scan(_ record: MeetingFileRecord, disk: Disk = Disk()) -> Self {
        var result = Self()
        var seen = Set<String>()
        for meeting in meetings(of: record) {
            let folder = URL(filePath: meeting.folder, directoryHint: .isDirectory)
            switch disk.presence(meeting.folder) {
            case .gone:
                continue

            case .unreachable:
                result.unreadableFolder = true

            case .present:
                guard MeetingFile.resolvedPath(folder) == folder.path else {
                    result.unreadableFolder = true
                    continue
                }
                guard let found = MeetingReportFolder.read(folder: folder, basename: meeting.basename, list: disk.list, read: disk.read) else {
                    result.unreadableFolder = true
                    continue
                }
                for report in found.reports {
                    let path = folder.appendingPathComponent(report.fileName).path
                    guard let identity = disk.regularFile(path), seen.insert(path).inserted else { continue }
                    result.reports.append(MeetingFile(role: .previousProtocol, path: path, identity: identity, owned: true, state: .present))
                }
            }
        }
        return result
    }

    /// Each folder and name the record's transcript and notes files have, gone ones
    /// too: a meeting whose notes already went keeps its reports.
    static func meetings(of record: MeetingFileRecord) -> [(folder: String, basename: String)] {
        var seen = Set<String>()
        return record.files.filter { $0.role == .transcript || $0.role == .protocol }.compactMap { file in
            let url = URL(filePath: file.path, directoryHint: .notDirectory)
            let meeting = (folder: url.deletingLastPathComponent().path, basename: url.deletingPathExtension().lastPathComponent)
            return seen.insert("\(meeting.folder)/\(meeting.basename)").inserted ? meeting : nil
        }
    }

    /// Whether `path` names a report of a meeting another record also lists, by its
    /// transcript or notes: a meeting two records share keeps its reports, as it keeps
    /// the shared files themselves.
    static func isReportOfASharedMeeting(_ path: String, jobID: UUID, in records: [MeetingFileRecord]) -> Bool {
        guard let own = records.first(where: { $0.jobID == jobID }) else { return false }
        let url = URL(filePath: path, directoryHint: .notDirectory)
        let folder = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let meetingFiles = Set(meetings(of: own).filter { $0.folder == folder && name.hasPrefix("\($0.basename) (") }.flatMap { meeting in
            ["\(folder)/\(meeting.basename).txt", "\(folder)/\(meeting.basename).md"]
        })
        guard !meetingFiles.isEmpty else { return false }
        return records.contains { other in
            other.jobID != jobID && other.files.contains { $0.state != .gone && meetingFiles.contains($0.path) }
        }
    }
}
