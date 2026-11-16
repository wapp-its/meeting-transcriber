import Foundation

/// A finished meeting's word timings (R7): its transcript segments file, kept
/// beside its raw transcript and listed in its record, and what Identify Speakers
/// Again reads from it in place of a transcription (R10).
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

    /// The segments an Identify Speakers Again run labels again: the meeting's
    /// current segments file, while it is the file its record names. Nil for any
    /// other run, and for a file gone, replaced, unreadable or empty, which the run
    /// then transcribes again.
    func keptWordTimings(for job: PipelineJob) -> [TimestampedSegment]? { // swiftlint:disable:this discouraged_optional_collection
        guard job.rerun?.mode == .identifySpeakersAgain,
              let file = meetingFileStore?.record(for: job.id)?.keptWordTimings,
              MeetingFileRemover.isTheRecordedFile(file),
              let data = try? Data(contentsOf: URL(filePath: file.path)),
              let segments = try? JSONDecoder().decode([TimestampedSegment].self, from: data),
              !segments.isEmpty
        else { return nil }
        return segments
    }

    /// A two-track meeting's kept segments with the microphone's tagged by this
    /// queue's label, which the labelling splits them by
    /// (`DiarizationProcess.labelSegments`): Settings' mic name may have changed
    /// since the meeting ran. Every segment not tagged as the call audio's is the
    /// microphone's, as the mic name never reads as the call audio's tag.
    func retaggedForThisQueue(_ segments: [TimestampedSegment]) -> [TimestampedSegment] {
        segments.map { segment in
            guard segment.speaker != DiarizationProcess.remoteSpeakerLabel else { return segment }
            var mic = segment
            mic.speaker = micLabel
            return mic
        }
    }
}

extension MeetingFileRecord {
    /// The meeting's word timings: its current segments file, nil when the record
    /// lists none or that one is gone.
    var keptWordTimings: MeetingFile? {
        files.last { $0.role == .segments }.flatMap { $0.state == .gone ? nil : $0 }
    }
}
