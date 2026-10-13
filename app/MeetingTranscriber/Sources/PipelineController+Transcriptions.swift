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
}
