import Foundation

/// The fork's link between the original's recording retention and the meeting
/// records behind All Recordings: a pass deletes only what a record and the
/// queue let it, and what a pass deleted shows on the meeting's row.
extension PipelineController {
    /// Set once from `activate`, before the first pass can run.
    func connectRetentionToMeetingRecords() {
        recordingRetention.recordGate = { [weak self] jobs in self?.retentionRecordGate(for: jobs) }
        recordingRetention.didDelete = { [weak self] jobID, gone in
            self?.noteDeletedByRetention(jobID: jobID, paths: gone)
        }
    }

    /// Which of `jobs` this build's retention pass may delete the audio of: the
    /// record, read fresh from the file the other build writes too, has to allow
    /// it (`MeetingFileRecord.allowsRetention`), and the queue has to be through
    /// with the job (`LiveMeetingState.isSettled`), so a running Notion export
    /// holds the audio, and so do saved jobs that do not read. A job without a
    /// record is never allowed. Nil when the record file does not read.
    func retentionRecordGate(for jobs: Set<UUID>) -> RecordingRetentionPolicy.RecordGate? {
        guard meetingFileStore.reload() else { return nil }
        let build = meetingFileStore.bundleID
        let allowed = meetingFileStore.records
            .filter { jobs.contains($0.jobID) && $0.allowsRetention(by: build) }
            .map(\.jobID)
            .filter { liveMeetingState(jobID: $0)?.isSettled ?? true }
        return .only(Set(allowed))
    }

    /// Mark the files a pass deleted as gone in the meeting's record, and date the
    /// deletion once no audio of the meeting is left, so its row says
    /// "Audio deleted automatically" instead of "Audio not found".
    func noteDeletedByRetention(jobID: UUID, paths: [URL]) {
        // Compared with the folder resolved, as the files no longer exist to be
        // resolved themselves (`MeetingFile.resolvedPath`).
        let key = { (url: URL) in
            url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        let deleted = Set(paths.map(key))
        let date = now()
        meetingFileStore.update(jobID: jobID) { record in
            var changed = false
            for index in record.files.indices where deleted.contains(key(URL(filePath: record.files[index].path))) {
                record.files[index].state = .gone
                changed = true
            }
            let audioLeft = record.files.contains { $0.role.isSourceTrack && $0.state != .gone }
            if changed, !audioLeft, record.audioDeletion == nil {
                record.audioDeletion = .init(kind: .automatic, at: date)
            }
        }
    }
}

extension MeetingFileRecord {
    /// Whether the retention pass of the build `bundleID` may delete the meeting's
    /// audio once its registry entry is due, as the fork's rules have it: a
    /// recording (never an import) that this build created (`createdBy`, nil in a
    /// record from before that field) and that finished, which is neither marked
    /// Keep, nor in a deletion of the user's under way or left incomplete, nor a
    /// recovered recording from before the records existed.
    func allowsRetention(by bundleID: String?) -> Bool {
        guard origin == .recorded, let createdBy, createdBy == bundleID, case .finished = outcome else { return false }
        return !keep && pending == nil && incomplete == nil && !excludedFromAutomaticDeletion
    }
}
