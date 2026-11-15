import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProcessedRecordingsLedger")

/// File-backed ledger of mix-file paths the pipeline is finished with, backing
/// `PipelineQueue`'s orphan-recovery skip list.
///
/// Finished, not succeeded. A recording lands here once its job reached any
/// terminal state, and also when the user dismisses it. Recording the failures
/// is the point: one that fails deterministically, say a silent capture that
/// yields an empty transcript, would otherwise be re-picked as an orphan on
/// every launch and fail again, with a notification each time. Re-importing by
/// hand is the intended retry and never consults this list.
///
/// Nothing else writes it: a recording the pipeline never finished is not in
/// it, however long it has been in staging. So on an install that has never
/// finished a job, which in record-only mode is every install, a recording
/// the app died during is still recovered.
///
/// Pure persistence over one JSON file (`processed_recordings.json` in
/// `logDir`): a JSON array of standardized file paths (`[String]`), written
/// atomically and restricted to owner-only (0600) like the other
/// sensitive-JSON stores, since the paths embed the account username.
/// `PipelineQueue.recoverOrphanedRecordings` reads this set to skip recordings
/// that were already processed, so they aren't re-queued as orphans on the
/// next launch.
///
/// A value type with no back-references into queue state, so it needs no
/// delegate. It self-ensures `logDir` before writes (creating it only when
/// absent) rather than sharing the queue's cached `logDirCreated` flag.
struct ProcessedRecordingsLedger {
    let logDir: URL

    var path: URL {
        logDir.appendingPathComponent("processed_recordings.json")
    }

    /// Load the set of mix paths the pipeline is finished with. Returns an
    /// empty set when the file is missing or unreadable/corrupt.
    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: path),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    /// Record that the pipeline is finished with a job's mix file. Nil mixPath
    /// (paired imports without a `_mix.wav` source) is a no-op — there's no
    /// path to track for orphan recovery.
    func markProcessed(mixPath: URL?) {
        guard let mixPath else { return }
        var paths = load()
        paths.insert(mixPath.standardizedFileURL.path)
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(Array(paths))
            try data.write(to: path, options: .atomic)
            try? FileManager.default.restrictToOwner(path)
        } catch {
            logger.error("Failed to write processed recordings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ensure `logDir` exists before a write. Skips the `createDirectory`
    /// syscall when the directory already exists (the steady-state case, since
    /// the queue creates its log dir early), so no cached flag is needed.
    private func ensureLogDir() {
        guard !FileManager.default.fileExists(atPath: logDir.path) else { return }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }
}
