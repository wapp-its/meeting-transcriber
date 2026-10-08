import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "TerminalJobStore")

/// File-backed history of finished jobs, keyed by jobID with a bounded FIFO
/// (the newest 1000 by default) so it can't grow without limit.
///
/// `PipelineQueue` removes `.done` jobs from its in-memory list after
/// `completedJobLifetime` (default 60s). An automation client polling slower
/// than that would then get a 404 and lose the transcript/protocol paths. This
/// store outlives the reaping (and an app restart) so `GET /v1/jobs/<id>` stays
/// answerable, and so the Transcriptions window can list every finished job.
/// Only finished (`.done`/`.error`) jobs are ever recorded. Each element is a
/// `TerminalJobRecord`: the `JobStatusDTO` served on the wire plus the fields
/// the window lists, which `lookup(jobID:)` leaves behind.
///
/// Observable so the window and the menu follow `records`.
///
/// Writes are atomic (staging file + `replaceItemAt`, mirroring
/// `PipelineSnapshot`) and owner-only; reads happen on `init`.
@MainActor
@Observable
final class TerminalJobStore {
    @ObservationIgnored private let path: URL
    @ObservationIgnored private let cap: Int
    private(set) var records: [TerminalJobRecord]

    init(path: URL, cap: Int = 1000) {
        self.path = path
        self.cap = cap
        self.records = Self.load(from: path)
    }

    /// Pure: drop any record with the same jobID, append the new one, and keep
    /// only the most recent `cap` entries.
    nonisolated static func upserting(
        _ records: [TerminalJobRecord], with rec: TerminalJobRecord, cap: Int,
    ) -> [TerminalJobRecord] {
        var next = records.filter { $0.status.jobID != rec.status.jobID }
        next.append(rec)
        if next.count > cap {
            next = Array(next.suffix(cap))
        }
        return next
    }

    /// Upsert `rec` and persist. Best-effort: a write failure is logged but
    /// never throws into the pipeline (the job itself already succeeded).
    func record(_ rec: TerminalJobRecord) {
        records = Self.upserting(records, with: rec, cap: cap)
        save()
    }

    /// Record a status alone, with none of the history fields.
    func record(_ status: JobStatusDTO) {
        record(TerminalJobRecord(status: status))
    }

    /// Drop a job's record and persist, for a job that is no longer finished:
    /// a retried job answers from the live queue, and if it then leaves the
    /// queue without a new record, the old outcome must not be served for it.
    func remove(jobID: UUID) {
        let key = jobID.uuidString
        guard records.contains(where: { $0.status.jobID == key }) else { return }
        records.removeAll { $0.status.jobID == key }
        save()
    }

    func lookup(jobID: UUID) -> JobStatusDTO? {
        records.last { $0.status.jobID == jobID.uuidString }?.status
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            let staging = path.deletingLastPathComponent()
                .appendingPathComponent(path.lastPathComponent + ".tmp")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try data.write(to: staging)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: staging)
            // Records carry meeting titles, participant names and output
            // paths — keep owner-only, matching the other sensitive-JSON
            // writers (SpeakerMatcher, RecordingSidecar).
            try? FileManager.default.restrictToOwner(path)
        } catch {
            logger.error("Failed to persist terminal job records: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load records from `path`, returning `[]` on a missing or unreadable file
    /// (a corrupt store must never block startup or readback).
    private static func load(from path: URL) -> [TerminalJobRecord] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        do {
            let data = try Data(contentsOf: path)
            return try JSONDecoder().decode([TerminalJobRecord].self, from: data)
        } catch {
            logger.error("Failed to load terminal job records: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
