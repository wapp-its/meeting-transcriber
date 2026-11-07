import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingFileStore")

/// The file of every meeting's `MeetingFileRecord`, one JSON document beside
/// `terminal_jobs.json`, holding the records and when the file was first created.
///
/// A second running build of the app (the development and the release build
/// share the data folder) writes the same file, so every write takes an exclusive
/// lock on a lock file beside it, re-reads the file and changes only its one
/// record there. Re-reading alone is not enough: two processes could both read
/// before either writes. The kernel drops a lock when its process dies, so a
/// crash leaves nothing to clean up.
///
/// A write reports whether it was saved, because a deletion may start only after
/// its pending mark is on disk. A failed write is logged and never thrown: the
/// pipeline ignores the answer, and a meeting's result never depends on it.
/// `records` follows the file at each read, so after a failed write it holds what
/// the file holds.
///
/// Writes are atomic and owner-only, as in `TerminalJobStore`. The file lists
/// output paths and meeting slugs, so nothing from it is logged as public.
@MainActor
@Observable
final class MeetingFileStore {
    private struct Document: Codable, Equatable {
        var since: Date
        var records: [MeetingFileRecord]
    }

    /// A write fails rather than wait longer, because it runs on the main actor
    /// and a stuck holder must not hang the app. Long enough for any one
    /// read-change-write of the other build.
    private static let lockWaitBound = Duration.seconds(2)
    private static let lockRetryInterval: useconds_t = 10000

    @ObservationIgnored private let path: URL
    /// The running build's bundle identifier: the build a record created here is
    /// stamped with, and the only build whose records the automatic deletion acts on
    /// (`RecordingRetentionRule`). Injected, so a test can run two builds over one file.
    @ObservationIgnored let bundleID: String?
    private(set) var records: [MeetingFileRecord] = []
    /// When the file was first created: what a recovered recording's audio is
    /// compared with to tell one from before this feature. Written once, before
    /// the first record, so a recording made since the first launch of this
    /// version does not read as older than the file.
    @ObservationIgnored private(set) var since = Date()

    init(path: URL, bundleID: String? = Bundle.main.bundleIdentifier) {
        self.path = path
        self.bundleID = bundleID
        reload()
    }

    func record(for jobID: UUID) -> MeetingFileRecord? {
        records.first { $0.jobID == jobID }
    }

    /// Add a record. A record the file already has stands, because its recording
    /// date is written once and its Keep mark and deletion state must survive:
    /// nothing is written then, and the answer is still true.
    @discardableResult
    func create(_ record: MeetingFileRecord) -> Bool {
        transact { document in
            if !document.records.contains(where: { $0.jobID == record.jobID }) {
                document.records.append(record)
            }
            return true
        }
    }

    /// Change the file's copy of one record, and false when the file has none:
    /// a meeting from before this version never gets one.
    @discardableResult
    func update(jobID: UUID, _ change: (inout MeetingFileRecord) -> Void) -> Bool {
        transact { document in
            guard let index = document.records.firstIndex(where: { $0.jobID == jobID }) else {
                logger.info("No meeting file record for job \(PipelineJob.shortID(for: jobID), privacy: .public)")
                return false
            }
            change(&document.records[index])
            return true
        }
    }

    /// True also when the file has no such record: it is gone either way.
    @discardableResult
    func remove(jobID: UUID) -> Bool {
        transact { document in
            document.records.removeAll { $0.jobID == jobID }
            return true
        }
    }

    /// Mark the listed files in `roles` the pipeline has just removed. Only a file
    /// the disk answers for: a file on a volume that is not connected stays listed
    /// as present. The probe runs outside the lock, which is never held while the
    /// disk is asked, and the mark goes by path, as `records` can be a write behind.
    func markGone(jobID: UUID, roles: Set<MeetingFile.Role>) {
        guard let record = record(for: jobID) else { return }
        let gone = Set(record.files.filter { file in
            roles.contains(file.role) && file.state == .present && MeetingFilePresence.of(file.path) == .gone
        }.map(\.path))
        guard !gone.isEmpty else { return }
        update(jobID: jobID) { record in
            for index in record.files.indices where gone.contains(record.files[index].path) {
                record.files[index].state = .gone
            }
        }
    }

