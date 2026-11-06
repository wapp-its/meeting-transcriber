// The parts of a quit that `WatchLoop` answers for and that do not need its
// private state: where a recording the quit stopped goes, and what a stop that
// recorded nothing means while quitting. `finishForQuit` stays in
// `WatchLoop.swift`, next to the watch task it waits for.
import Foundation

extension WatchLoop {
    /// Stop and enqueue a manual recording a quit is finishing, with the file
    /// work off the main actor: the mix (`stopOffMain`) and, in record-only
    /// mode, the move into the output folder (`writeRecordOnlyOffMain`). The
    /// quit's budget is a timer on the main actor and needs the thread free;
    /// ending the capture session is the part that stays on it. Never cut: a
    /// quit is not an answer to the silence question. A detected meeting's
    /// recording takes `finishMeetingRecording`, which also applies a cut.
    func stopAndEnqueueForQuit(
        _ recorder: any RecordingProvider,
        title: String,
        appName: String,
        trigger: RecordingSidecar.Trigger,
        participants: [String] = [],
        protocolOptions: MeetingProtocolOptions? = nil,
    ) async throws {
        endSilencePrompt()
        let stoppedAt = nowProvider()
        let recording = try await recorder.stopOffMain()
        let pauses = takeRecordingPauses(endingAt: stoppedAt, capturedOffsets: recording.pauseOffsets)
        if recordOnly() {
            await writeRecordOnlyOffMain(
                title: title, appName: appName, recording: recording, trigger: trigger, pauses: pauses,
                participants: participants,
            )
        } else {
            enqueueRecording(
                title: title, appName: appName, recording: recording, trigger: trigger, pauses: pauses,
                participants: participants, protocolOptions: protocolOptions,
            )
        }
    }

    /// During a quit, a recording that ended before it captured anything is
    /// nothing recorded, not a failure to report in the middle of quitting.
    func isNothingRecordedAtQuit(_ error: any Error) -> Bool {
        guard finishingForQuit, case .noAudioData? = error as? RecorderError else { return false }
        return true
    }
}
