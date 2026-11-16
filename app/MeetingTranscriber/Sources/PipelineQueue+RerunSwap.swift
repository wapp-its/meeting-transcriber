import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

extension RerunFailure {
    static let currentFileReplaced = "a current file of the meeting was changed while the re-run ran"
    static let currentFilesUnreachable = "the meeting's files are not reachable"
    static let noEarlierName = "no free name was left for an earlier version"
    static let swapFailed = "the new files could not take the current names"
    static let swapNotRecorded = "the meeting's record could not be updated"
    static let notSaved = "the re-run could not be saved to disk"
}

/// A re-run's success (R5): its transcript and notes take the meeting's current
/// names, and the current ones stay beside them as earlier versions
/// (`EarlierVersionName`). The record is the journal, as for every other end: the
/// list of renames is written into the marker first, then the current files are
/// renamed to their earlier names, then the re-run's files to the current names,
/// each only while it is still the file the record names and with a move that never
/// replaces a file. One record update is the commit point. After it the finished-job
/// entry is written, and once that write landed the job is the meeting's ordinary
/// finished job again; once the queue's snapshot holding it has landed it leaves the
/// re-run file, and then its Notion export starts. A failed step before the commit
/// ends the re-run as R6, whose end moves back every rename made
/// (`closeRerun`); a quit between two steps reads as a row of the launch table
/// (`resumeRerunSwaps`).
extension PipelineQueue {
    typealias Rename = MeetingFileRecord.Rename

    /// The roles the swap gives the current names; every other file of the re-run
    /// (its naming data, its 16 kHz copies) is removed before the renames.
    private static let swappedRoles: [MeetingFile.Role] = [.transcript, .protocol, .segments]

    /// The re-run's speakers are confirmed or skipped and its notes are saved or not
    /// wanted: the swap runs once the job's done state, with its marker and its
    /// queued export, is in the re-run file, so a stop at any step of the swap finds
    /// it there as done (`resumeRerunSwaps`), and once no regeneration runs (as Move
    /// Meeting to Trash waits for one). When that write fails again on the flush's
    /// retry, no rename starts and the re-run ends as R6: after the commit point only
    /// the job in that file says what is left to do.
    func rerunSucceeded(id: UUID) {
        guard let job = job(withID: id), let runID = job.rerun?.marker.runID, let name = rerunFilename else { return }
        logger.info("[\(job.shortID, privacy: .public)] rerun_succeeded")
        let logDir = logDir
        Task { [weak self] in
            await PipelineSnapshotStore.flush(logDir)
            // A flush leaves a store only for a write that failed again on its retry.
            guard PipelineSnapshotStore.existing(for: logDir, named: name) == nil else {
                if let self, isDueForSwap(id: id, runID: runID) {
                    logger.error("[\(PipelineJob.shortID(for: id), privacy: .public)] rerun_done_not_saved: no rename starts")
                    endRerun(id: id, because: .failed(RerunFailure.notSaved))
                }
                return
            }
            while self?.swapWaits(id: id, runID: runID) == true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, isDueForSwap(id: id, runID: runID) else { return }
            swapInRerun(id: id)
        }
    }

    private func isDueForSwap(id: UUID, runID: UUID) -> Bool {
        guard !isRetired, let job = job(withID: id) else { return false }
        return job.state == .done && job.rerun?.marker.runID == runID
    }

    private func swapWaits(id: UUID, runID: UUID) -> Bool {
        isDueForSwap(id: id, runID: runID) && isRegenerationRunning()
    }

    /// The swap from its start: the re-run's other files go, the renames are
    /// planned against the record and the disk, written into the marker, made, and
    /// committed.
    private func swapInRerun(id: UUID) {
        guard let store = meetingFileStore, let job = job(withID: id), let rerun = job.rerun else { return }
        store.reload()
        guard let record = store.record(for: id), let recorded = record.rerun, recorded.runID == rerun.marker.runID else {
            endRerun(id: id, because: .failed(RerunFailure.swapNotRecorded))
            return
        }
        let marker = Self.merged(rerun.marker, into: recorded, ownIsNewer: true)
        let left = removeOtherRerunFiles(of: marker, jobID: id)
        let plan = Self.swapRenames(marker: marker, record: record, base: Self.namingSlug(
            title: job.meetingTitle, jobID: job.id, startTime: job.artifactStartTime,
        ))
        if let refusal = plan.refusal {
            logger.warning("[\(job.shortID, privacy: .public)] rerun_swap_refused reason=\(refusal, privacy: .private)")
            endRerun(id: id, because: .failed(refusal))
            return
        }
        var listed = false
        let saved = store.update(jobID: id) { record in
            guard record.rerun?.runID == marker.runID else { return }
            record.rerun?.renames = plan.renames
            listed = true
        }
        guard saved, listed else {
            endRerun(id: id, because: .failed(RerunFailure.swapNotRecorded))
            return
        }
        var swapped = marker
        swapped.renames = plan.renames
        guard Self.performRenames(plan.renames, jobID: id) == nil else {
            endRerun(id: id, because: .failed(RerunFailure.swapFailed))
            return
        }
        guard Self.commitSwap(swapped, left: left, jobID: id, in: store) else {
            endRerun(id: id, because: .failed(RerunFailure.swapNotRecorded))
            return
        }
        finishCommittedRerun(id: id)
    }

