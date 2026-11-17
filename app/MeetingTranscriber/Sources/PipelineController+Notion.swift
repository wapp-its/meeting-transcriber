import Foundation

extension PipelineController {
    /// The first queue is otherwise built by a user action, so a failed or
    /// interrupted export, or meeting notes that failed, would have no retry row
    /// after a relaunch. Any other saved job keeps waiting for that action:
    /// building the queue would resume it. A re-run job in this build's own file
    /// is one of those (A24).
    func restorePendingNotionExports() {
        let logDir = queueEnvironment.logDir
        guard let saved = try? PipelineSnapshot.load(from: logDir),
              saved.contains(where: \.isHeldAfterCompletion),
              saved.allSatisfy({ $0.state == .done }),
              !PipelineQueue.rerunFileHoldsJobs(in: logDir, bundleID: meetingFileStore.bundleID) else { return }
        rebuild(recoversStagedRecordings: false)
    }
}
