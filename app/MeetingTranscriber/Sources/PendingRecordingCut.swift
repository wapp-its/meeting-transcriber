import Darwin
import Foundation
import os

/// The meeting-end cut of one in-progress recording, kept on disk so it
/// survives the process.
///
/// A detected meeting whose signal disappears is not stopped at once: the
/// person is asked whether it ended, and the recording runs on while they
/// decide. An unanswered question cuts the saved recording back to where the
/// silent stop used to end it. That cut point lived only in memory, so an app
/// that died while asking (a crash, a Force Quit, a power loss, or a plain
/// quit, which ends a recording abruptly as well) left the next launch's
/// recovery a recording with the room audio recorded while asking still in
/// it. This record is what recovery reads to make the same cut.
///
/// One small owner-only JSON file per recording in the staging folder, beside
/// the recording's in-progress marker, named by and carrying its stem. Its own
/// file rather than content in the marker: the recorder removes the marker as
/// soon as the stopped recording's mix exists, which is before the live cut
/// runs, and the marker's age anchors the reaping of dead markers.
///
/// Every change is durable, not only atomic, so it survives a power loss as
/// well as a process death. `Data.write(options: .atomic)` renames but syncs
/// neither the file nor the folder, which is why this type owns its sequence.
///
/// Dates use `JSONEncoder`'s default encoding, a `Double` of seconds since
/// 2001 as in the pipeline snapshot, which brings a `Date` back bit for bit.
/// `.iso8601`, which the record-only sidecar uses, drops the fractional
/// seconds that `keptSeconds` and the deadline check compare.
struct PendingRecordingCut: Codable, Equatable, Sendable {
    /// The record format this build writes and applies.
    static let currentVersion = 1

    let version: Int
    /// The recording's stem, compared with the file's own name on read.
    let stem: String
    /// Where the saved audio has to end: the signal loss plus the end grace,
    /// wall clock.
    let cutAt: Date
    /// When the loop saw capture running, the origin the live cut measures
    /// `cutAt` from, wall clock.
    let startedAt: Date
    /// When the countdown would end the recording unanswered, wall clock.
    let deadline: Date
    /// When capture stopped, wall clock. Set once, by the live stop or by the
    /// first recovery pass that sees the record, and never changed afterwards.
    var captureEndedAt: Date?
    /// The resolved cut on the recording's own timeline, in seconds from its
    /// first frame. Set before any track is cut and never changed afterwards:
    /// the placement reads the mix's length, which the cut itself shortens, so
    /// placing it again on a cut recording would cut deeper.
    var keptSeconds: TimeInterval?

    init(
        stem: String,
        cutAt: Date,
        startedAt: Date,
        deadline: Date,
        captureEndedAt: Date? = nil,
        keptSeconds: TimeInterval? = nil,
    ) {
        version = Self.currentVersion
        self.stem = stem
        self.cutAt = cutAt
        self.startedAt = startedAt
        self.deadline = deadline
        self.captureEndedAt = captureEndedAt
        self.keptSeconds = keptSeconds
    }

    /// What a read found.
    enum ReadResult: Equatable, Sendable {
        /// No file: nothing was stored for this recording, or it was removed.
        case absent
        case valid(PendingRecordingCut)
        /// A file that must never be applied.
        case invalid(InvalidReason)
    }

    enum InvalidReason: Equatable, Sendable {
        /// The file could not be read, or its bytes are not a record.
        case unreadable
        /// Zero bytes: what a removal that could not unlink the file leaves.
        case empty
        case unknownVersion
        /// The stem inside differs from the file's own name.
        case otherRecording
        /// Not `startedAt ≤ cutAt ≤ deadline`.
        case timesOutOfOrder
        case nonPositiveKeptSeconds
    }

    /// How a write or a `recordResolution` ended.
    enum WriteOutcome: Sendable {
        /// The new record is in place and on disk.
        case written
        /// It failed before the rename: whatever was stored before is
        /// untouched, and no temporary file is left behind.
        case notPublished(any Error)
        /// The new record is in place, but the folder sync after the rename
        /// failed, so a power loss could still bring the old state back.
        case publishedNotSynced(any Error)
    }

    /// How a removal ended.
    enum RemoveOutcome: Sendable {
        /// The file is gone and the folder synced.
        case removed
        /// The file is gone, but the folder sync failed.
        case removedNotSynced(any Error)
        /// The unlink failed, so the file was emptied and synced instead. An
        /// empty file never reads as a record, so it is never applied.
        case emptied(unlinkError: any Error)
        /// Neither the unlink nor the emptying worked.
        case failed(unlinkError: any Error, emptyError: any Error)
    }