    /// The launch row of a marker with a list of renames whose job this build's file
    /// holds: completed when every file the list names is at one of its two ends,
    /// else ended as R6, which moves back the renames made.
    private func completeSwap(id: UUID, marker: MeetingFileRecord.RerunMarker, renames: [Rename]) {
        guard let store = meetingFileStore else { return }
        let ends = renames.map(Self.whereRenameIs)
        guard ends.allSatisfy({ $0.atTarget || $0.atSource }) else {
            logger.warning("[\(PipelineJob.shortID(for: id), privacy: .public)] rerun_swap_undone_at_launch: a file is missing")
            endRerun(id: id, because: .failed(RerunFailure.swapFailed))
            return
        }
        let left = removeOtherRerunFiles(of: marker, jobID: id)
        let pending = zip(renames, ends).filter { !$0.1.atTarget }.map(\.0)
        guard Self.performRenames(pending, jobID: id) == nil else {
            endRerun(id: id, because: .failed(RerunFailure.swapFailed))
            return
        }
        guard Self.commitSwap(marker, left: left, jobID: id, in: store) else {
            endRerun(id: id, because: .failed(RerunFailure.swapNotRecorded))
            return
        }
        logger.info("[\(PipelineJob.shortID(for: id), privacy: .public)] rerun_swap_completed_at_launch")
        finishCommittedRerun(id: id)
    }

    /// The re-run jobs restored done, by their record: a stamp noted as committed
    /// finishes after the commit point, a marker with a list of renames completes or
    /// undoes the swap, and a marker without one starts the swap.
    func resumeRerunSwaps() {
        let done = jobs.filter { $0.state == .done && $0.rerun != nil }
        for job in done {
            guard let marker = job.rerun?.marker, let record = meetingFileStore?.record(for: job.id) else { continue }
            if let note = record.rerunNote, note.committed, note.stamp == marker.stamp {
                finishCommittedRerun(id: job.id)
            } else if let recorded = record.rerun, recorded.runID == marker.runID {
                if let renames = recorded.renames {
                    completeSwap(id: job.id, marker: Self.merged(marker, into: recorded, ownIsNewer: false), renames: renames)
                } else {
                    rerunSucceeded(id: job.id)
                }
            }
        }
    }

    // MARK: - After the commit point

