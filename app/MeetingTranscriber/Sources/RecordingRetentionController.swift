import Foundation
import Observation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingRetention")

/// Deletes finished meetings' audio for good as `AppSettings.recordingRetention`
/// says. `RecordingRetentionRule` decides, from the record alone; this asks the disk
/// and the queue right before it deletes. `AppState` owns it as `recordingRetention`.
///
/// - **Nothing happens before `start()`.** `AppState` is built by many unit tests,
///   so `init` only stores its inputs, and the menu-bar `.task` calls `start()`.
/// - **When it checks:** at `start()`, every `interval`, on `requestCheck`, which the
///   pipeline calls when a meeting reaches `.done`, when a Notion export ends and after
///   a rebuild, shortly after `apply`, and never two at once. `Task.sleep` counts
///   through system sleep (see `LivenessMarker`).
/// - **Paths come from the record.** It never resolves an output folder to find a
///   file, so the silent fallback folder cannot lead it to anything.
/// - **Automatic deletions never read as incomplete.** A file that is out of reach or
///   refuses to go stays listed and is tried again at the next check.
@MainActor
@Observable
final class RecordingRetentionController {
    /// How long after a confirmed setting the check comes. A moment, so the choice can
    /// still be changed, and well inside the minute the preview promises.
    static let settingChangeDelay = Duration.seconds(5)

    private(set) var isChecking = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: MeetingFileStore
    @ObservationIgnored private let remover: MeetingFileRemover
    @ObservationIgnored private let liveState: @MainActor (UUID) -> LiveMeetingState?
    @ObservationIgnored private let isListed: @MainActor (UUID) -> Bool
    @ObservationIgnored private let securityScope: SecurityScopeAccess
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let settingChangeDelay: Duration
    @ObservationIgnored private let readFile: @Sendable (String) -> RetentionPreview.FileOnDisk

    @ObservationIgnored private var started = false
    @ObservationIgnored private var checkAgain = false
    /// The one request waiting for its moment, and that moment.
    @ObservationIgnored private var waiting: (task: Task<Void, Never>, until: ContinuousClock.Instant)?

    init(
        settings: AppSettings,
        store: MeetingFileStore,
        remover: MeetingFileRemover,
        liveState: @escaping @MainActor (UUID) -> LiveMeetingState?,
        isListed: @escaping @MainActor (UUID) -> Bool,
        securityScope: SecurityScopeAccess = .live,
        interval: Duration = .seconds(24 * 60 * 60),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = { Date() },
        settingChangeDelay: Duration = settingChangeDelay,
        readFile: @escaping @Sendable (String) -> RetentionPreview.FileOnDisk = RetentionPreview.FileOnDisk.read,
    ) {
        self.settings = settings
        self.store = store
        self.remover = remover
        self.liveState = liveState
        self.isListed = isListed
        self.securityScope = securityScope
        self.interval = interval
        self.calendar = calendar
        self.now = now
        self.settingChangeDelay = settingChangeDelay
        self.readFile = readFile
    }

    /// Asks `pipeline` for everything and is told by it when a meeting settles.
    convenience init(pipeline: PipelineController) {
        self.init(
            settings: pipeline.settings,
            store: pipeline.meetingFileStore,
            remover: pipeline.fileRemover,
            liveState: { pipeline.liveMeetingState(jobID: $0) },
            isListed: { pipeline.listsMeeting(jobID: $0) },
            securityScope: pipeline.queueEnvironment.securityScope,
            now: pipeline.now,
        )
        pipeline.onMeetingSettled = { [weak self] in self?.requestCheck() }
    }