    /// Why `recordResolution` found nothing to update.
    enum ResolutionError: Error, Equatable {
        case noRecord
        case invalidRecord(InvalidReason)
    }

    /// Flushes one open descriptor to stable storage. A parameter of every
    /// change so tests can pin the order of the syncs and make one fail.
    typealias Sync = (Int32) throws -> Void

    // MARK: - Storage

    /// Path of the stored cut for one recording.
    static func url(stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(stem + RecordingFileSuffix.pendingCut)
    }

    /// Store `record` in place of whatever is stored for its recording.
    ///
    /// The record goes to a hidden temporary file beside the target, a new one
    /// per write and owner-only before it holds any data. That file is fully
    /// synced and renamed over the target, and the folder is synced last, so
    /// the rename itself is on disk. The rename is the only step that
    /// publishes: a reader finds the old record or the new one, never part of
    /// either.
    static func write(_ record: Self, in dir: URL, sync: Sync = Self.fullSync) -> WriteOutcome {
        let target = url(stem: record.stem, in: dir)
        let temporary = dir.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).writing")
        do {
            let data = try JSONEncoder().encode(record)
            try writeSynced(data, to: temporary, sync: sync)
            try RecordingCut.rename(temporary, target)
        } catch {
            _ = unlink(temporary.path)
            return .notPublished(error)
        }
        do {
            try syncFolder(dir, sync: sync)
        } catch {
            return .publishedNotSynced(error)
        }
        return .written
    }

    /// Read the stored cut for one recording and say whether it may be
    /// applied: its version is known, its stem is the file's own, `startedAt ≤
    /// cutAt ≤ deadline`, and `keptSeconds`, when present, is positive.
    static func read(stem: String, in dir: URL) -> ReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url(stem: stem, in: dir))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .invalid(.unreadable)
        }
        guard !data.isEmpty else { return .invalid(.empty) }
        let decoder = JSONDecoder()
        // The version alone first: a later format need not decode as this one.
        guard let format = try? decoder.decode(Format.self, from: data) else { return .invalid(.unreadable) }
        guard format.version == currentVersion else { return .invalid(.unknownVersion) }
        guard let record = try? decoder.decode(Self.self, from: data) else { return .invalid(.unreadable) }
        guard record.stem == stem else { return .invalid(.otherRecording) }
        guard record.startedAt <= record.cutAt, record.cutAt <= record.deadline else { return .invalid(.timesOutOfOrder) }
        guard record.keptSeconds.map({ $0 > 0 }) ?? true else { return .invalid(.nonPositiveKeptSeconds) }
        return .valid(record)
    }

    /// Store how the cut was resolved: each value only where the stored record
    /// has none, so a value already there is never changed. The merged record
    /// is written as `write` writes, and the outcome is `write`'s. Without a
    /// valid record to update nothing is written, and the outcome is
    /// `notPublished` with a `ResolutionError`.
    ///
    /// A read followed by a write, not one atomic step: two changes to the
    /// same recording's record must not run at once. Callers keep them apart:
    /// the hold separates this process's stop from recovery, and recovery
    /// passes must not overlap.
    static func recordResolution(
        stem: String,
        in dir: URL,
        keptSeconds: TimeInterval?,
        captureEndedAt: Date?,
        sync: Sync = Self.fullSync,
    ) -> WriteOutcome {
        var record: Self
        switch read(stem: stem, in: dir) {
        case let .valid(stored): record = stored
        case .absent: return .notPublished(ResolutionError.noRecord)
        case let .invalid(reason): return .notPublished(ResolutionError.invalidRecord(reason))
        }
        if record.keptSeconds == nil { record.keptSeconds = keptSeconds }
        if record.captureEndedAt == nil { record.captureEndedAt = captureEndedAt }
        return write(record, in: dir, sync: sync)
    }

    /// Remove the stored cut for one recording: unlink it, then sync the
    /// folder. A file that is already gone counts as removed and the folder is
    /// still synced, which also makes an earlier removal whose sync failed
    /// durable. When the unlink fails, the file is emptied and fully synced
    /// instead.
    static func remove(stem: String, in dir: URL, sync: Sync = Self.fullSync) -> RemoveOutcome {
        let target = url(stem: stem, in: dir)
        if unlink(target.path) != 0 {
            let unlinkError = lastPOSIXError()
            if unlinkError.code != .ENOENT {
                do {
                    try empty(target, sync: sync)
                } catch {
                    return .failed(unlinkError: unlinkError, emptyError: error)
                }
                return .emptied(unlinkError: unlinkError)
            }
        }
        do {
            try syncFolder(dir, sync: sync)
        } catch {
            return .removedNotSynced(error)
        }
        return .removed
    }

    /// The production sync. `F_FULLFSYNC` is what reaches the storage itself
    /// on macOS; a plain `fsync` hands the data to the drive, whose cache can
    /// still lose it on a power loss. A file system that does not support
    /// `F_FULLFSYNC` gets `fsync` instead, as SQLite does. Unlike SQLite,
    /// which falls back on any failure, only the answers that mean "not
    /// supported here" fall back: an I/O error is reported as it is, because
    /// an `fsync` after it may return success without anything having reached
    /// the disk.
    static func fullSync(_ descriptor: Int32) throws {
        let fullSyncCode = errorCode { fcntl(descriptor, F_FULLFSYNC) }
        guard fullSyncCode != 0 else { return }
        guard fullSyncUnsupported.contains(fullSyncCode) else { throw posixError(fullSyncCode) }
        let syncCode = errorCode { fsync(descriptor) }
        guard syncCode == 0 else { throw posixError(syncCode) }
    }

    /// What `F_FULLFSYNC` answers on a file system that does not implement
    /// it. Drivers decline it in different words: the default vnode operation
    /// answers `ENOTSUP`, one with no ioctl handler `ENOTTY`, others
    /// `EOPNOTSUPP`, `EINVAL` or `ENOSYS`. Each says the request was not
    /// understood, none that a write failed.
    private static let fullSyncUnsupported: Set<Int32> = [ENOTSUP, EOPNOTSUPP, ENOTTY, EINVAL, ENOSYS]

    /// The version field alone, read before the whole record.
    private struct Format: Decodable {
        let version: Int
    }

    /// Create `url` owner-only, write `data` into it and sync it. The file is
    /// new (`O_EXCL`), so nothing is ever written through an existing file or
    /// link.
    private static func writeSynced(_ data: Data, to url: URL, sync: Sync) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(FileManager.ownerOnlyPermissions))
        guard descriptor >= 0 else { throw lastPOSIXError() }
        defer { _ = close(descriptor) }
        // Exactly 0600 whatever the umask left of the mode, before any data.
        try FileManager.default.restrictToOwner(url)
        try data.withUnsafeBytes { try writeAll($0, to: descriptor) }
        try sync(descriptor)
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        guard let base = bytes.baseAddress else { return }
        var written = 0
        while written < bytes.count {
            let count = Darwin.write(descriptor, base + written, bytes.count - written)
            if count < 0 {
                if errno == EINTR { continue }
                throw lastPOSIXError()
            }
            written += count
        }
    }

    /// Truncate `url` to zero bytes and sync it. Never follows a link, so only
    /// the stored cut itself can be emptied.
    private static func empty(_ url: URL, sync: Sync) throws {
        let descriptor = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw lastPOSIXError() }
        defer { _ = close(descriptor) }
        guard ftruncate(descriptor, 0) == 0 else { throw lastPOSIXError() }
        try sync(descriptor)
    }

    /// Sync the folder itself, so a rename or an unlink in it is on disk.
    private static func syncFolder(_ dir: URL, sync: Sync) throws {
        let descriptor = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw lastPOSIXError() }
        defer { _ = close(descriptor) }
        try sync(descriptor)
    }

    /// Run a call that answers -1 and sets `errno` on failure, again while it
    /// is interrupted by a signal. 0 on success, else the error code.
    private static func errorCode(_ call: () -> Int32) -> Int32 {
        while call() == -1 {
            let code = errno
            if code != EINTR { return code }
        }
        return 0
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// The error the failed call just before this one left in `errno`.
    private static func lastPOSIXError() -> POSIXError {
        posixError(errno)
    }

    // MARK: - This process's hold

    /// Stems whose stored cut belongs to a stop of this process that has not
    /// settled it yet: the recording is live, or stopped and not yet cut.
    /// Recovery also runs on queue rebuilds while this process may be
    /// recording; it leaves these alone and treats every other stored cut as
    /// its own. No clock is involved. Behind a lock rather than an actor
    /// because recovery reads it off the main actor.
    private static let holds = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func hold(_ stem: String) {
        holds.withLock { _ = $0.insert(stem) }
    }

    static func release(_ stem: String) {
        holds.withLock { _ = $0.remove(stem) }
    }

    static func isHeld(_ stem: String) -> Bool {
        holds.withLock { $0.contains(stem) }
    }

    /// Test-only: drop every hold, so one test's holds never reach the next.
    static func releaseAllForTesting() {
        holds.withLock { $0.removeAll() }
    }
}
