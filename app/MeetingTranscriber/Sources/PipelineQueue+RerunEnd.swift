import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// How a re-run ended other than by success (R6).
enum RerunEnd: Equatable, Sendable {
    /// A stage failed, or one that a new meeting only warns about (A25), with why.
    case failed(String)
    /// The row's Cancel, or Dismiss in the menu's "Needs you" group.
    case cancelled
    /// Its naming was left past the wait (A5).
    case unnamed
}

/// What a meeting's row says after its re-run failed or was left unnamed (A23).
struct RerunWarning: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        case failed(String)
        case unnamed
    }

    let mode: RerunMode
    let cause: Cause
}

/// Why a re-run failed where a new meeting only warns (A25), as the row's warning
/// line goes on after "failed: ".
enum RerunFailure {
    static let unknown = "an unknown error"
    static let speakersNotAvailable = "speaker identification is not available"
    static let speakersFailed = "speaker identification failed"
    static let callAudioSpeakersFailed = "speaker identification failed on the call audio"
    static let microphoneSpeakersFailed = "speaker identification failed on the microphone"
    static let notesNotMade = "the notes could not be made"
    static let notesNotSaved = "the notes could not be saved"
    static let namingLost = "the speakers to name could not be read again after the app restarted"
}

/// Every end of a re-run but success leaves the meeting as it was (R6, A2). The
/// record is the re-run's journal, so each step is written there before the next
/// one starts: the marker is marked as ending, the re-run's own files are removed,
/// one record update restores the outcome and notes the stamp as ended, and only
/// then does the job leave the queue and its file. A crash between any two steps
/// reads as one row of the launch table (PipelineQueue+RerunRecovery.swift).
extension PipelineQueue {
    /// Ends the re-run `id` other than by success. Its work stops, its local
    /// generation under the marker's run id: the gate refuses an id it cancelled for
    /// as long as the app runs, and the meeting's next re-run and its Regenerate
    /// Meeting Notes run under the meeting's id. None of what a finished or failed
    /// job leaves runs for it: no outcome, no finished entry, no ledger mark, no
    /// audio move, no notification. A finished job of the meeting it took over comes
    /// back as it was, with its export state and its notes failure.
    func endRerun(id: UUID, because end: RerunEnd) {
        guard let job = job(withID: id), let rerun = job.rerun else { return }
        cancelWork(of: id, endingLocalGeneration: false)
        cancelLocalModelGeneration(jobID: rerun.marker.runID)
        let marker = recordedMarker(rerun.marker, jobID: id)
        let recorded = meetingFileStore.map { Self.closeRerun(marker, jobID: id, in: $0) }
        takeOutOfQueue(id)
        if recorded?.saved != true {
            // Kept in its file in `.error`, which tells the next launch that its end
            // was decided (`restoreDecision`).
            logger.error("[\(job.shortID, privacy: .public)] rerun_end_not_recorded: the re-run stays in its file")
            var decided = job
            decided.state = .error
            rerunJobsAwaitingRecord[id] = decided
        }
        if case let .job(held) = rerun.heldEntry {
            jobs.append(held)
            scheduleCompletedJobRemoval(id: id)
        }
        switch end {
        case let .failed(reason): rerunWarnings[id] = RerunWarning(mode: rerun.mode, cause: .failed(reason))
        case .unnamed: rerunWarnings[id] = RerunWarning(mode: rerun.mode, cause: .unnamed)
        case .cancelled: break
        }
        saveSnapshot()
        logger.info(
            "[\(job.shortID, privacy: .public)] rerun_ended end=\(end.logTag, privacy: .public) files_left=\(recorded?.left.count ?? 0, privacy: .public)",
        )
    }

    /// Ends `jobID`'s re-run as failed, for a stage failure that a new meeting
    /// only warns about (A25), and returns the error that stops the stage: the
    /// job is gone.
    func failRerun(_ jobID: UUID, _ reason: String) -> CancellationError {
        updateJobState(id: jobID, to: .error, error: reason)
        return CancellationError()
    }

