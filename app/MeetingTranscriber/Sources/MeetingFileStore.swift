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
    private(set) var records: [MeetingFileRecord] = []
    /// When the file was first created: what a recovered recording's audio is
    /// compared with to tell one from before this feature. Written once, before
    /// the first record, so a recording made since the first launch of this
    /// version does not read as older than the file.
    @ObservationIgnored private(set) var since = Date()

    init(path: URL) {
        self.path = path
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
            // Never `list`: each run the Trash refuses leaves one more copy, and
            // deleting the meeting has to find them all.
            if let keptFile {
                record.files.removeAll { $0.path == keptFile.path }
                record.files.append(keptFile)
            }
        }
        if current == nil { markGone(jobID: jobID, roles: [.protocol]) }
    }

    /// Read the file again. Creates it when there is none yet.
    func reload() {
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
