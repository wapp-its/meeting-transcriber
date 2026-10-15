import Foundation

/// The job a stopped recording becomes, split out of `WatchLoop.swift` to keep
/// that file under the line cap. Reads nothing but its arguments.
extension WatchLoop {
    /// `protocolOptions` is nil for every start without the start dialog (the
    /// immediate menu item, `/v1/record`, a detected meeting): the queue then
    /// stamps the default template when it admits the job, and there is no
    /// background.
    static func pipelineJob(
        title: String,
        appName: String,
        recording: RecordingResult,
        pauses: [RecordingPause],
        protocolOptions: MeetingProtocolOptions?,
        participants: [String] = [],
    ) -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay,
            participants: participants,
            meetingStartTime: recording.recordingStartDate,
            pauses: pauses,
            protocolTemplate: protocolOptions?.template,
            protocolBackground: protocolOptions?.background,
        )
    }
}
