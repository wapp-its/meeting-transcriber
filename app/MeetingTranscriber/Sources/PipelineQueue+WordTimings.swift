import Foundation

/// A finished meeting's word timings (R7): its transcript segments file, kept
/// beside its raw transcript and listed in its record.
extension PipelineQueue {
    /// Whether `job`'s transcript segments file stays when its naming files go:
    /// for a meeting whose record lists it, so Move Meeting to Trash finds it, and
    /// whose raw transcript is kept separately. With that option off it goes when
    /// the speakers are named, as before.
    func keepsWordTimings(of job: PipelineJob) -> Bool {
        meetingFileStore?.record(for: job.id) != nil && transcriptOutputOptions(of: job).saveRawTranscriptSeparately
    }

    func keepsWordTimings(jobID: UUID) -> Bool {
        job(withID: jobID).map(keepsWordTimings(of:)) ?? false
    }
}
