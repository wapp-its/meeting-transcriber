import Foundation

/// Whether a meeting's file is there, truly gone, or out of reach. The one probe
/// the record, its deletions and the rows ask, because "the file is not there"
/// is what an unplugged drive answers too, and only `gone` may change a record:
/// an unreachable file stays listed and comes back with its volume.
///
/// Touches the file system, so it can block on a network or removable volume;
/// never call it from a view body.
enum MeetingFilePresence: Equatable, Sendable {
    case present
    case gone
    case unreachable

    /// Built on `lstat`, so a symbolic link counts as what is at the path, and
    /// on its `errno`, which `FileManager.fileExists` throws away. Gone only on
    /// `ENOENT` while the parent folder can be opened for reading: a missing
    /// parent answers `ENOENT` as well, and that is the disconnected drive.
    static func of(_ path: String) -> Self {
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        guard errno == ENOENT else { return .unreachable }
        let folder = URL(filePath: path, directoryHint: .notDirectory).deletingLastPathComponent().path
        let parent = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return .unreachable }
        close(parent)
        return .gone
    }

    /// Whether `path` leads to a regular file the app can read, through a link too.
    /// `of` answers that something is there, which a folder or a dangling link also
    /// is, so it cannot say that a file holds anything.
    static func isReadableFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, R_OK) == 0
    }
}

/// A file's identity on disk: volume and file number from `lstat`. A rename
/// keeps it and an atomic rewrite replaces it, so a deletion can tell that the
/// file at a listed path is still the one that was listed.
struct FileIdentity: Codable, Equatable, Sendable {
    let device: Int64
    let inode: UInt64

    /// Nil when nothing is at `path` or it cannot be read.
    static func of(_ path: String) -> Self? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Self(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
