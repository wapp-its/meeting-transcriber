import Foundation

/// One finished job in `TerminalJobStore`: the status `GET /v1/jobs/<id>`
/// serves, plus what the Transcriptions window lists about the job.
///
/// Stored flat, every `JobStatusDTO` key next to the extra ones, never with the
/// status nested under a key of its own. The history file is read by builds on
/// either side of this type: an older build decodes it as `[JobStatusDTO]`,
/// whose synthesized decoder ignores keys it does not know, so a flat record
/// still reads as the status it carries, while a nested one would fail and
/// cost that build the whole history. In the other direction every extra
/// decodes as absent, so a file written before this type existed loads with
/// each record intact.
///
/// The extras stay off the wire: `TerminalJobStore.lookup(jobID:)` hands out
/// `status` alone, so participants and the rest never reach the automation API
/// through the history.
struct TerminalJobRecord: Codable, Equatable {
    let status: JobStatusDTO
    let appName: String?
    /// When the recording started; nil for imports and recovered jobs, which
    /// have no live recording, and for records written before this field.
    let meetingStartTime: Date?
    let enqueuedAt: Date?
    /// The recording's length in seconds, as stage 1 measured it. Nil when it
    /// was never measured.
    let audioDuration: TimeInterval?
    let participants: [String]

    init(job: PipelineJob) {
        status = JobStatusDTO(job: job)
        appName = job.appName
        meetingStartTime = job.meetingStartTime
        enqueuedAt = job.enqueuedAt
        audioDuration = job.audioDuration
        participants = job.participants
    }

    /// A record that knows only the status, as every record written before
    /// this type did.
    init(status: JobStatusDTO) {
        self.status = status
        appName = nil
        meetingStartTime = nil
        enqueuedAt = nil
        audioDuration = nil
        participants = []
    }

    private enum CodingKeys: String, CodingKey {
        case appName, meetingStartTime, enqueuedAt, audioDuration, participants
    }

    init(from decoder: any Decoder) throws {
        status = try JobStatusDTO(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        meetingStartTime = try container.decodeIfPresent(Date.self, forKey: .meetingStartTime)
        enqueuedAt = try container.decodeIfPresent(Date.self, forKey: .enqueuedAt)
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration)
        participants = try container.decodeIfPresent([String].self, forKey: .participants) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        try status.encode(to: encoder) // flattens the status fields into this object
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(meetingStartTime, forKey: .meetingStartTime)
        try container.encodeIfPresent(enqueuedAt, forKey: .enqueuedAt)
        try container.encodeIfPresent(audioDuration, forKey: .audioDuration)
        if !participants.isEmpty {
            try container.encode(participants, forKey: .participants)
        }
    }
}
