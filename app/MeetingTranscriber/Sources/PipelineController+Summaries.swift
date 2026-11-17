import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineController")

/// The meeting summaries All Recordings shows: taken when a meeting's
/// current notes are saved, typed in the Edit Summary sheet, and dropped with the
/// meeting. `MeetingSummary` holds the rules, `MeetingSummaryStore` the file.
extension PipelineController {
    var summaryStore: MeetingSummaryStore {
        summarizer.store
    }

    /// The meeting's current notes were saved: by its job, by a re-run's success,
    /// or by a Regenerate Notes that replaced them. The summary call asks the
    /// provider the notes were asked of.
    func notesSaved(jobID: UUID, notes: MeetingSummarizer.SavedNotes, title: String) {
        guard listsMeeting(jobID: jobID) else { return }
        summarizer.notesSaved(jobID: jobID, notes: notes, title: title) { [weak self] in self?.makeProtocolGenerator() }
    }

    /// Save in the Edit Summary sheet. Nothing is stored for a meeting the window
    /// no longer lists (moved to the Trash while the sheet was open).
    @discardableResult
    func saveTypedSummary(jobID: UUID, field: String) -> Bool {
        guard listsMeeting(jobID: jobID) else { return false }
        let date = now()
        let saved = summaryStore.update(jobID: jobID) { MeetingSummary.afterTyped($0, field: field, at: date) }
        if !saved { logger.error("[\(PipelineJob.shortID(for: jobID), privacy: .public)] summary_not_saved source=typed") }
        return saved
    }

    /// At launch, once interrupted deletions are settled: the summaries of every
    /// meeting neither the finished-job list nor the record file holds go, which
    /// also retries a removal that failed when its meeting went to the Trash. Left
    /// for the next launch when the record file does not read.
    func pruneSummaries() {
        guard meetingFileStore.reload() else { return }
        let terminal = Set(terminalJobStore.records.map(\.status.jobID))
        let recorded = Set(meetingFileStore.records.map(\.jobID))
        let kept = summaryStore.removeAll { terminal.contains($0.uuidString) || recorded.contains($0) }
        if !kept { logger.error("summaries_not_pruned") }
    }
}