    /// Re-runs waiting for names past the wait end, and the meetings stay as they
    /// were (A5); with the wait set to never this is not called.
    func endStaleReruns(_ pending: [PipelineJob], maxAge: TimeInterval) {
        let now = Date()
        for job in pending where now.timeIntervalSince(job.namingDeadlineStart) > maxAge {
            endRerun(id: job.id, because: .unnamed)
        }
    }

    /// The marker of a re-run as its record has it, with every file the job's copy
    /// lists (`merged`); the job's own copy when the record holds another run's or none.
    private func recordedMarker(
        _ own: MeetingFileRecord.RerunMarker, jobID: UUID,
    ) -> MeetingFileRecord.RerunMarker {
        guard let recorded = meetingFileStore?.record(for: jobID)?.rerun, recorded.runID == own.runID else { return own }
        return Self.merged(own, into: recorded, ownIsNewer: true)
    }

    /// What leaving the queue undoes, without the steps `removeJob` runs for a job
    /// of its own: the meeting's outcome, the ledger and its audio stay as they are.
    private func takeOutOfQueue(_ id: UUID) {
        completedJobRemovalTokens.removeValue(forKey: id)
        naming.forgetNamingData(jobID: id)
        jobs.removeAll { $0.id == id }
        forgetStageBookkeeping(for: id)
        protocolResumeDispositions.removeValue(forKey: id)
        protocolGenerationOn.removeValue(forKey: id)
        // The re-run's own export, queued with its notes; the entry taken over
        // has none, since it was settled.
        pendingNotionExports.removeValue(forKey: id)
    }

    // MARK: - The record and the files

    /// The record-side end of the re-run `marker` names: marked as ending with every
    /// file it lists, the swap's renames it lists moved back, those files removed,
    /// then one update restoring the outcome (A27 for a file left).
    /// `saved` is whether that last update landed; `left` the files that stayed.
    static func closeRerun(
        _ marker: MeetingFileRecord.RerunMarker, jobID: UUID, in store: MeetingFileStore,
    ) -> (saved: Bool, left: [MeetingFile]) {
        let marked = store.update(jobID: jobID) { record in
            guard record.rerun?.runID == marker.runID else { return }
            record.rerun?.ending = true
            record.rerun?.files = marker.files
        }
        if !marked {
            logger.error("[\(PipelineJob.shortID(for: jobID), privacy: .public)] rerun_ending_not_recorded")
        }
        // A rename that could not go back keeps the marker, as a file left does, so
        // the next launch and the next admission try it again.
        // Nothing at a rename's target is removed: a current file kept there as an
        // earlier version is the meeting's own.
        let stuck = marker.renames.map { undoRenames($0, jobID: jobID) } ?? []
        let targets = Set((marker.renames ?? []).map(\.to))
        let left = removeRerunFiles(marker.files.filter { !targets.contains($0.path) }, jobID: jobID) + stuck
        let saved = store.update(jobID: jobID) { $0.endRerun(marker, leaving: left) }
        return (saved, left)
    }

    /// Removes each of `files` that is still the file the re-run wrote, in the
    /// folder it wrote it to (`MeetingFileRemover.isTheRecordedFile`), and returns
    /// the ones that stayed: replaced at their path, reached through a folder
    /// replaced by a symbolic link, out of reach, or refused by the disk.
    static func removeRerunFiles(_ files: [MeetingFile], jobID: UUID) -> [MeetingFile] {
        files.filter { file in
            guard file.state != .gone, let reason = removeRerunFile(file) else { return false }
            logger.warning(
                "[\(PipelineJob.shortID(for: jobID), privacy: .public)] rerun_file_left reason=\(reason, privacy: .private)",
            )
            return true
        }
    }

    /// Nil when `file` is gone, now or before; else why it stays.
    private static func removeRerunFile(_ file: MeetingFile) -> String? {
        switch MeetingFilePresence.of(file.path) {
        case .gone:
            return nil

        case .unreachable:
            return "unreachable"

        case .present:
            guard MeetingFileRemover.isTheRecordedFile(file) else { return "replaced" }
            do {
                try FileManager.default.removeItem(atPath: file.path)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}

private extension RerunEnd {
    var logTag: String {
        switch self {
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unnamed: "unnamed"
        }
    }
}
