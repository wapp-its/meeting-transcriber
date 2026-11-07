import Foundation

/// What the Transcriptions window and the menu's job lines act through: the
/// one list of jobs, and the actions on its entries.
extension PipelineController {
    /// The live jobs and the finished-job history as one list, newest first.
    var transcriptionEntries: [TranscriptionEntry] {
        TranscriptionList.entries(liveJobs: queue.jobs, records: terminalJobStore.records)
    }

    /// Called when the Transcriptions window appears. Starts the pipeline the
    /// way importing a file does, which reads the snapshot: until then a failed
    /// or naming-pending job from an earlier session is not in the queue, so a
    /// failed one could not be retried from the window.
    func prepareTranscriptionsWindow() {
        ensureQueue()
    }

    /// Whether `retryJob` would accept this job now; the window offers Retry
    /// only where it holds, as the menu does.
    func canRetryJob(id: UUID) -> Bool {
        queue.canRetryJob(id: id)
    }

    @discardableResult
    func retryJob(id: UUID) -> Bool {
        queue.retryJob(id: id)
    }

    /// Take a failed job off the list for good: out of the queue, its audio
    /// marked processed so orphan recovery does not bring it back, and out of
    /// the history. Deletes no file. Anything that is not a failed job is left
    /// alone.
    ///
    /// The pipeline is started first: a failed job still only in the unread
    /// snapshot would otherwise come back the next time the queue is built.
    /// The history record goes in a step of its own because `removeJob` is
    /// also how the queue reaps a done job after a minute, and that job has
    /// to stay listed.
    func removeFailedJob(id: UUID) {
        ensureQueue()
        if let live = queue.jobs.first(where: { $0.id == id }) {
            guard live.state == .error else { return }
            queue.removeJob(id: id)
        } else {
            guard terminalJobStore.lookup(jobID: id)?.state == .error else { return }
        }
        terminalJobStore.remove(jobID: id)
    }

    // MARK: - A meeting's files

    /// Move the meeting's own audio to the Trash; the transcript and the protocol
    /// stay. Returns false when it refuses and changes nothing; a file it could not
    /// move is not a refusal, and shows in the record as `incomplete`.
    @discardableResult
    func moveAudioToTrash(jobID: UUID) -> Bool {
        // A half-deleted meeting goes on with Retry: finishing the audio here would
        // replace the record of the meeting's own unfinished deletion.
        guard let record = actionableMeetingRecord(jobID: jobID), record.origin == .recorded,
              record.incomplete?.kind != .meetingToTrash,
              !record.filesCovered(by: .audioToTrash).isEmpty else { return false }
        return runManualDeletion(.audioToTrash, of: record)
    }

    /// Move every file the app owns of the meeting to the Trash, then take the
    /// meeting off every list. Nothing here talks to Notion: a page stays where it is.
    @discardableResult
    func moveMeetingToTrash(jobID: UUID) -> Bool {
        guard let record = actionableMeetingRecord(jobID: jobID) else { return false }
        return runManualDeletion(.meetingToTrash, of: record)
    }

    /// Run an incomplete deletion again, over what the record still lists rather
    /// than the paths that failed: a retry that finds nothing left completes it.
    @discardableResult
    func retryDeletion(jobID: UUID) -> Bool {
        guard let record = actionableMeetingRecord(jobID: jobID), let kind = record.incomplete?.kind,
              kind != .automatic else { return false }
        return runManualDeletion(kind, of: record)
    }

    @discardableResult
    func setKeep(jobID: UUID, _ keep: Bool) -> Bool {
        guard let record = actionableMeetingRecord(jobID: jobID), record.origin == .recorded else { return false }
        return meetingFileStore.setKeep(keep, jobID: jobID)
    }

    /// Finish, at launch, what a quit or a crash stopped. A meeting with nothing
    /// left to move ends as the action would have.
    ///
    /// The queue is not built for this, as that would resume the other jobs waiting
    /// in the snapshot (see `restorePendingNotionExports`).
    func reconcileInterruptedDeletions(isRunning: (DeletionProcess) -> Bool = DeletionProcess.isRunning) {
        guard meetingFileStore.records.contains(where: { $0.pending != nil }) else { return }
        let finished = withOutputFolderScope {
            meetingFileStore.reconcileInterruptedDeletions(now: now(), isRunning: isRunning)
        }
        for jobID in finished {
            removeMovedMeeting(jobID: jobID)
        }
    }

