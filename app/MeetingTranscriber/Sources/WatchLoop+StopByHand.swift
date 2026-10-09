import Foundation

/// "Stop Recording" for a detected meeting's recording, split out of
/// `WatchLoop.swift` to keep that file under the line cap.
///
/// The request is parked rather than acted on here. The recording belongs to
/// `handleMeeting`, which is waiting in `waitForMeetingEnd`, and that wait takes
/// the request at its next poll and ends there, so a stop by hand goes through
/// the same stop, cut and enqueue as every other meeting end. `handleMeeting`
/// drops a request it did not use when it returns, so one made for a recording
/// whose capture then failed to start never ends a later recording.
extension WatchLoop {
    /// Ask the recording of the detected meeting to end at the wait's next
    /// poll, and say whether it was accepted. Refused unless a detected
    /// meeting is recording: a manual recording stops through
    /// `stopManualRecording()`. Asked again before that poll, the first
    /// request's time stands, since a "Keep recording" answer counts only
    /// when it came before the stop.
    @discardableResult
    func stopDetectedRecording() -> Bool {
        guard state == .recording, manualRecordingInfo == nil, currentMeeting != nil else { return false }
        if stopByHandRequestedAt == nil {
            stopByHandRequestedAt = nowProvider()
        }
        return true
    }

    /// Take the parked request's time, clearing it.
    func takeStopByHandRequest() -> Date? {
        defer { stopByHandRequestedAt = nil }
        return stopByHandRequestedAt
    }
}
