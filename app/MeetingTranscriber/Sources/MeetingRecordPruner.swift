import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingRecordPruner")

/// Removes the `MeetingFileRecord` of a meeting nothing is left of, so
/// `meeting_files.json` does not grow for good. `AppState` owns it, and the
/// menu-bar `.task` calls `start()`.
///
/// Only the record goes, never a file: a record is removed when the disk answers
/// gone for every file it ever listed, the window no longer lists the meeting, no
/// deletion is under way and its outcome is known. Deleting audio automatically
/// is `RecordingRetention`'s job, by its own registry.
@MainActor
final class MeetingRecordPruner {
    private let store: MeetingFileStore
    private let isListed: @MainActor (UUID) -> Bool
    /// Opens the chosen output folder's scope for one pass and returns what closes
    /// it, so the sandbox can answer for files in it.
    private let openScope: @MainActor () -> () -> Void
    private let interval: Duration
    private var started = false
    private var running = false

    init(
        store: MeetingFileStore,
        isListed: @escaping @MainActor (UUID) -> Bool,
        openScope: @escaping @MainActor () -> () -> Void = { {} },
        interval: Duration = .seconds(24 * 60 * 60),
    ) {
        self.store = store
        self.isListed = isListed
        self.openScope = openScope
        self.interval = interval
    }

    /// The paths come from the record, so on `.fallback` there is no chosen folder to open.
    convenience init(pipeline: PipelineController) {
        let scope = pipeline.queueEnvironment.securityScope
        self.init(
            store: pipeline.meetingFileStore,
            isListed: { pipeline.listsMeeting(jobID: $0) },
            openScope: {
                guard case let .custom(root) = pipeline.settings.outputDirectoryResolution, scope.start(root) else { return {} }
                return { scope.stop(root) }
            },
        )
    }

    /// One pass now, then one every `interval`. A second call does nothing.
    /// `Task.sleep` counts through system sleep (see `LivenessMarker`).
    func start() {
        guard !started else { return }
        started = true
        Task { [weak self, interval] in
            while !Task.isCancelled {
                // Weak across the sleep, so a pruner that goes away (in tests)
                // is not kept alive for a day by its timer.
                await self?.prune()
                guard self != nil else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Whether a record can go once nothing of it remains. Its row is what the record
    /// is kept for, a deletion's mark says something is under way, and `inProgress`
    /// may be another build between moving a file and listing its new path.
    private func mayBePruned(_ record: MeetingFileRecord) -> Bool {
        record.pending == nil && record.outcome != .inProgress && !isListed(record.jobID)
    }

    /// A record goes when the disk answers gone for every file it ever listed, also
    /// those marked gone, which may be back from the Trash. Never two passes at once.
    func prune() async {
        guard !running else { return }
        running = true
        defer { running = false }
        store.reload()
        guard store.records.contains(where: mayBePruned) else { return }
        let closeScope = openScope()
        defer { closeScope() }
        for record in store.records where mayBePruned(record) {
            let answers = await Self.presence(of: record.files.map(\.path))
            guard answers.values.allSatisfy({ $0 == .gone }), !isListed(record.jobID) else { continue }
            if store.remove(unchanged: record) {
                logger.notice("Removed the record of meeting \(String(record.jobID.uuidString.prefix(8)), privacy: .public): nothing of it is left")
            }
        }
    }

    nonisolated private static func presence(of paths: [String]) async -> [String: MeetingFilePresence] {
        await Task.detached(priority: .utility) {
            Dictionary(paths.map { ($0, MeetingFilePresence.of($0)) }) { first, _ in first }
        }.value
    }
}
