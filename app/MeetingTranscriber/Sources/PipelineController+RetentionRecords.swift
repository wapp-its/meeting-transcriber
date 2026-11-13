import Foundation

/// The fork's link between the original's recording retention and the meeting
/// records behind All Recordings: what a user holds there is never deleted, and
/// what a pass deleted shows on the meeting's row.
extension PipelineController {
    /// Set once from `activate`, before the first pass can run.
    func connectRetentionToMeetingRecords() {
        recordingRetention.heldJobs = { [weak self] in self?.jobsHeldFromRetention() }
        recordingRetention.didDelete = { [weak self] jobID, paths in
            self?.noteDeletedByRetention(jobID: jobID, paths: paths)
        }
    }

    /// The jobs whose audio the retention pass must leave, read fresh from the
    /// record file, which the other build writes too: the ones the user holds
    /// (`isHeldFromRetention`), and, as the fork's rules always had it, every
    /// import and every meeting this build did not create (`createdBy`, nil in a
    /// record from before that field). The registry already lists only this
    /// build's relocations; these keep that true whatever reaches it. Nil when the
    /// file does not read.
    func jobsHeldFromRetention() -> Set<UUID>? { // swiftlint:disable:this discouraged_optional_collection
        guard meetingFileStore.reload() else { return nil }
        let build = meetingFileStore.bundleID
        return Set(meetingFileStore.records.filter { record in
            record.isHeldFromRetention || record.origin == .imported || record.createdBy == nil || record.createdBy != build
        }.map(\.jobID))
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
    /// Whether the retention pass must leave the meeting's audio, whatever its
    /// registry entry says: marked Keep, a deletion of the user's under way or
    /// unfinished, or a recovered recording from before the records existed.
    var isHeldFromRetention: Bool {
        keep || pending != nil || incomplete != nil || excludedFromAutomaticDeletion
    }
}
