import Foundation

// Speaker naming for the automation API (`/v1/jobs/<id>/naming`). Split out of
// `PipelineController.swift` to keep that file under the `file_length` limit;
// no behavioural difference from declaring these inline.
extension PipelineController {
    /// Naming data for a job that is *actually* awaiting resolution — both in
    /// `.speakerNamingPending` state and with stashed data. Guarding on the
    /// state (not just the dict) makes confirm/skip idempotent: confirming
    /// transitions the job out of `.speakerNamingPending` synchronously, so a
    /// duplicate call (e.g. an automation retry) is rejected before it can
    /// double-record recognition or spawn a second re-apply.
    private func pendingNamingData(forID id: UUID) -> PipelineQueue.SpeakerNamingData? {
        guard queue.jobs.first(where: { $0.id == id })?.state == .speakerNamingPending else { return nil }
        return queue.speakerNamingDataByJob[id]
    }

    /// The speaker-naming choice awaiting resolution for a job, or nil when the
    /// job has no naming pending (unknown ID → the RPC layer 404s). Excludes
    /// embeddings.
    func namingStatus(forID id: UUID) -> NamingStatusDTO? {
        guard let data = pendingNamingData(forID: id) else { return nil }
        let speakers = data.mapping.keys.sorted().map { label in
            NamingStatusDTO.Speaker(
                label: label,
                suggested: data.mapping[label] ?? label,
                speakingSeconds: data.speakingTimes[label] ?? 0,
            )
        }
        return NamingStatusDTO(
            jobID: id.uuidString, meetingTitle: data.meetingTitle,
            speakers: speakers, participants: data.participants,
        )
    }

    /// Confirm speaker names for a pending job. Returns false when the job has no
    /// naming awaiting resolution (→ the RPC layer 404s); idempotent on retry.
    @discardableResult
    func confirmNaming(jobID: UUID, mapping: [String: String]) -> Bool {
        resolveNaming(jobID: jobID, result: .confirmed(mapping))
    }

    /// Skip speaker naming for a single pending job (accept the auto-names).
    /// Returns false when the job has no naming awaiting resolution.
    @discardableResult
    func skipNaming(jobID: UUID) -> Bool {
        resolveNaming(jobID: jobID, result: .skipped)
    }

    /// Shared guard + dispatch for confirm/skip: act only on a job actually
    /// awaiting naming, returning whether it did (false → 404).
    private func resolveNaming(jobID: UUID, result: PipelineQueue.SpeakerNamingResult) -> Bool {
        // Tagged `.rpc`: nobody was looking at a dialog, so a row from here must
        // not read as a human decision in the recognition log. Whether the job
        // was awaiting naming is the session's answer, so a refused answer can
        // never read as taken.
        queue.completeSpeakerNaming(jobID: jobID, result: result, source: .rpc) == nil
    }
}