    /// After the commit point, live and at launch, and safe to repeat: the job takes
    /// the current names the record lists, the earlier segments file goes, the
    /// raw-transcript setting is applied as a new meeting's `.done` applies it, and
    /// the finished-job entry is written.
    /// Only once that write landed does the job turn into an ordinary finished job;
    /// until then it stays in the re-run file. It leaves that file, and its Notion
    /// export starts, only once the queue's snapshot holding it has landed
    /// (`handOverCommittedRerun`).
    func finishCommittedRerun(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let rerun = jobs[index].rerun,
              let record = meetingFileStore?.record(for: id) else { return }
        let transcript = record.files.last { $0.role == .transcript }
        let notes = record.files.last { $0.role == .protocol }
        jobs[index].transcriptPath = transcript.flatMap { $0.state == .gone ? nil : URL(filePath: $0.path) }
        jobs[index].protocolPath = notes.flatMap { $0.state == .gone ? nil : URL(filePath: $0.path) }
        jobs[index].namingSlug = (transcript ?? notes).map { URL(filePath: $0.path).deletingPathExtension().lastPathComponent }
        let madeNotes = rerun.marker.files.contains { $0.role == .protocol }
        let shortID = jobs[index].shortID
        removeEarlierSegments(of: record, marker: rerun.marker, jobID: id)
        // With notes off nothing new was saved, so the transcript is what the run made.
        // A current file the record no longer names (replaced while the app was
        // closed) is left as it is.
        let current = [transcript, record.files.last { $0.role == .segments }].compactMap(\.self)
        if madeNotes, current.allSatisfy({ $0.state == .gone || MeetingFilePresence.of($0.path) == .gone || MeetingFileRemover.isTheRecordedFile($0) }) {
            removeRawTranscriptArtifactsIfSafe(for: index)
        } else if madeNotes {
            logger.warning("[\(shortID, privacy: .public)] rerun_raw_transcript_kept: a current file was replaced")
        }
        guard terminalJobStore?.record(TerminalJobRecord(job: jobs[index])) ?? true else {
            logger.error("[\(shortID, privacy: .public)] rerun_entry_not_saved: the re-run stays in its file")
            saveSnapshot()
            return
        }
        // The re-run file keeps the job as it is now, export state included, until
        // the hand-off below lets it go.
        rerunJobsAwaitingRecord[id] = jobs[index]
        jobs[index].endRerunCommitted()
        jobs[index].exportsToPageDatabase = true
        if !madeNotes, case let .job(held) = rerun.heldEntry, held.notesFailure != nil {
            // Held for a notes retry, which now reads the new transcript (A12).
            jobs[index].notesFailure = held.notesFailure
            jobs[index].notesSpeakerNames = held.notesSpeakerNames
        }
        logger.info("[\(shortID, privacy: .public)] rerun_committed")
        handOverCommittedRerun(id: id, runID: rerun.marker.runID)
        scheduleCompletedJobRemoval(id: id)
        if recordingRetention != nil {
            Task { [weak self] in await self?.sweepRetainedRecordings() }
        }
    }

    /// The committed job moves from the re-run file into the queue's snapshot, two
    /// files with writers of their own: the re-run file keeps it
    /// (`rerunJobsAwaitingRecord`) until the snapshot holding it as an ordinary
    /// finished job has landed, so a quit at any moment leaves the job, and the
    /// export it owes, in one of the two. Then it leaves the re-run file, and only
    /// once that has landed too does its export start, so a launch that finds it
    /// there knows the export never started and starts it once (`resumeRerunSwaps`;
    /// the re-run file's job wins over the snapshot's). A write that fails again on
    /// the flush's retry, as at the swap's start, leaves the job in the re-run file
    /// and the export to the next launch.
    private func handOverCommittedRerun(id: UUID, runID: UUID) {
        saveSnapshot()
        guard let name = rerunFilename else { return }
        let logDir = logDir
        Task { [weak self] in
            await PipelineSnapshotStore.flush(logDir)
            guard let self, !isRetired, let committed = rerunJobsAwaitingRecord[id], committed.rerun?.marker.runID == runID else { return }
            // A flush leaves a store only for a write that failed again on its retry.
            guard PipelineSnapshotStore.existing(for: logDir) == nil else {
                logger.error("[\(PipelineJob.shortID(for: id), privacy: .public)] rerun_handover_not_saved: the re-run stays in its file")
                return
            }
            rerunJobsAwaitingRecord[id] = nil
            saveRerunFile()
            await PipelineSnapshotStore.flush(logDir)
            guard !isRetired else { return }
            guard PipelineSnapshotStore.existing(for: logDir, named: name) == nil else {
                // Still in the file on disk: it stays there, and the export with it.
                rerunJobsAwaitingRecord[id] = committed
                saveRerunFile()
                logger.error("[\(PipelineJob.shortID(for: id), privacy: .public)] rerun_handover_not_removed: the re-run stays in its file")
                return
            }
            startCommittedExport(id: id)
        }
    }