    /// List files the pipeline has just written. An earlier file of the same role
    /// at another path goes only when the disk answers that it is gone: one in a
    /// folder that cannot be reached, or still there beside the new one, is a file
    /// of this meeting all the same.
    func list(_ files: [MeetingFile], jobID: UUID) {
        let kept = earlierFilesStillOnDisk(beside: files, jobID: jobID)
        update(jobID: jobID) { record in
            for file in files {
                record.list(file, keeping: kept)
            }
        }
    }

    /// The paths `list` keeps. Outside `update`, as the lock is never held while
    /// the disk is asked.
    private func earlierFilesStillOnDisk(beside files: [MeetingFile], jobID: UUID) -> Set<String> {
        guard let record = record(for: jobID) else { return [] }
        return Set(record.files.filter { earlier in
            earlier.state != .gone
                && files.contains { $0.role == earlier.role && $0.path != earlier.path }
                && MeetingFilePresence.of(earlier.path) != .gone
        }.map(\.path))
    }

    /// What a regeneration left of a meeting's protocol. `current` is nil when the
    /// new one did not go in place and the old one did not go back; `keptPrevious`
    /// is a previous protocol still on disk under a name of its own.
    func noteProtocolReplaced(jobID: UUID, current: URL?, keptPrevious: URL?) {
        // Read from memory and outside `update`, as `PipelineQueue.noteWritten` does.
        guard let origin = record(for: jobID)?.origin else { return }
        let currentFile = current.map { MeetingFile(role: .protocol, url: $0, owned: origin.owns(.protocol)) }
        let keptFile = keptPrevious.map { MeetingFile(role: .previousProtocol, url: $0, owned: origin.owns(.previousProtocol)) }
        let kept = currentFile.map { earlierFilesStillOnDisk(beside: [$0], jobID: jobID) } ?? []
        update(jobID: jobID) { record in
            if let currentFile { record.list(currentFile, keeping: kept) }
            if let keptFile { record.appendKept(keptFile) }
        }
        if current == nil { markGone(jobID: jobID, roles: [.protocol]) }
    }

    /// A file the app itself left on disk for the meeting under a name of its own:
    /// an old additional report the regenerator kept, or a report a failed rename
    /// left under the new name. Listed under `previousProtocol`, as no report rule
    /// may find it any more and Move Meeting to Trash has to; that role also keeps
    /// it out of the "right after the notes" check, which counts only `.protocol`.
    func noteKeptFile(jobID: UUID, url: URL) {
        guard let origin = record(for: jobID)?.origin else { return }
        let kept = MeetingFile(role: .previousProtocol, url: url, owned: origin.owns(.previousProtocol))
        update(jobID: jobID) { $0.appendKept(kept) }
    }

    /// Read the file again. Creates it when there is none yet. False when that failed,
    /// which leaves `records` as they were and says nothing about the file.
    @discardableResult
    func reload() -> Bool {
        transact { _ in true }
    }

    // MARK: - Persistence

    /// One read-change-write under the lock, the only place the lock is held.
    /// `change` runs inside it, so it must not touch anything but the document.
    /// Nothing is written when `change` left the document as it was, unless the
    /// file does not exist yet.
    @discardableResult
    private func transact(_ change: (inout Document) -> Bool) -> Bool {
        guard let lock = acquireLock() else { return false }
        defer { close(lock) } // Closing the only descriptor releases the lock.
        guard let onDisk = readDocument() else { return false }
        adopt(onDisk.document)
        var document = onDisk.document
        guard change(&document) else { return false }
        guard document != onDisk.document || onDisk.isNew else { return true }
        guard save(document) else { return false }
        adopt(document)
        return true
    }

    /// Compare-before-assign, as a reload usually finds nothing new and every
    /// assignment to an observed property redraws what reads it.
    private func adopt(_ document: Document) {
        since = document.since
        if records != document.records { records = document.records }
    }

