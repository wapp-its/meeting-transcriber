import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// A re-run across a quit (A24): its job lives in a file of this build's own beside
/// the queue's snapshot, and at launch the meeting's record decides what becomes of
/// it, row by row of the launch table in the spec. The rows of the swap (a list of
/// renames, a stamp noted as committed) are the success path's.
extension PipelineQueue {
    /// What the launch does with a re-run job of this build's file, by its record.
    enum RerunRestore: Equatable {
        /// The marker of its stamp, running: the re-run resumes.
        case resume
        /// Its stamp noted as committed: left to the swap's own launch row.
        case keep
        /// Marked as ending, its end decided in this file, noted as ended, or no
        /// marker and no note (a record an older build rewrote): the files left go
        /// and the re-run ends as R6, from this marker.
        case finish(MeetingFileRecord.RerunMarker)
        /// No record, or another run's marker: the job goes, the record stays.
        case drop
    }

    /// This build's re-run file; nil for a queue without a record store, which
    /// admits no re-run.
    var rerunFilename: String? {
        meetingFileStore.map { PipelineSnapshot.rerunFilename(bundleID: $0.bundleID) }
    }

    /// The jobs `pipeline_queue.json` holds: every job but a re-run, and the
    /// finished entry each re-run took over, so one saved copy of that entry is
    /// there whichever of the two files lands first, at admission and at the end.
    var snapshotJobs: [PipelineJob] {
        jobs.filter { $0.rerun == nil } + jobs.compactMap { job in
            if case let .job(held) = job.rerun?.heldEntry { held } else { nil }
        }
    }

    /// Writes the re-run jobs into this build's file, staged and owner-only like the
    /// snapshot and through the same ordered writer. Skipped while there is none and
    /// none was saved before, and in a queue that could not read the file.
    func saveRerunFile() {
        guard let name = rerunFilename, !rerunFileFrozen else { return }
        let held = jobs.filter { $0.rerun != nil }
            + rerunJobsAwaitingRecord.values.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !held.isEmpty || rerunFileOwed else { return }
        rerunFileOwed = !held.isEmpty
        PipelineSnapshotStore.save(held, to: logDir, named: name) { jobs, dir in
            try PipelineSnapshot.save(jobs, to: dir, named: name)
        }
    }

    /// The re-run jobs to put back into the queue at restore, after each job of the
    /// file was decided by its record (`restoreDecision`): those that resume, in the
    /// state they were saved in (the restore resets a running stage after it decided
    /// whether the notes alone resume), and those left to the swap's row; the
    /// finished job a re-run took over, when an end here brings it back held. An
    /// unreadable file changes nothing and is not written over.
    func restoreRerunJobs() -> [PipelineJob] {
        guard let name = rerunFilename, let store = meetingFileStore else { return [] }
        let saved: [PipelineJob]
        do {
            guard let decoded = try PipelineSnapshotStore.latestJobs(in: logDir, named: name) else { return [] }
            saved = decoded
        } catch {
            logger.error("rerun_file_unreadable error=\(error.localizedDescription, privacy: .public)")
            rerunFileFrozen = true
            return []
        }
        rerunFileOwed = !saved.isEmpty
        store.reload()
        var restored: [PipelineJob] = []
        for job in saved {
            guard let rerun = job.rerun else { continue }
            let decision = Self.restoreDecision(
                for: rerun.marker, record: store.record(for: job.id), endDecided: job.state == .error,
            )
            switch decision {
            case .resume, .keep:
                restored.append(job)

            case let .finish(marker):
                // Kept as saved: the next launch reads the same row from it again.
                if !Self.closeRerun(marker, jobID: job.id, in: store).saved { rerunJobsAwaitingRecord[job.id] = job }
                if case let .job(held) = rerun.heldEntry, held.isHeldAfterCompletion { restored.append(held) }

            case .drop:
                logger.warning("[\(job.shortID, privacy: .public)] rerun_restore_dropped: its record holds no marker of it")
            }
        }
        return restored
    }

