import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingSummaryStore")

/// The file of every meeting's summaries (`MeetingSummaries`), keyed by job id, one
/// JSON document beside the finished-job list with a format version. Neither the
/// meeting record nor the finished-job list holds them: meetings from before the
/// record have none, and a build that does not know a field drops it when it rewrites
/// either file, which would lose a typed summary (spec A8).
///
/// A second running build shares the folder, so every write takes the lock beside the
/// file, reads the file again and changes only its one meeting there, as
/// `MeetingFileStore` does. A file that cannot be read or decoded is moved aside under
/// an `.unreadable` name before anything new is written; one that cannot be moved
/// aside is never written over. A failed write is logged without content and only
/// reported: no job and no action depends on it. `summaries` follows the file at each
/// write, so after a failed one it holds what the file holds.
///
/// Writes are atomic and owner-only. Summaries are meeting content: nothing from the
/// file is logged, and none of it goes to the automation API.
@MainActor
@Observable
final class MeetingSummaryStore {
    static let filename = "meeting-summaries.json"
    static let formatVersion = 1

    private struct Document: Codable, Equatable {
        var version: Int
        /// By job id (`UUID.uuidString`).
        var summaries: [String: MeetingSummaries]
    }

    /// As for the record file: the write runs on the main actor and must not hang.
    private static let lockWaitBound = Duration.seconds(2)
    private static let lockRetryInterval: useconds_t = 10000

    @ObservationIgnored private let path: URL
    private(set) var summaries: [UUID: MeetingSummaries] = [:]

    init(path: URL) {
        self.path = path
        reload()
    }

    func summaries(for jobID: UUID) -> MeetingSummaries? {
        summaries[jobID]
    }

    /// Change one meeting's summaries as the file holds them now; nil from `change`
    /// removes them. False when it was not saved.
    @discardableResult
    func update(jobID: UUID, _ change: (MeetingSummaries?) -> MeetingSummaries?) -> Bool {
        transact { document in
            let key = jobID.uuidString
            let next = change(document.summaries[key])
            document.summaries[key] = next?.notes == nil && next?.typed == nil ? nil : next
        }
    }

    /// True also when the file holds none for the meeting.
    @discardableResult
    func remove(jobID: UUID) -> Bool {
        update(jobID: jobID) { _ in nil }
    }

    /// Drop the summaries of every meeting `keeps` does not hold, in one write.
    @discardableResult
    func removeAll(except keeps: (UUID) -> Bool) -> Bool {
        transact { document in
            document.summaries = document.summaries.filter { key, _ in UUID(uuidString: key).map(keeps) ?? false }
        }
    }

    /// Read the file again. False when it could not be read.
    @discardableResult
    func reload() -> Bool {
        transact { _ in }
    }

    // MARK: - Persistence

    /// One read-change-write under the lock, the only place it is held. Nothing is
    /// written when `change` left the document as it was.
    private func transact(_ change: (inout Document) -> Void) -> Bool {
        guard let lock = acquireLock() else { return false }
        defer { close(lock) } // Closing the only descriptor releases the lock.
        guard let onDisk = readDocument() else { return false }
        adopt(onDisk)
        var document = onDisk
        change(&document)
        guard document != onDisk else { return true }
        guard save(document) else { return false }
        adopt(document)
        return true
    }

    private func adopt(_ document: Document) {
        let byID = Dictionary(document.summaries.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }) { first, _ in first }
        if summaries != byID { summaries = byID }
    }

    /// An exclusive lock on the lock file beside the summaries, as an open descriptor,
    /// or nil when it stays held past the bound or cannot be opened.
    private func acquireLock() -> Int32? {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(path.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            logger.error("Meeting summaries not saved: lock file failed to open, errno \(errno, privacy: .public)")
            return nil
        }
        let deadline = ContinuousClock.now + Self.lockWaitBound
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR, ContinuousClock.now < deadline else {
                logger.error("Meeting summaries not saved: lock not acquired, errno \(failure, privacy: .public)")
                close(descriptor)
                return nil
            }
            usleep(Self.lockRetryInterval)
        }
        return descriptor
    }

    /// The file's content under the lock: empty for no file, and for one that could
    /// not be read or decoded once it is moved aside; nil when it could not be moved.
    private func readDocument() -> Document? {
        let empty = Document(version: Self.formatVersion, summaries: [:])
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileReadNoSuchFile {
            return empty
        } catch {
            logger.error("Meeting summaries do not read: \(error.localizedDescription, privacy: .private)")
            return moveUnreadableFileAside() ? empty : nil
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version == Self.formatVersion else {
            logger.error("Meeting summaries do not decode")
            return moveUnreadableFileAside() ? empty : nil
        }
        return document
    }

    /// An earlier unreadable copy is replaced; only the latest one is worth keeping.
    private func moveUnreadableFileAside() -> Bool {
        let aside = path.appendingPathExtension("unreadable")
        do {
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: path, to: aside)
            return true
        } catch {
            logger.error("Unreadable meeting summaries not moved aside: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func save(_ document: Document) -> Bool {
        let staging = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".tmp")
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: staging)
            try? FileManager.default.restrictToOwner(staging)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: staging)
            try? FileManager.default.restrictToOwner(path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            logger.error("Meeting summaries not saved: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