    /// The committed job's Notion export, once its hand-off landed: the one queued
    /// with its notes, or, for one queued before a quit with nothing running it,
    /// one export from the saved notes, as a retry runs it.
    private func startCommittedExport(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].notionExportStatus == .inProgress, pendingNotionExports[id] == nil, notionExportTasks[id] == nil else {
            startPendingNotionExport(jobID: id)
            return
        }
        jobs[index].finishNotionExport(succeeded: false)
        Self.noteNotionExportFailure(
            on: &jobs[index], reason: Self.notionExportInterruptedReason, backupSaved: jobs[index].protocolPath != nil,
        )
        saveSnapshot()
        guard jobs[index].protocolPath != nil, notionExportResolution(forJobID: id).configuration != nil else { return }
        Task { [weak self] in await self?.exportSavedNotes(id: id) }
    }

    /// The meeting's segments file from before the re-run goes once the swap
    /// committed (A22), since only the current transcript is offered for Identify
    /// Speakers Again. The swap moved it to its earlier-version name, so an undo
    /// could put it back, and the commit lists it there as an earlier version, so a
    /// stop before this step leaves it where a deletion of the meeting finds it.
    /// A re-run that kept no segments file of its own (its option was off, or the
    /// write failed) renamed none in, so the current one is still the earlier run's,
    /// which goes too: its words are no longer the current transcript's. The job's
    /// marker lists each file the re-run wrote before its done state was saved, which
    /// the swap waits for, so a current file with none of their identities is not one
    /// (and with an identity of theirs unknown, nothing is taken for the earlier run's).
    /// Safe to repeat: a file already gone counts as removed.
    private func removeEarlierSegments(of record: MeetingFileRecord, marker: MeetingFileRecord.RerunMarker, jobID: UUID) {
        guard let segments = record.files.last(where: { $0.role == .segments }) else { return }
        let names = Set(EarlierVersionName.names(for: segments.path, stamp: marker.stamp))
        var earlier = record.files.filter { file in
            file.role == .previousProtocol && file.state != .gone && names.contains(URL(filePath: file.path).lastPathComponent)
        }
        let written = marker.files.filter { $0.role == .segments }.map(\.identity)
        if segments.state != .gone, let identity = segments.identity, !written.contains(nil), !written.contains(identity) {
            earlier.append(segments)
        }
        guard !earlier.isEmpty else { return }
        let left = Set(Self.removeRerunFiles(earlier, jobID: jobID).map(\.path))
        let removed = Set(earlier.map(\.path)).subtracting(left)
        guard !removed.isEmpty else { return }
        meetingFileStore?.update(jobID: jobID) { record in
            for index in record.files.indices where removed.contains(record.files[index].path) {
                record.files[index].state = .gone
            }
        }
    }

    // MARK: - The plan, the renames and the commit

    /// The swap's renames in the order it makes them: each current file of a role
    /// the re-run wrote to its earlier-version name (the segments file only until
    /// the commit, `removeEarlierSegments`), then each file of the re-run to the
    /// current name of its role. A role without a current file takes the name the
    /// meeting's files have by its current transcript's stem, or its notes' when the
    /// transcript is gone, in their folder, and a segments file in the folder the
    /// re-run wrote it to, where the speaker naming reads it by that stem; a gone
    /// current file keeps no earlier version. A
    /// refusal, with no rename made, when a current file is out of reach, is no
    /// longer the file the record names, or has no earlier name left.
    static func swapRenames(
        marker: MeetingFileRecord.RerunMarker, record: MeetingFileRecord, base: String,
    ) -> (renames: [Rename], refusal: String?) {
        func current(_ role: MeetingFile.Role) -> MeetingFile? {
            record.files.last { $0.role == role }
        }
        let anchor = (current(.transcript) ?? current(.protocol)).map { URL(filePath: $0.path) }
        let stem = anchor.map { $0.deletingPathExtension().lastPathComponent } ?? base
        var earlier: [Rename] = []
        var renamed: [Rename] = []
        var claimed = Set<String>()
        for role in swappedRoles {
            guard let new = marker.files.last(where: { $0.role == role && $0.state != .gone }) else { continue }
            let newFolder = URL(filePath: new.path).deletingLastPathComponent()
            let targetFolder = role == .segments ? newFolder : anchor?.deletingLastPathComponent() ?? newFolder
            let target = current(role)?.path ?? targetFolder.appendingPathComponent(currentName(of: role, stem: stem)).path
            if let file = current(role), file.state != .gone {
                switch MeetingFilePresence.of(file.path) {
                case .unreachable:
                    return ([], RerunFailure.currentFilesUnreachable)

                case .present:
                    guard MeetingFileRemover.isTheRecordedFile(file) else { return ([], RerunFailure.currentFileReplaced) }
                    let folder = URL(filePath: file.path).deletingLastPathComponent()
                    guard let taken = EarlierVersionName.takenNames(in: folder) else {
                        return ([], RerunFailure.currentFilesUnreachable)
                    }
                    guard let name = EarlierVersionName.name(for: file.path, stamp: marker.stamp, taken: taken.union(claimed)) else {
                        return ([], RerunFailure.noEarlierName)
                    }
                    claimed.insert(MeetingReportFolder.folded(name))
                    earlier.append(Rename(
                        role: role, from: file.path, to: folder.appendingPathComponent(name).path, identity: file.identity, earlier: true,
                    ))

                case .gone:
                    break
                }
            }
            renamed.append(Rename(role: role, from: new.path, to: target, identity: new.identity, earlier: false))
        }
        return (earlier + renamed, nil)
    }

    private static func currentName(of role: MeetingFile.Role, stem: String) -> String {
        switch role {
        case .protocol: "\(stem).md"
        case .segments: "\(stem)_segments.json"
        default: "\(stem).txt"
        }
    }

    /// Makes `renames` in order and returns the index of the first that failed,
    /// nil when every one was made.
    static func performRenames(_ renames: [Rename], jobID: UUID) -> Int? {
        for (index, rename) in renames.enumerated() {
            if let reason = move(rename, from: rename.from, to: rename.to) {
                logger.warning(
                    "[\(PipelineJob.shortID(for: jobID), privacy: .public)] rerun_rename_failed step=\(index, privacy: .public) reason=\(reason, privacy: .private)",
                )
                return index
            }
        }
        return nil
    }

    /// Moves back each of `renames` that was made, the last first; those not made
    /// stay where they are, and one at neither end is logged. Returns the files of
    /// the renames made that could not go back, at the name they have now.
    @discardableResult
    static func undoRenames(_ renames: [Rename], jobID: UUID) -> [MeetingFile] {
        var stuck: [MeetingFile] = []
        for rename in renames.reversed() {
            let ends = whereRenameIs(rename)
            guard !ends.atSource else { continue }
            guard let reason = ends.atTarget ? move(rename, from: rename.to, to: rename.from) : "missing" else { continue }
            logger.warning(
                "[\(PipelineJob.shortID(for: jobID), privacy: .public)] rerun_rename_not_undone reason=\(reason, privacy: .private)",
            )
            if ends.atTarget {
                stuck.append(MeetingFile(role: rename.role, path: rename.to, identity: rename.identity, owned: true, state: .present))
            }
        }
        return stuck
    }

    /// Whether the file `rename` names is at its target or at its source, by its
    /// identity, in the folder the path names.
    private static func whereRenameIs(_ rename: Rename) -> (atTarget: Bool, atSource: Bool) {
        func holds(_ path: String) -> Bool {
            MeetingFileRemover.isTheRecordedFile(
                MeetingFile(role: rename.role, path: path, identity: rename.identity, owned: true, state: .present),
            )
        }
        return (holds(rename.to), holds(rename.from))
    }

    /// Nil when the file `rename` names moved from `source` to `destination`; else
    /// why not: it is no longer that file, or the destination is taken.
    private static func move(_ rename: Rename, from source: String, to destination: String) -> String? {
        let file = MeetingFile(role: rename.role, path: source, identity: rename.identity, owned: true, state: .present)
        guard MeetingFileRemover.isTheRecordedFile(file) else { return "replaced" }
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else { return String(cString: strerror(errno)) }
        return nil
    }

    /// The commit point: one record update from the renames `marker` lists, with
    /// each file's identity read from the disk now. True only when it landed on a
    /// record that still carried the marker.
    private static func commitSwap(
        _ marker: MeetingFileRecord.RerunMarker, left: [MeetingFile], jobID: UUID, in store: MeetingFileStore,
    ) -> Bool {
        let renames = marker.renames ?? []
        let current = renames.filter { !$0.earlier }.map { MeetingFile(role: $0.role, url: URL(filePath: $0.to), owned: true) }
        let earlier = renames.filter(\.earlier).map { rename in
            MeetingFile(role: .previousProtocol, url: URL(filePath: rename.to), owned: true)
        }
        let madeNotes = marker.files.contains { $0.role == .protocol && $0.state != .gone }
        let expectedBefore = if case let .finished(expected) = marker.outcomeBefore { expected } else { false }
        var committed = false
        let saved = store.update(jobID: jobID) { record in
            committed = record.commitRerun(
                marker, current: current, kept: earlier + left, protocolExpected: madeNotes || expectedBefore,
            )
        }
        return saved && committed
    }

    /// Removes the re-run's files the swap does not rename, marked gone on the job
    /// and in the record, and returns those that stayed, which the commit keeps
    /// listed so a deletion of the meeting finds them.
    private func removeOtherRerunFiles(of marker: MeetingFileRecord.RerunMarker, jobID: UUID) -> [MeetingFile] {
        let others = marker.files.filter { !Self.swappedRoles.contains($0.role) && $0.state != .gone }
        let left = Self.removeRerunFiles(others, jobID: jobID)
        let removed = Set(others.map(\.path)).subtracting(left.map(\.path))
        guard !removed.isEmpty else { return left }
        if let index = jobs.firstIndex(where: { $0.id == jobID }) { jobs[index].markRerunFilesGone(paths: removed) }
        meetingFileStore?.update(jobID: jobID) { $0.rerun?.markGone(paths: removed) }
        return left
    }
}
