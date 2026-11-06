import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingFileRemover")

/// The running app behind a pending deletion. The development and the release
/// build share the data folder, so a deletion found pending may be one the other
/// build is doing right now: only a process that has ended left it abandoned.
///
/// By process ID and start time, as a later process can reuse the ID. Not by
/// bundle ID, which is what tells the two builds apart in the first place.
struct DeletionProcess: Codable, Equatable, Sendable {
    let pid: Int32
    let launchTime: Date

    static let current = Self(pid: getpid(), launchTime: startTime(of: getpid()) ?? .distantPast)

    /// Answers true when it cannot tell, which is what the App Store build's
    /// sandbox may answer about another process: leaving a deletion alone only
    /// shows it as unfinished for longer, while taking over a live one would have
    /// two builds moving the same files.
    static func isRunning(_ process: Self) -> Bool {
        if kill(process.pid, 0) != 0, errno == ESRCH { return false }
        guard let started = startTime(of: process.pid) else { return true }
        return abs(process.launchTime.timeIntervalSince(started)) < 0.000_000_5
    }

    /// When `pid` started, as the kernel records it, or nil when the kernel does not
    /// say. A missing process answers success with size 0.
    private static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}

/// Moves a meeting's files to the Trash or deletes them for good, one at a time,
/// keeping the record in step: a crash at any point leaves each file listed as
/// present, as being deleted, or as gone.
///
/// The caller picks the mode, and a refused move never turns into the other one:
/// a mistake made by hand stays recoverable.
struct MeetingFileRemover {
    enum Mode {
        case trash
        case forGood
    }

    enum Failure: Equatable, Sendable {
        case unreachable
        case replaced
        case listedByAnotherMeeting
        case refused(String)
        case recordNotSaved
    }

    struct FileOutcome: Equatable, Sendable {
        enum Result: Equatable, Sendable {
            case removed
            case alreadyGone
            case failed(Failure)
        }

        let path: String
        let result: Result
    }

    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// `unlink`, because it refuses a folder where `FileManager.removeItem` would
    /// empty it.
    var removeForGood: (URL) throws -> Void = { url in
        guard unlink(url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// One result per file, in order: a file that fails does not stop the next.
    @MainActor
    func remove(_ files: [MeetingFile], mode: Mode, in store: MeetingFileStore, jobID: UUID) -> [FileOutcome] {
        files.map { FileOutcome(path: $0.path, result: remove($0, mode: mode, in: store, jobID: jobID)) }
    }

    @MainActor
    private func remove(_ file: MeetingFile, mode: Mode, in store: MeetingFileStore, jobID: UUID) -> FileOutcome.Result {
        switch MeetingFilePresence.of(file.path) {
        case .gone:
            store.setState(.gone, ofFileAt: file.path, jobID: jobID)
            return .alreadyGone

        case .unreachable:
            return .failed(.unreachable)

        case .present:
            break
        }
        guard Self.isTheRecordedFile(file) else { return .failed(.replaced) }
        switch store.startRemoving(path: file.path, jobID: jobID) {
        case .marked:
            break

        case .listedByAnotherMeeting:
            return .failed(.listedByAnotherMeeting)

        case .notSaved:
            return .failed(.recordNotSaved)
        }
        let url = URL(filePath: file.path, directoryHint: .notDirectory)
        do {
            switch mode {
            case .trash: try trash(url)
            case .forGood: try removeForGood(url)
            }
        } catch {
            logger.error("A meeting file was not removed: \(error.localizedDescription, privacy: .private)")
            store.setState(.present, ofFileAt: file.path, jobID: jobID)
            return .failed(.refused(Self.refusalText(of: error, mode: mode)))
        }
        store.setState(.gone, ofFileAt: file.path, jobID: jobID)
        return .removed
    }

    /// Whether the path still leads to the regular file the record names, in the
    /// folder it names. A file replaced at the path has another identity; a folder
    /// replaced by a symbolic link leaves the identity alone, as it reaches the very
    /// same file, and only the resolved folder tells.
    private static func isTheRecordedFile(_ file: MeetingFile) -> Bool {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        let folder = URL(filePath: file.path, directoryHint: .notDirectory).deletingLastPathComponent()
        guard MeetingFile.resolvedPath(folder) == folder.path else { return false }
        return file.identity == FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// What a row shows for a refused file. The system's own text for a volume
    /// without a Trash is only an error number. Not measured on a real volume: these
    /// are the errors `trashItem` is reported to throw there.
    private static func refusalText(of error: any Error, mode: Mode) -> String {
        let nsError = error as NSError
        let noTrash = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFeatureUnsupportedError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOTSUP))
        return mode == .trash && noTrash ? "this volume has no Trash" : error.localizedDescription
    }

    /// The sentence "Deletion incomplete:" goes on with, or nil when nothing failed.
    /// Refusals are not counted, as their text comes from the system.
    static func failureReason(of outcomes: [FileOutcome]) -> String? {
        let failures = outcomes.compactMap { outcome -> Failure? in
            if case let .failed(failure) = outcome.result { return failure }
            return nil
        }
        guard !failures.isEmpty else { return nil }
        let count = { (failure: Failure) in failures.count { $0 == failure } }
        let counted = [
            (count(.unreachable), "is on a drive or in a folder that is not available", "are on a drive or in a folder that is not available"),
            (count(.replaced), "was replaced", "were replaced"),
            (count(.listedByAnotherMeeting), "is also listed by another meeting", "are also listed by another meeting"),
        ]
        var parts = counted.compactMap { number, one, many -> String? in
            switch number {
            case 0: nil
            case 1: "1 file \(one)"
            default: "\(number) files \(many)"
            }
        }
        for case let .refused(text) in failures where !parts.contains(text) {
            parts.append(text)
        }
        if failures.contains(.recordNotSaved) { parts.append("the meeting's record could not be saved") }
        return parts.joined(separator: "; ")
    }
}
