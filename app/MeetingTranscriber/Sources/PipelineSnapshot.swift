import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineSnapshot")

/// Pure I/O helpers for persisting `PipelineQueue`'s `[PipelineJob]` array
/// to disk and reading it back. Extracted from `PipelineQueue` so the
/// serialization + atomic-rename mechanics can be exercised without
/// constructing a full queue + speaker DB + engine wiring, and so the
/// save side can later run off the main actor without touching the rest
/// of `PipelineQueue`'s `@MainActor` surface.
///
/// File names mirror what `PipelineQueue` used inline before the
/// extraction (`pipeline_queue.json` final, `pipeline_queue.tmp` staging)
/// so existing on-disk snapshots load unchanged after upgrade.
enum PipelineSnapshot {
    static let snapshotFilename = "pipeline_queue.json"
    static let stagingFilename = "pipeline_queue.tmp"

    /// JSON-encode `jobs` and atomically replace any existing snapshot at
    /// `logDir/pipeline_queue.json`. The staging write goes to
    /// `pipeline_queue.tmp` first; `replaceItemAt` (which lowers to
    /// `renamex_np` on macOS) swaps it in.
    ///
    /// Both files are owner-only: a job carries the meeting's title, its
    /// participants and the background info typed for its protocol.
    ///
    /// - Throws: `EncodingError` from JSONEncoder, or any `FileManager` /
    ///   `FileHandle` I/O error. A failed replace leaves no staging file.
    static func save(_ jobs: [PipelineJob], to logDir: URL) throws {
        try save(jobs, to: logDir) { snapshot, staging in
            _ = try FileManager.default.replaceItemAt(snapshot, withItemAt: staging)
        }
    }

    /// `save` with the swap passed in, so a test can look at the staging file
    /// at the moment it is swapped in, or make the swap fail.
    static func save(
        _ jobs: [PipelineJob], to logDir: URL, replace: (_ snapshot: URL, _ staging: URL) throws -> Void,
    ) throws {
        let data = try JSONEncoder().encode(jobs)
        let stagingPath = logDir.appendingPathComponent(stagingFilename)
        try writeOwnerOnly(data, to: stagingPath)
        let snapshotPath = logDir.appendingPathComponent(snapshotFilename)
        do {
            try replace(snapshotPath, stagingPath)
        } catch {
            try? FileManager.default.removeItem(at: stagingPath)
            throw error
        }
        // `replaceItemAt` keeps the replaced file's permissions, so a snapshot
        // written before this was owner-only stays readable until restricted.
        do {
            try FileManager.default.restrictToOwner(snapshotPath)
        } catch {
            logger.error("pipeline_snapshot_restrict_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Creates `url` empty and owner-only, then writes `data` into it, so no
    /// byte is ever in a file other users can read. `Data.write` would create
    /// the file under the process umask (typically 0644) with the bytes in it.
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let created = FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: FileManager.ownerOnlyPermissions],
        )
        guard created else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    // swiftlint:disable discouraged_optional_collection
    /// Read + JSON-decode the snapshot at `logDir/pipeline_queue.json`.
    ///
    /// - Returns: the decoded jobs, or `nil` if no snapshot file exists.
    ///   `nil` vs an empty array is load-bearing: the caller logs a
    ///   different message ("No pipeline snapshot to restore" vs
    ///   "Snapshot loaded but no recoverable jobs") so flattening into
    ///   `[]` on missing-file would lose that distinction.
    /// - Throws: any read or `DecodingError` failure. Caller decides how
    ///   to recover (PipelineQueue logs + drops the load).
    static func load(from logDir: URL) throws -> [PipelineJob]? {
        let snapshotPath = logDir.appendingPathComponent(snapshotFilename)
        guard FileManager.default.fileExists(atPath: snapshotPath.path) else {
            return nil
        }
        let data = try Data(contentsOf: snapshotPath)
        return try JSONDecoder().decode([PipelineJob].self, from: data)
    }
    // swiftlint:enable discouraged_optional_collection
}