    /// The record when an action may change this meeting right now, or nil. Asked
    /// when the action runs, not when its menu was drawn. Only a finished meeting
    /// qualifies: a run of another build reads as `inProgress` here, a meeting that
    /// left the queue unfinished keeps its audio. A finished record says nothing
    /// about a late re-diarization or an export, so the queue is asked as well, and
    /// it has to be built first to know about a job still only in the snapshot.
    private func actionableMeetingRecord(jobID: UUID) -> MeetingFileRecord? {
        ensureQueue()
        meetingFileStore.reload()
        guard let record = meetingFileStore.record(for: jobID), record.pending == nil,
              case .finished = record.outcome else { return nil }
        if let live = queue.jobs.first(where: { $0.id == jobID }),
           live.state != .done || live.notionExportStatus == .inProgress {
            return nil
        }
        return record
    }

    private func runManualDeletion(_ kind: MeetingFileRecord.DeletionKind, of record: MeetingFileRecord) -> Bool {
        let jobID = record.jobID
        let files = record.filesCovered(by: kind)
        guard meetingFileStore.beginDeletion(jobID: jobID, kind: kind, paths: files.map(\.path)) else { return false }
        let outcomes = withOutputFolderScope {
            fileRemover.remove(files, mode: .trash, in: meetingFileStore, jobID: jobID)
        }
        if let reason = MeetingFileRemover.failureReason(of: outcomes) {
            let left = outcomes.filter { outcome in
                if case .failed = outcome.result { return true }
                return false
            }.map(\.path)
            meetingFileStore.finishDeletion(jobID: jobID, outcomes: outcomes) { record in
                record.incomplete = .init(reason: reason, paths: left, kind: kind)
            }
        } else if kind == .meetingToTrash {
            removeMovedMeeting(jobID: jobID)
        } else {
            let deletion = MeetingFileRecord.AudioDeletion(kind: .manual, at: now())
            meetingFileStore.finishDeletion(jobID: jobID, outcomes: outcomes) { record in
                record.audioDeletion = deletion
                record.incomplete = nil
            }
        }
        return true
    }

    /// Take a meeting whose files are gone off every list. The row leaves at once,
    /// the record last: it holds the pending mark, and a snapshot or a history that
    /// still lists the meeting would bring it back with nothing to finish it by. So
    /// the record goes only once both are on disk. A failed write or a crash leaves
    /// the mark, and the next launch ends up here again.
    private func removeMovedMeeting(jobID: UUID) {
        if queue.jobs.contains(where: { $0.id == jobID }) {
            queue.removeJob(id: jobID, keepingFiles: true)
        } else if queue.engine == nil {
            guard forgetInUnreadSnapshot(jobID: jobID) else { return }
        }
        guard terminalJobStore.remove(jobID: jobID) else { return }
        guard queue.isSnapshotWorkerActive else {
            meetingFileStore.remove(jobID: jobID)
            return
        }
        // The queue writes its snapshot off the main actor.
        Task { [queue, meetingFileStore] in
            await queue.awaitSnapshotFlush()
            // Still active after a flush means the write failed and is still owed.
            guard !queue.isSnapshotWorkerActive else { return }
            meetingFileStore.remove(jobID: jobID)
        }
    }

    /// A queue that has not read the snapshot must not be told to remove a job:
    /// `removeJob` saves its own empty list over the file. The file is edited
    /// instead, or the job would come back when the queue is built.
    ///
    /// False when the file could not be written. An unreadable one holds nothing
    /// that can come back.
    private func forgetInUnreadSnapshot(jobID: UUID) -> Bool {
        let logDir = queueEnvironment.logDir
        guard let saved = try? PipelineSnapshot.load(from: logDir), saved.contains(where: { $0.id == jobID }) else {
            return true
        }
        return (try? PipelineSnapshot.save(saved.filter { $0.id != jobID }, to: logDir)) != nil
    }

    /// Around any file work on a meeting: in the sandboxed build a chosen folder is
    /// out of reach without its scope, which only reads as files gone or unavailable.
    /// Only a folder the bookmark resolved has one; `.fallback` stands in for a folder
    /// that cannot be reached.
    private func withOutputFolderScope<T>(_ body: () -> T) -> T {
        guard case let .custom(root) = settings.outputDirectoryResolution else { return body() }
        let access = queueEnvironment.securityScope
        let opened = access.start(root)
        defer { if opened { access.stop(root) } }
        return body()
    }
}
