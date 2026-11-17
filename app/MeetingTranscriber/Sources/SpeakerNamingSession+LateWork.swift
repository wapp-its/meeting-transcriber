import Foundation

/// Tracking of the late-naming tasks that `SpeakerNamingSession+Late.swift`
/// starts after the pipeline already reached `.speakerNamingPending`, so a
/// removed or cancelled job can stop them. Split out of that file to keep it
/// under the lint cap.
extension SpeakerNamingSession {
    /// Run `work` on a task of its own, tracked under `jobID` until it returns
    /// so `cancelLateWork` can reach it.
    func startLateWork(jobID: UUID, _ work: @escaping () async -> Void) {
        let token = UUID()
        lateWork[jobID, default: [:]][token] = Task {
            await work()
            lateWork[jobID]?[token] = nil
            if lateWork[jobID]?.isEmpty == true { lateWork[jobID] = nil }
        }
    }

    /// Cancel every late-naming task still running for `jobID`. Called when
    /// the job is removed or cancelled. The tasks still re-check the job after
    /// each await, because a step that ignores cancellation returns all the
    /// same.
    func cancelLateWork(jobID: UUID) {
        lateWork.removeValue(forKey: jobID)?.values.forEach { $0.cancel() }
    }
}
