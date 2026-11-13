import Foundation

/// What the queue knows of a job it still lists. A job stays `.done` through its
/// Notion export, first run or retry, so its state alone cannot say the queue is
/// through with it.
struct LiveMeetingState: Equatable, Sendable {
    let state: JobState
    let notionExportRunning: Bool

    /// Whether the queue is through with the job for now.
    var isSettled: Bool {
        switch state {
        case .done: !notionExportRunning
        case .waiting, .transcribing, .diarizing, .generatingProtocol, .speakerNamingPending, .error: false
        }
    }
}

/// What the All Recordings window asks the queue about a meeting before it acts.
extension PipelineController {
    /// What the queue knows of a meeting. A job the queue has not read yet counts,
    /// as the record says finished a moment before the snapshot does, and a crash in
    /// between comes back as a job still running. Building the queue to ask it would
    /// resume those jobs, so its unread file is read instead, and when the saved jobs
    /// cannot be known the answer is that the meeting is not through, which keeps its
    /// audio.
    func liveMeetingState(jobID: UUID) -> LiveMeetingState? {
        if let job = queue.jobs.first(where: { $0.id == jobID }) {
            return LiveMeetingState(
                state: job.state,
                // A chained re-export reads completed between one export's end and
                // the next one's start, and its task runs throughout.
                notionExportRunning: job.notionExportStatus == .inProgress || queue.notionExportTasks[jobID] != nil,
            )
        }
        guard let saved = jobsTheQueueHasNotRead() else {
            return LiveMeetingState(state: .waiting, notionExportRunning: false)
        }
        return saved.first { $0.id == jobID }.map { job in
            LiveMeetingState(state: job.state, notionExportRunning: job.notionExportStatus == .inProgress)
        }
    }

    /// Whether the All Recordings window still has a row for a meeting. Saved jobs that
    /// cannot be known may hold one.
    func listsMeeting(jobID: UUID) -> Bool {
        if queue.jobs.contains(where: { $0.id == jobID }) || terminalJobStore.lookup(jobID: jobID) != nil { return true }
        return jobsTheQueueHasNotRead()?.contains { $0.id == jobID } ?? true
    }

    // swiftlint:disable discouraged_optional_collection
    /// The saved jobs only the snapshot holds (`loadSnapshot` reads the same two
    /// places), none once a queue has read it or when there is no file, and nil when
    /// they cannot be known: the file does not read, or did not when the queue tried,
    /// which leaves a queue with an engine and an empty list.
    private func jobsTheQueueHasNotRead() -> [PipelineJob]? {
        guard !queue.snapshotRestoreFailed else { return nil }
        guard queue.engine == nil else { return [] }
        let logDir = queueEnvironment.logDir
        return try? PipelineSnapshotStore.existing(for: logDir)?.latestSaved ?? PipelineSnapshot.load(from: logDir) ?? []
    }

    // swiftlint:enable discouraged_optional_collection
}