    /// An exclusive lock on the lock file, as an open descriptor, or nil when it
    /// stays held past the bound or cannot be opened. `LOCK_NB` in a short loop
    /// because a plain `flock` has no timeout. The lock file is never removed:
    /// two processes could otherwise each hold a lock on a different file.
    private func acquireLock() -> Int32? {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let descriptor = open(path.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            logger.error("Meeting file record not saved: lock file failed to open, errno \(errno, privacy: .public)")
            return nil
        }
        let deadline = ContinuousClock.now + Self.lockWaitBound
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR, ContinuousClock.now < deadline else {
                logger.error("Meeting file record not saved: lock not acquired, errno \(failure, privacy: .public)")
                close(descriptor)
                return nil
            }
            usleep(Self.lockRetryInterval)
        }
        return descriptor
    }

    /// The file's content under the lock, or nil when a write must not go ahead.
    /// No file, or one moved aside, starts a new document; a file that could not
    /// be read says nothing about its content, so it stays as it is.
    private func readDocument() -> (document: Document, isNew: Bool)? {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileReadNoSuchFile {
            return (Document(since: since, records: []), true)
        } catch {
            logger.error("Failed to read meeting file records: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        do {
            return try (JSONDecoder().decode(Document.self, from: data), false)
        } catch {
            logger.error("Meeting file records do not decode: \(error.localizedDescription, privacy: .private)")
            return moveCorruptFileAside() ? (Document(since: since, records: []), true) : nil
        }
    }

    /// Never overwritten by an empty list, as what it held may be recoverable. A
    /// file that cannot be moved aside fails the write for the same reason. An
    /// earlier corrupt copy is replaced; only the latest damage is worth keeping.
    private func moveCorruptFileAside() -> Bool {
        let aside = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".corrupt")
        do {
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: path, to: aside)
            return true
        } catch {
            logger.error("Failed to move corrupt meeting file records aside: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func save(_ document: Document) -> Bool {
        let staging = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".tmp")
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: staging)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: staging)
            try? FileManager.default.restrictToOwner(path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            logger.error("Failed to persist meeting file records: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}

// MARK: - Deletions

/// A second running build reads and writes the same file, so each decision about
/// a deletion is made under the lock against the file's content, never against
/// `records`, which can be a write behind.
extension MeetingFileStore {
    enum RemovalStart: Equatable {
        case marked
        case listedByAnotherMeeting
        case meetingChanged
        case notSaved
    }

    /// Set the Keep mark, unless a deletion of the meeting is under way. Under the
    /// lock the deletion's mark is written under, so the first of the two wins: a Keep
    /// that came first stops the deletion, and a deletion that came first refuses the
    /// Keep, which never reads as saved beside audio that went.
    func setKeep(_ keep: Bool, jobID: UUID) -> Bool {
        transact { document in
            guard let index = document.records.firstIndex(where: { $0.jobID == jobID }),
                  document.records[index].pending == nil else { return false }
            document.records[index].keep = keep
            return true
        }
    }

    /// Save a deletion before it touches its first file. False starts nothing: the
    /// save failed, the meeting has no record, a deletion of it is already pending, or
    /// the file's copy differs from `read`, the record the caller decided on, which is
    /// the last look, under the lock another build also takes.
    ///
    /// `reports`, the additional reports Move Meeting to Trash found, are listed in the
    /// same save and join the pending paths, so a crash or a retry carries them. One the
    /// record already lists is left as listed, with the identity it was listed with: a
    /// report replaced since is refused as replaced. One the record lists as not the
    /// app's stays out.
    func beginDeletion(
        jobID: UUID, kind: MeetingFileRecord.DeletionKind, paths: [String], unchangedFrom read: MeetingFileRecord? = nil,
        adding reports: [MeetingFile] = [],
    ) -> Bool {
        transact { document in
            guard let index = document.records.firstIndex(where: { $0.jobID == jobID }),
                  document.records[index].pending == nil,
                  read == nil || document.records[index] == read else { return false }
            var pending = paths
            for report in reports {
                let listed = document.records[index].files.filter { $0.path == report.path }
                guard listed.allSatisfy(\.owned) else { continue }
                if !listed.contains(where: { $0.state != .gone }) { document.records[index].appendKept(report) }
                if !pending.contains(report.path) { pending.append(report.path) }
            }
            document.records[index].pending = .init(kind: kind, paths: pending)
            return true
        }
    }

    /// End a deletion that never started as incomplete, with `reason`, under the same
    /// checks as `beginDeletion`: nothing moved, and Retry Deletion runs it again.
    /// The paths are what the deletion covers now.
    func failBeforeDeletion(
        jobID: UUID, kind: MeetingFileRecord.DeletionKind, reason: String, unchangedFrom read: MeetingFileRecord? = nil,
    ) -> Bool {
        transact { document in
            guard let index = document.records.firstIndex(where: { $0.jobID == jobID }),
                  document.records[index].pending == nil,
                  read == nil || document.records[index] == read else { return false }
            let paths = document.records[index].filesCovered(by: kind).map(\.path)
            document.records[index].incomplete = .init(reason: reason, paths: paths, kind: kind)
            return true
        }
    }

    /// Remove a record the caller found nothing left of, as long as the file's copy
    /// still is the one it looked at. `remove(jobID:)` is for a meeting already gone.
    @discardableResult
    func remove(unchanged read: MeetingFileRecord) -> Bool {
        transact { document in
            guard let index = document.records.firstIndex(where: { $0.jobID == read.jobID }),
                  document.records[index] == read else { return false }
            document.records.remove(at: index)
            return true
        }
    }

    /// Mark one file as being deleted, the last step before it is touched. A path
    /// another record lists is left alone: that meeting still needs the file. So is a
    /// report of a meeting another record lists by its transcript or notes. An
    /// entry the other record knows is gone holds nothing back. An automatic deletion
    /// also stops here when the record no longer allows it: not every write of another
    /// build looks at the mark, and what has not gone yet can still stay.
    func startRemoving(path: String, jobID: UUID) -> RemovalStart {
        var answer = RemovalStart.notSaved
        let marked = transact { document in
            let listedElsewhere = document.records.contains { other in
                other.jobID != jobID && other.files.contains { $0.path == path && $0.state != .gone }
            } || MeetingReportScan.isReportOfASharedMeeting(path, jobID: jobID, in: document.records)
            if listedElsewhere { answer = .listedByAnotherMeeting }
            guard !listedElsewhere, let index = document.records.firstIndex(where: { $0.jobID == jobID }) else {
                return false
            }
            if document.records[index].pending?.kind == .automatic,
               !RecordingRetentionRule.recordAllowsDeletion(document.records[index], bundleID: bundleID) {
                answer = .meetingChanged
                return false
            }
            document.records[index].setState(.deleting, ofFileAt: path)
            return true
        }
        return marked ? .marked : answer
    }

    func setState(_ state: MeetingFile.State, ofFileAt path: String, jobID: UUID) {
        update(jobID: jobID) { $0.setState(state, ofFileAt: path) }
    }

    /// End a deletion in one write: what became of each file, what `change` records,
    /// and the pending mark. A file's own mark can have failed to save on the way,
    /// and once the pending mark is gone nothing looks at that file again. False
    /// leaves the pending mark, so the next launch settles it.
    @discardableResult
    func finishDeletion(
        jobID: UUID, outcomes: [MeetingFileRemover.FileOutcome], _ change: (inout MeetingFileRecord) -> Void,
    ) -> Bool {
        update(jobID: jobID) { record in
            for outcome in outcomes {
                switch outcome.result {
                case .removed, .alreadyGone: record.setState(.gone, ofFileAt: outcome.path)
                case .failed: record.setState(.present, ofFileAt: outcome.path)
                }
            }
            change(&record)
            record.pending = nil
        }
    }

    /// Check every pending deletion whose process no longer runs against the disk.
    /// Another running build's deletion is not an abandoned one, so it stays.
    ///
    /// - Returns: the meetings whose files are all gone and of which only the
    ///   removal from the lists is left, which is not this store's to do.
    func reconcileInterruptedDeletions(now: Date, isRunning: (DeletionProcess) -> Bool) -> [UUID] {
        reload()
        var onlyTheRecordLeft: [UUID] = []
        for record in records {
            guard let pending = record.pending, !isRunning(pending.process) else { continue }
            // Outside the lock, which is never held while the disk is asked.
            let gone = Set(record.files.filter { file in
                file.state != .gone
                    && (file.state == .deleting || pending.paths.contains(file.path))
                    && MeetingFilePresence.of(file.path) == .gone
            }.map(\.path))
            var recordIsLeft = false
            let saved = transact { document in
                guard let index = document.records.firstIndex(where: { $0.jobID == record.jobID }),
                      document.records[index].pending == pending else { return false }
                recordIsLeft = document.records[index].settleInterrupted(pending, gone: gone, at: now)
                return true
            }
            if saved, recordIsLeft { onlyTheRecordLeft.append(record.jobID) }
        }
        return onlyTheRecordLeft
    }
}

private extension MeetingFileRecord {
    mutating func setState(_ state: MeetingFile.State, ofFileAt path: String) {
        for index in files.indices where files[index].path == path {
            files[index].state = state
        }
    }
}
