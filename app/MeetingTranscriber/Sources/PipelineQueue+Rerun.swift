import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// What a re-run of a finished meeting runs again.
enum RerunMode: String, Codable, Sendable {
    /// The whole processing, with the current settings.
    case transcribeAgain = "transcribe_again"
}

/// What `PipelineQueue.rerunJob(id:mode:)` did.
enum RerunAdmission: Equatable {
    case queued
    case refused(RerunRefusal)
}

/// Why a re-run was not admitted. None of them changed anything.
enum RerunRefusal: Error, Equatable, Sendable {
    /// No finished entry or record of the meeting, or its record has not finished.
    case notFinished
    /// A deletion of the meeting is pending or incomplete.
    case deletionPending
    /// A re-run of the meeting is under way, in this build or another.
    case alreadyRerunning
    /// A job of the meeting waits, runs, waits for names or exports.
    case meetingBusy
    /// Another run holds the meeting's audio.
    case audioHeldElsewhere
    /// None of the meeting's source audio is there any more.
    case audioGone
    /// The meeting's source audio is on a drive that is not connected.
    case audioUnreachable
    /// The record could not be written, or changed while the admission read it.
    case recordNotSaved
}

extension PipelineJob {
    /// What a re-run job carries beside its marker.
    struct Rerun: Codable, Sendable {
        let mode: RerunMode
        /// The same marker the meeting's record carries.
        var marker: MeetingFileRecord.RerunMarker
        let settings: RerunSettings
        /// The finished job of the meeting the re-run took over in the queue, as it
        /// was; nil when the meeting had left the queue.
        let heldEntry: HeldEntry?
    }

    /// The settings a queue captures when it is built, as Settings named them when
    /// the re-run was admitted: the re-run runs with what its sheet showed.
    struct RerunSettings: Codable, Equatable, Sendable {
        /// Nil keeps the queue's engine (a queue built without Settings).
        let engine: TranscriptionEngineSetting?
        let diarize: Bool
        let numSpeakers: Int
        /// Nil with voice activity detection off.
        let vadThreshold: Float?
    }

    /// A finished job kept whole, so every end of the re-run but success can put it
    /// back with its export state and its notes failure. Indirect, as a job holds it.
    indirect enum HeldEntry: Codable, Sendable {
        case job(PipelineJob)
    }
}

/// Running a finished meeting again from its own audio, under file names of its
/// own: the meeting stays one meeting (its id, row, record and finished entry), and
/// its current files stay as they are while the re-run runs.
extension PipelineQueue {
    /// Queue a re-run of the finished meeting `id`, rebuilt from its finished entry
    /// and its record, at the end of the queue like an import. A finished job of the
    /// meeting still in the queue (in its last minute, or held by a failed export or
    /// failed notes) is taken over: its removal is cancelled and it is kept whole in
    /// the marker. Unlike Retry, the finished entry stays as it is.
    ///
    /// Refused, with nothing changed, for a meeting whose record has not finished,
    /// has a deletion pending or incomplete or carries a re-run already (also one
    /// another build wrote: the record is read under its lock), a job of the meeting
    /// that is not settled, audio another run holds, and audio gone or out of reach.
    @discardableResult
    func rerunJob(id: UUID, mode: RerunMode) -> RerunAdmission {
        let live = job(withID: id)
        if let live, !isSettled(live) { return .refused(.meetingBusy) }
        guard let meetingFileStore,
              let finished = terminalJobStore?.records.last(where: { $0.status.jobID == id.uuidString })
        else { return .refused(.notFinished) }
        meetingFileStore.reload()
        guard let record = meetingFileStore.record(for: id) else { return .refused(.notFinished) }
        if let refusal = record.rerunRefusal { return .refused(refusal) }
        let audio: RelocatedAudioPaths
        switch Self.rerunAudio(from: record.rerunSourceTracks) {
        case let .success(found): audio = found
        case let .failure(refusal): return .refused(refusal)
        }
        let marker = MeetingFileRecord.RerunMarker(
            stamp: Date(), outcomeBefore: record.outcome, bundleID: meetingFileStore.bundleID,
            process: .current, runID: UUID(),
        )
        let settings = currentRerunSettings()
        // Resolved while Settings names it, so the stages find this instance later.
        if let kind = settings.engine { _ = engineForKind?(kind) }
        var job = PipelineJob(
            rerunOf: finished, id: id, audio: audio, inputs: record.rerunInputs(finished: finished),
            rerun: .init(mode: mode, marker: marker, settings: settings, heldEntry: live.map { .job($0) }),
        )
        stampTranscriptOutputOptions(on: &job)
        guard !audioIsHeldElsewhere(for: job) else { return .refused(.audioHeldElsewhere) }
        if let refusal = meetingFileStore.beginRerun(marker, unchangedFrom: record) { return .refused(refusal) }
        admit(job, tookOver: live != nil)
        return .queued
    }

    /// A finished job no export runs for: one waiting, running, waiting for names
    /// or exporting is not, a notes retry waiting or running included.
    private func isSettled(_ job: PipelineJob) -> Bool {
        job.state == .done && job.notionExportStatus != .inProgress && notionExportTasks[job.id] == nil
    }

