import AudioTapLib
import Foundation

extension MeetingFileRecord {
    /// What running the meeting again takes from its first run, beyond the
    /// title, app, start time and participants its finished-job entry keeps:
    /// these live only on the queued job, which is gone once it leaves the queue.
    ///
    /// It holds the background the user wrote, as the queue's snapshot does;
    /// both files are owner-only.
    struct RunInputs: Codable, Equatable, Sendable {
        var micDelay: TimeInterval = 0
        var pauses: [RecordingPause] = []
        /// On the mic track's timeline, as `PipelineJob.micMuteIntervals`.
        var micMuteIntervals: [MicMuteInterval] = []
        /// Nil lets the admission of the run pick by the title, as for a new job.
        var protocolTemplate: ProtocolTemplateID?
        var protocolBackground: String?
        /// The database the page was made in, as the export normalized it.
        var notionDatabaseID: String?
        var notionPageID: String?
    }

    /// What a re-run of the meeting starts from: the inputs the record kept,
    /// else none of them (no mic delay, no pauses, no mute spans, no template,
    /// so the rules pick one by the title, no background), and without a kept
    /// page the Notion page `finished` names, in no known database. The page
    /// and its database are kept together (`PipelineJob.recordNotionPage`).
    func rerunInputs(finished: TerminalJobRecord) -> RunInputs {
        var inputs = runInputs ?? RunInputs()
        if inputs.notionPageID == nil {
            inputs.notionPageID = finished.status.export?.id
        }
        return inputs
    }
}

extension MeetingFileRecord.RunInputs {
    init(job: PipelineJob) {
        self.init(
            micDelay: job.micDelay,
            pauses: job.pauses ?? [],
            micMuteIntervals: job.micMuteIntervals ?? [],
            protocolTemplate: job.protocolTemplate,
            protocolBackground: job.protocolBackground,
            notionDatabaseID: job.notionDatabaseID,
            notionPageID: job.notionPageID,
        )
    }

    /// Each input may be missing, like the record's own later fields, so none
    /// can make the record file unreadable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            micDelay: container.decodeIfPresent(TimeInterval.self, forKey: .micDelay) ?? 0,
            pauses: container.decodeIfPresent([RecordingPause].self, forKey: .pauses) ?? [],
            micMuteIntervals: container.decodeIfPresent([MicMuteInterval].self, forKey: .micMuteIntervals) ?? [],
            protocolTemplate: container.decodeIfPresent(ProtocolTemplateID.self, forKey: .protocolTemplate),
            protocolBackground: container.decodeIfPresent(String.self, forKey: .protocolBackground),
            notionDatabaseID: container.decodeIfPresent(String.self, forKey: .notionDatabaseID),
            notionPageID: container.decodeIfPresent(String.self, forKey: .notionPageID),
        )
    }
}
