import Foundation

/// Retrying a failed job, split out of `PipelineQueue+Recovery.swift` to keep
/// that file under the `file_length` limit. Pure move; no behavior change.
extension PipelineQueue {
    /// Run a failed job again from its audio. Returns false, and changes
    /// nothing, unless `canRetryJob` holds.
    ///
    /// A failed job stays listed, and in the snapshot, until it is dismissed,
    /// but nothing used to run it again: the only way back was finding the
    /// staged audio and importing it by hand. That matters most when the
    /// failure was the app's, fixed in a later version, since the restored job
    /// then fails for a reason that no longer exists.
    ///
    /// By hand on purpose, not automatic. Most failures are deterministic (a
    /// silent capture, audio the engine refuses), and re-running those on every
    /// launch would cost a full transcription and an error notification each
    /// time for nothing. The user can tell a transient failure from a
    /// permanent one; this code cannot.
    ///
    /// The job keeps its ID, so its snapshot entry and event-log history
    /// continue rather than forking. The processed ledger is not consulted: a
    /// retry is an explicit request, like a re-import.
    ///
    /// Refused for any job not in `.error`, and while another job here, or a
    /// run on another queue, still holds the same audio: two jobs for one
    /// recording would transcribe it twice and write two sets of outputs.
    ///
    /// Everything the failed run left keyed on this job goes first, since the
    /// retry reuses the ID and would otherwise inherit it:
    /// - the speaker-naming state (in-memory naming data, recognition stashes,
    ///   the sidecars on disk). Diarization parks it before stage 3 writes the
    ///   transcript, which can throw, and a retry that produced none of its own
    ///   would skip the protocol and park in the dialog with the old mapping;
    /// - the audio length the stage-timing stats charge to the job;
    /// - a protocol-only resume the restore marked and a failed full run left
    ///   behind, which would publish the failed run's undiarized draft;
    /// - the durable terminal record. The API answers from the live job while
    ///   there is one, and a retried job that is then cancelled leaves without
    ///   a new record, so the old error would be served for it again.
    @discardableResult
    func retryJob(id: UUID) -> Bool {
        guard canRetryJob(id: id), let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        guard Self.sourceAudioExists(for: jobs[index]) else {
            noteRetryAudioMissing(at: index)
            return false
        }
        naming.removeNamingData(
            jobID: id, slug: jobs[index].namingSlug, in: allSidecarDirs(of: jobs[index]),
        )
        jobAudioSeconds.removeValue(forKey: id)
        protocolResumeDispositions.removeValue(forKey: id)
        terminalJobStore?.remove(jobID: id)
        jobs[index].prepareForRetry()
        updateJobState(id: id, to: .waiting)
        triggerProcessing()
        return true
    }

    /// Whether the menu offers Retry for this job: a hint from the queue's
    /// state, never a file check. It stands for what the menu shows on every
    /// render, and the recording can sit on a network or removable volume,
    /// where a `fileExists` can block the main thread. `retryJob` looks at the
    /// file itself on every click, and one that finds it gone says so on the
    /// job. The offer stays, so a volume that comes back is retryable again.
    ///
    /// Decided live, never from the error text. A job refused because another
    /// run held its audio is a duplicate only while that run holds it: once the
    /// owner failed, was cancelled or was dismissed, nothing processes the
    /// recording any more and this job is the way back to it. An owner that
    /// finished keeps blocking for as long as it is listed, since retrying then
    /// would write the same meeting a second time.
    ///
    /// The job must name an audio file. After the owner moved the recording
    /// (stage 3 relocates a staged one into the output folder) the duplicate
    /// still names the staging path, so it is offered, and the click reports the
    /// file gone.
    func canRetryJob(id: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .error,
              Self.sourceAudio(for: job) != nil else { return false }
        return !audioIsHeldElsewhere(for: job)
    }

    private static let retryAudioMissingNote = "The recording is no longer there, so there is nothing to retry."

    /// The retry found nothing to run on. The menu shows an error job's error
    /// text, so the reason goes there, once; the failure it had stays in front.
    private func noteRetryAudioMissing(at index: Int) {
        let failure = jobs[index].error ?? ""
        guard !failure.hasSuffix(Self.retryAudioMissingNote) else { return }
        jobs[index].error = failure.isEmpty ? Self.retryAudioMissingNote : "\(failure) \(Self.retryAudioMissingNote)"
        saveSnapshot()
    }

    /// The file a run reads first: the mix, or for a paired import without
    /// one, the app track.
    private static func sourceAudio(for job: PipelineJob) -> URL? {
        job.mixPath ?? job.appPath
    }

    private static func sourceAudioExists(for job: PipelineJob) -> Bool {
        sourceAudio(for: job).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Whether a run is claimed for this job or its mix file on any queue, or
    /// another job in this one that has not failed holds the same mix file.
    /// Paired imports without a mix file are compared by the claim alone.
    /// A failed holder does not count: it processes nothing any more, and this
    /// job is the way back to the recording.
    private func audioIsHeldElsewhere(for job: PipelineJob) -> Bool {
        inFlightRuns.isInFlight(job) || otherJobHoldsAudio(of: job, in: \.mixPaths, includingFailed: false)
    }

    /// Whether a job of this queue other than `job` points at one of `job`'s
    /// audio files, as `files` names them. `includingFailed` counts a failed
    /// job too: it keeps its recording for Retry. The one rule behind
    /// `audioIsHeldElsewhere` (Retry) and the move of a cancelled job's
    /// recording; each says which files and which holders count.
    func otherJobHoldsAudio(
        of job: PipelineJob, in files: KeyPath<PipelineJob, [URL]>, includingFailed: Bool,
    ) -> Bool {
        let mine = Set(job[keyPath: files].map(\.standardizedFileURL.path))
        guard !mine.isEmpty else { return false }
        return jobs.contains { other in
            other.id != job.id && (includingFailed || other.state != .error)
                && other[keyPath: files].contains { mine.contains($0.standardizedFileURL.path) }
        }
    }
}