    /// The audio a re-run reads: the listed tracks that are there. A recorded call
    /// keeps its two tracks while it has both; without one of them it runs on the
    /// mix, or on the one track left. Refused while any listed track is out of
    /// reach, since running without it would quietly change the result until its
    /// drive is back, and when none is there.
    private static func rerunAudio(from listed: RelocatedAudioPaths) -> Result<RelocatedAudioPaths, RerunRefusal> {
        let tracks = [listed.mix, listed.app, listed.mic].map { url in
            url.map { (url: $0, presence: MeetingFilePresence.of($0.path)) }
        }
        let presences = tracks.compactMap { $0?.presence }
        if presences.contains(.unreachable) { return .failure(.audioUnreachable) }
        let present = tracks.map { $0?.presence == .present ? $0?.url : nil }
        if let app = present[1], let mic = present[2] {
            return .success(RelocatedAudioPaths(mix: present[0], app: app, mic: mic))
        }
        guard let first = present.compactMap(\.self).first else { return .failure(.audioGone) }
        return .success(RelocatedAudioPaths(mix: first, app: nil, mic: nil))
    }

    private func currentRerunSettings() -> PipelineJob.RerunSettings {
        rerunSettingsProvider?() ?? .init(
            engine: nil, diarize: diarizeEnabled, numSpeakers: numSpeakers, vadThreshold: vadConfig?.threshold,
        )
    }

    /// The re-run joins the end of the queue (A14), so a finished job it takes over
    /// leaves its place without what removing a job does: it lives on in the marker.
    /// What a run left keyed on the id goes, as for Retry; the meeting's files stay.
    private func admit(_ job: PipelineJob, tookOver: Bool) {
        if tookOver {
            completedJobRemovalTokens.removeValue(forKey: job.id)
            jobs.removeAll { $0.id == job.id }
        }
        jobAudioSeconds.removeValue(forKey: job.id)
        protocolResumeDispositions.removeValue(forKey: job.id)
        jobs.append(job)
        eventLog.append(jobID: job.id, event: "rerun_admitted", from: tookOver ? .done : nil, to: .waiting)
        saveSnapshot()
        logger.info("[\(job.shortID, privacy: .public)] rerun_admitted took_over=\(tookOver, privacy: .public)")
        triggerProcessing()
    }

    // MARK: - What the stages read

    func isRerun(_ jobID: UUID) -> Bool {
        job(withID: jobID)?.rerun != nil
    }

    /// The stem every file of `job`'s run carries: the meeting's, and for a re-run
    /// with its stamp (`MeetingFileRecord.RerunMarker.stem(base:)`).
    static func runStem(for job: PipelineJob) -> String {
        let base = namingSlug(title: job.meetingTitle, jobID: job.id, startTime: job.artifactStartTime)
        return job.rerun.map { $0.marker.stem(base: base) } ?? base
    }

    /// The engine `job` transcribes with: for a re-run the kind Settings named at
    /// its admission, else this queue's.
    func stageEngine(for job: PipelineJob) -> (any TranscribingEngine)? {
        job.rerun?.settings.engine.flatMap { engineForKind?($0) } ?? engine
    }

    func diarizes(_ jobID: UUID) -> Bool {
        job(withID: jobID)?.rerun?.settings.diarize ?? diarizeEnabled
    }

    func expectedSpeakers(_ jobID: UUID) -> Int {
        job(withID: jobID)?.rerun?.settings.numSpeakers ?? numSpeakers
    }

    /// Nil runs no voice activity detection.
    func vadThreshold(_ jobID: UUID) -> Float? {
        guard let settings = job(withID: jobID)?.rerun?.settings else { return vadConfig?.threshold }
        return settings.vadThreshold
    }

    /// The id a job's local notes go through the gate under: a re-run's run id,
    /// so a cancel of the re-run never refuses the meeting's own id.
    func gateJobID(for jobID: UUID) -> UUID {
        job(withID: jobID)?.rerun?.marker.runID ?? jobID
    }

    // MARK: - The re-run's files

    /// A re-run's files go into its marker, on the job and in the record, never
    /// among the meeting's files, which stay the current ones until it succeeds.
    /// False for a job that is no re-run.
    func noteRerunWritten(jobID: UUID, _ files: [MeetingFile]) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].rerun != nil else { return false }
        for file in files {
            jobs[index].noteRerunFile(file)
        }
        meetingFileStore?.update(jobID: jobID) { record in
            for file in files {
                record.rerun?.list(file)
            }
        }
        return true
    }

    /// The marker's files in `roles` the disk answers are gone, marked so. False for
    /// a job that is no re-run. The probe runs before the record's lock is taken.
    func noteRerunFilesGone(jobID: UUID, roles: Set<MeetingFile.Role>) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), let marker = jobs[index].rerun?.marker else { return false }
        let gone = Set(marker.files.filter { file in
            roles.contains(file.role) && file.state != .gone && MeetingFilePresence.of(file.path) == .gone
        }.map(\.path))
        guard !gone.isEmpty else { return true }
        jobs[index].markRerunFilesGone(paths: gone)
        meetingFileStore?.update(jobID: jobID) { $0.rerun?.markGone(paths: gone) }
        return true
    }

    /// The re-run's speakers are confirmed or skipped and its notes are saved or
    /// not wanted: its files still there go to the success hook.
    func rerunSucceeded(id: UUID) {
        guard let job = job(withID: id), let marker = job.rerun?.marker else { return }
        logger.info("[\(job.shortID, privacy: .public)] rerun_succeeded files=\(marker.files.count, privacy: .public)")
        onRerunSucceeded?(job, marker.files.filter { $0.state != .gone })
    }
}