    /// One check now, then one every `interval`. A second call does nothing.
    func start() {
        guard !started else { return }
        started = true
        requestCheck()
        Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                requestCheck()
            }
        }
    }

    /// Ask for a check `delay` from now. Requests run as one: the earliest moment
    /// asked for decides, so a setting's delay never holds up a finished meeting.
    /// Runs in a task of its own also without a delay, as a job's callback comes
    /// before the queue has written down that the job finished.
    func requestCheck(after delay: Duration = .zero) {
        let moment = ContinuousClock.now + delay
        if let waiting, waiting.until <= moment { return }
        waiting?.task.cancel()
        let task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(until: moment, clock: .continuous) }
            guard !Task.isCancelled, let self else { return }
            waiting = nil
            await checkNow()
        }
        waiting = (task, moment)
    }

    /// Run a check, or if one is running, have one more run after it, as the state
    /// this request came for may be newer than what the running one has read.
    func checkNow() async {
        guard !isChecking else {
            checkAgain = true
            return
        }
        isChecking = true
        repeat {
            checkAgain = false
            await runOneCheck()
        } while checkAgain
        isChecking = false
    }

    // MARK: - The setting

    /// What `retention` would delete now, by the check's own rule, changing nothing. The
    /// disk is asked off the main actor, as this runs from Settings and a network volume
    /// can block for as long as it likes. The answer is what the user agrees to; the check
    /// that follows deletes what the rule selects at that moment.
    func preview(for retention: RecordingRetention) async -> RetentionPreview {
        store.reload()
        let selection = RetentionPreview.Selection(
            records: store.records, live: { liveState($0) }, retention: retention, now: now(), calendar: calendar,
        )
        let paths = Set(selection.meetings.joined().map(\.path))
        guard !paths.isEmpty else { return RetentionPreview(selection) { _ in .gone } }
        let closeScope = openOutputFolderScope()
        defer { closeScope() }
        let answers = await Self.read(paths, with: readFile)
        let preview = RetentionPreview(selection) { answers[$0.path] ?? .unreachable }
        let skipped = preview.skipped
        logger.notice(
            """
            Retention preview for \(retention.rawValue, privacy: .public): \(preview.meetingCount, privacy: .public) meetings, \
            \(preview.unreachableFiles, privacy: .public) files out of reach; skipped \(skipped.kept, privacy: .public) kept, \
            \(skipped.failed, privacy: .public) failed, \(skipped.imported, privacy: .public) imported, \
            \(skipped.fromBeforeThisFeature, privacy: .public) from before this feature
            """,
        )
        return preview
    }

    /// A value the user confirmed: saved now, and a check within the minute the preview
    /// promised. The check reads the setting when it runs, so going back to Never during
    /// the delay keeps the audio.
    func apply(_ retention: RecordingRetention) {
        settings.recordingRetention = retention
        requestCheck(after: settingChangeDelay)
    }

    // MARK: - One check

    /// A meeting chosen by the rule, as the record read then said.
    private struct Selected {
        let record: MeetingFileRecord
        let files: [MeetingFile]
    }

    private func runOneCheck() async {
        store.reload()
        let retention = settings.recordingRetention
        let time = now()
        let selected = select(retention: retention, at: time)
        guard !selected.isEmpty || store.records.contains(where: mayBePruned) else { return }
        let closeScope = openOutputFolderScope()
        defer { closeScope() }
        for meeting in selected {
            await deleteAudio(of: meeting, at: time)
        }
        await pruneRecords()
    }

    private func select(retention: RecordingRetention, at time: Date) -> [Selected] {
        store.records.compactMap { record in
            // The rule alone settles most, and the queue's answer can read a file.
            guard !audioToDelete(record, live: nil, retention: retention, at: time).isEmpty else { return nil }
            let files = audioToDelete(record, live: liveState(record.jobID), retention: retention, at: time)
            return files.isEmpty ? nil : Selected(record: record, files: files)
        }
    }

    private func audioToDelete(
        _ record: MeetingFileRecord, live: LiveMeetingState?, retention: RecordingRetention, at time: Date,
    ) -> [MeetingFile] {
        RecordingRetentionRule.audioToDelete(record: record, live: live, retention: retention, now: time, calendar: calendar)
    }

    /// The deletion never reaches a meeting whose notes are not a file on the disk that
    /// can be read, as the audio would then be the last copy, whatever the record last
    /// marked. The disk is asked off the main actor, because it can block on a network
    /// volume, and everything is read again after that wait, down to the setting.
    private func deleteAudio(of meeting: Selected, at time: Date) async {
        let record = meeting.record
        let notes = Self.notesToFind(in: record)
        let answers = await Self.presence(of: meeting.files.map(\.path) + notes.map(\.path))
        let readableNotes = await Self.readableFiles(among: notes.map(\.path))

        store.reload()
        let unchanged = store.record(for: record.jobID) == record && audioToDelete(
            record, live: liveState(record.jobID), retention: settings.recordingRetention, at: time,
        ) == meeting.files
        guard unchanged else {
            logger.notice("Automatic deletion skipped meeting \(Self.shortID(record), privacy: .public): it changed")
            return
        }
        if !record.savedToNotion, !notes.contains(where: { readableNotes.contains($0.path) }) {
            store.markGone(jobID: record.jobID, roles: Set(notes.filter { answers[$0.path] == .gone }.map(\.role)))
            logger.notice("Automatic deletion kept meeting \(Self.shortID(record), privacy: .public): no saved notes found")
            return
        }
        // Nothing here for this pass to delete, so no deletion begins: a crash after
        // its mark would have the launch date one the app never did.
        guard meeting.files.contains(where: { answers[$0.path] == .present }) else {
            store.markGone(jobID: record.jobID, roles: Set(meeting.files.filter { answers[$0.path] == .gone }.map(\.role)))
            logger.notice("Automatic deletion found nothing to delete of meeting \(Self.shortID(record), privacy: .public)")
            return
        }
        // Every file, also those out of reach: a crash now must not let the launch
        // date a deletion that left one on another drive.
        let paths = meeting.files.map(\.path)
        guard store.beginDeletion(jobID: record.jobID, kind: .automatic, paths: paths, unchangedFrom: record) else {
            logger.notice("Automatic deletion skipped meeting \(Self.shortID(record), privacy: .public): its mark was not saved")
            return
        }
        let reachable = meeting.files.filter { answers[$0.path] != .unreachable }
        finish(record, outcomes: remover.remove(reachable, mode: .forGood, in: store, jobID: record.jobID), of: meeting.files, at: time)
    }

    /// Dated only when this pass deleted something and nothing is left: audio that
    /// was all gone already was not deleted by the app.
    private func finish(
        _ record: MeetingFileRecord, outcomes: [MeetingFileRemover.FileOutcome], of files: [MeetingFile], at time: Date,
    ) {
        let failed = outcomes.filter { outcome in
            if case .failed = outcome.result { return true }
            return false
        }.count
        let outOfReach = files.count - outcomes.count
        let complete = failed == 0 && outOfReach == 0 && outcomes.contains { $0.result == .removed }
        let saved = store.finishDeletion(jobID: record.jobID, outcomes: outcomes) { now in
            if complete { now.audioDeletion = .init(kind: .automatic, at: time) }
        }
        let meeting = Self.shortID(record)
        if !saved {
            // The pending mark stays, so the next launch settles it from the disk.
            logger.error("Automatic deletion of meeting \(meeting, privacy: .public) was not saved")
        }
        if complete {
            logger.notice("Automatic deletion removed the audio of meeting \(meeting, privacy: .public)")
        } else if failed > 0 || outOfReach > 0 {
            logger.error(
                "Automatic deletion retries meeting \(meeting, privacy: .public): \(failed, privacy: .public) failed, \(outOfReach, privacy: .public) out of reach",
            )
            if let reason = MeetingFileRemover.failureReason(of: outcomes) {
                // The system's text can name a file.
                logger.error("Automatic deletion: \(reason, privacy: .private)")
            }
        }
    }

    /// The files that say a meeting's notes are saved, none for a completed Notion
    /// export (A8): its protocol, or with notes off (A1) also its transcript, as far as
    /// the record still lists them. A finished meeting with notes off always has its
    /// transcript, as only a saved protocol removes that; without it the audio is all
    /// there is of the meeting.
    private static func notesToFind(in record: MeetingFileRecord) -> [MeetingFile] {
        guard !record.savedToNotion else { return [] }
        return record.files.filter { file in
            guard file.state == .present else { return false }
            if case .finished(protocolExpected: false) = record.outcome, file.role == .transcript { return true }
            return file.role == .protocol
        }
    }

    /// The chosen folder's scope for one pass, and what closes it. The paths come from
    /// the record, and on `.fallback` there is no chosen folder to open.
    private func openOutputFolderScope() -> () -> Void {
        guard case let .custom(root) = settings.outputDirectoryResolution, securityScope.start(root) else { return {} }
        return { [securityScope] in securityScope.stop(root) }
    }

    // MARK: - Pruning

    /// Whether a record can go once nothing of it remains. Its row is what the record
    /// is kept for (A12), a deletion's mark says something is under way, and
    /// `inProgress` may be another build between moving a file and listing its new path.
    private func mayBePruned(_ record: MeetingFileRecord) -> Bool {
        record.pending == nil && record.outcome != .inProgress && !isListed(record.jobID)
    }

    /// A record goes when the disk answers gone for every file it ever listed, also
    /// those marked gone, which may be back from the Trash.
    private func pruneRecords() async {
        for record in store.records where mayBePruned(record) {
            let answers = await Self.presence(of: record.files.map(\.path))
            guard answers.values.allSatisfy({ $0 == .gone }), !isListed(record.jobID) else { continue }
            if store.remove(unchanged: record) {
                logger.notice("Removed the record of meeting \(Self.shortID(record), privacy: .public): nothing of it is left")
            }
        }
    }

    // MARK: - Helpers

    private static func shortID(_ record: MeetingFileRecord) -> String {
        String(record.jobID.uuidString.prefix(8))
    }

    nonisolated private static func presence(of paths: [String]) async -> [String: MeetingFilePresence] {
        await Task.detached(priority: .utility) {
            Dictionary(paths.map { ($0, MeetingFilePresence.of($0)) }) { first, _ in first }
        }.value
    }

    nonisolated private static func read(
        _ paths: Set<String>, with readFile: @escaping @Sendable (String) -> RetentionPreview.FileOnDisk,
    ) async -> [String: RetentionPreview.FileOnDisk] {
        await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, readFile($0)) })
        }.value
    }

    nonisolated private static func readableFiles(among paths: [String]) async -> Set<String> {
        await Task.detached(priority: .utility) {
            Set(paths.filter { MeetingFilePresence.isReadableFile($0) })
        }.value
    }
}