    /// Which row of the launch table a re-run job of this build's file is in.
    /// `endDecided` is a job saved in `.error`, which only a re-run whose end could
    /// not be recorded is (`endRerun`): it ends, whatever its marker says, and its
    /// copy of the marker, saved from the live job then, is the newer one.
    static func restoreDecision(
        for marker: MeetingFileRecord.RerunMarker, record: MeetingFileRecord?, endDecided: Bool,
    ) -> RerunRestore {
        guard let record else { return .drop }
        if let current = record.rerun {
            guard current.runID == marker.runID else { return .drop }
            guard current.isEnding || endDecided else { return .resume }
            return .finish(merged(marker, into: current, ownIsNewer: endDecided))
        }
        if let note = record.rerunNote, note.stamp == marker.stamp, note.committed { return .keep }
        return .finish(marker)
    }

    /// The record's marker with every file either copy lists. Where both list a
    /// file, the newer copy's identity wins: a live job's copy is newer than the
    /// record's (it is updated first, and a record update can fail), a saved job's
    /// is older (its file is written at state changes, the record at each write),
    /// unless it was saved when its end could not be recorded.
    static func merged(
        _ own: MeetingFileRecord.RerunMarker, into recorded: MeetingFileRecord.RerunMarker, ownIsNewer: Bool,
    ) -> MeetingFileRecord.RerunMarker {
        var marker = recorded
        let (newer, older) = ownIsNewer ? (own.files, recorded.files) : (recorded.files, own.files)
        let listed = Set(newer.map(\.path))
        marker.files = newer + older.filter { !listed.contains($0.path) }
        return marker
    }

    /// The launch rows that need no queue (run beside the deletions' reconcile):
    /// a marker of this build whose job this build's file does not hold ends as R6
    /// when it was marked as ending or its process has ended. Markers of the other
    /// build, and every marker while the file does not read, stay as they are.
    static func reconcileOrphanedReruns(
        in store: MeetingFileStore, logDir: URL, isRunning: (DeletionProcess) -> Bool,
    ) {
        let saved: [PipelineJob]
        do {
            saved = try PipelineSnapshotStore.latestJobs(
                in: logDir, named: PipelineSnapshot.rerunFilename(bundleID: store.bundleID),
            ) ?? []
        } catch {
            logger.error("rerun_file_unreadable error=\(error.localizedDescription, privacy: .public): every marker stays")
            return
        }
        let inFile = Set(saved.compactMap { $0.rerun?.marker.runID })
        for record in store.records {
            guard let marker = record.rerun, marker.bundleID == store.bundleID, !inFile.contains(marker.runID),
                  marker.isEnding || !isRunning(marker.process) else { continue }
            logger.info("[\(PipelineJob.shortID(for: record.jobID), privacy: .public)] rerun_orphan_ended")
            _ = closeRerun(marker, jobID: record.jobID, in: store)
        }
    }

    /// Every saved job a queue in `logDir` would restore: this build's re-run jobs
    /// first, as they win over a finished entry of their meeting, then the
    /// snapshot's. Throws when either file does not read.
    static func savedJobs(in logDir: URL, bundleID: String?) throws -> [PipelineJob] {
        let reruns = try PipelineSnapshotStore.latestJobs(in: logDir, named: PipelineSnapshot.rerunFilename(bundleID: bundleID))
        return try (reruns ?? []) + (PipelineSnapshotStore.latestJobs(in: logDir) ?? [])
    }

    /// Whether this build's re-run file holds a job, or cannot be read: either way
    /// the launch builds no queue early for an export, and the re-run waits for the
    /// first queue like any saved job.
    static func rerunFileHoldsJobs(in logDir: URL, bundleID: String?) -> Bool {
        let name = PipelineSnapshot.rerunFilename(bundleID: bundleID)
        guard let saved = try? PipelineSnapshotStore.latestJobs(in: logDir, named: name) else {
            return FileManager.default.fileExists(atPath: logDir.appendingPathComponent(name).path)
        }
        return saved.contains { $0.rerun != nil }
    }
}