extension PipelineController {
    /// What the queue knows of a meeting. A job the queue has not read yet counts,
    /// as the record says finished a moment before the snapshot does, and a crash in
    /// between comes back as a job still running. Building the queue to ask it would
    /// resume those jobs, so its unread file is read instead, and when the saved jobs
    /// cannot be known the answer is that the meeting is not through, which keeps its
    /// audio.
    func liveMeetingState(jobID: UUID) -> LiveMeetingState? {
        if let job = queue.jobs.first(where: { $0.id == jobID }) {
            return LiveMeetingState(
                state: job.state,
                // A chained re-export reads completed between one export's end and
                // the next one's start, and its task runs throughout.
                notionExportRunning: job.notionExportStatus == .inProgress || queue.notionExportTasks[jobID] != nil,
            )
        }
        guard let saved = jobsTheQueueHasNotRead() else {
            return LiveMeetingState(state: .waiting, notionExportRunning: false)
        }
        return saved.first { $0.id == jobID }.map { job in
            LiveMeetingState(state: job.state, notionExportRunning: job.notionExportStatus == .inProgress)
        }
    }

    /// Whether the All Recordings window still has a row for a meeting. Saved jobs that
    /// cannot be known may hold one.
    func listsMeeting(jobID: UUID) -> Bool {
        if queue.jobs.contains(where: { $0.id == jobID }) || terminalJobStore.lookup(jobID: jobID) != nil { return true }
        return jobsTheQueueHasNotRead()?.contains { $0.id == jobID } ?? true
    }

    // swiftlint:disable discouraged_optional_collection
    /// The saved jobs only the snapshot holds (`loadSnapshot` reads the same two
    /// places), none once a queue has read it or when there is no file, and nil when
    /// they cannot be known: the file does not read, or did not when the queue tried,
    /// which leaves a queue with an engine and an empty list.
    private func jobsTheQueueHasNotRead() -> [PipelineJob]? {
        guard !queue.snapshotRestoreFailed else { return nil }
        guard queue.engine == nil else { return [] }
        let logDir = queueEnvironment.logDir
        return try? PipelineSnapshotStore.existing(for: logDir)?.latestSaved ?? PipelineSnapshot.load(from: logDir) ?? []
    }

    // swiftlint:enable discouraged_optional_collection

    /// Call `onMeetingSettled` after the callbacks already on the queue. Last, because
    /// the local-model notices end a noticed job's callback early.
    func chainRetentionTriggers() {
        let announce = queue.onJobStateChange
        queue.onJobStateChange = { [weak self] job, oldState, newState in
            announce?(job, oldState, newState)
            if newState == .done { self?.onMeetingSettled?() }
        }
        let announceExport = queue.onNotionExportFinished
        queue.onNotionExportFinished = { [weak self] job, failureReason in
            announceExport?(job, failureReason)
            self?.onMeetingSettled?()
        }
    }
}
