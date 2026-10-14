import Foundation

/// What a request to pause or resume the recording did.
enum RecordingPauseOutcome {
    /// The recording was paused, or resumed.
    case changed
    /// It already was: paused a second time, or resumed while it runs or
    /// while nothing records.
    case unchanged
    /// No recording's capture is running, so there is nothing to pause.
    case nothingToPause
}

/// The pauses of the recording in progress: when it was paused and resumed,
/// and when the loop saw its capture running, which a pause's position is
/// estimated from when the capture reports none. Made at every capture start
/// and taken at the stop, so every recording starts with an empty log.
struct RecordingPauseRecord {
    let startedAt: Date
    var log = RecordingPauseLog()
}

/// Pausing and resuming the recording in progress, split out of
/// `WatchLoop.swift` to keep that file under the line cap.
///
/// `pausedSince` is the one answer to "is the recording paused" for the menu,
/// the icon and the automation API. Only `pauseRecording()` sets it, and the
/// funnel clears it on every way out of `.recording`. The phase stays
/// `.recording` while paused, so whatever ends a recording ends a paused one
/// the same way: the meeting's end and its question, the app quitting, Stop,
/// Stop Watching, and the maximum length, which counts paused time too.
extension WatchLoop {
    var isPaused: Bool {
        pausedSince != nil
    }

    /// Whether a recording's capture is running. False for the moment a
    /// detected meeting is `.recording` before its recorder has started.
    var canPause: Bool {
        state == .recording && activeRecorder != nil
    }

    /// Pause the recording: nothing is captured until `resumeRecording()`.
    func pauseRecording() -> RecordingPauseOutcome {
        guard canPause, let recorder = activeRecorder else { return .nothingToPause }
        guard pausedSince == nil else { return .unchanged }
        let now = nowProvider()
        recorder.pause()
        _ = recordingPauses?.log.pause(at: now)
        update { next in
            next.pausedSince = now
            next.detail = "Paused: \(detailTitle)"
        }
        diagnostics.notice("recording_paused")
        return .changed
    }

    /// Resume the paused recording, which goes on as the same recording.
    func resumeRecording() -> RecordingPauseOutcome {
        guard pausedSince != nil else { return .unchanged }
        let now = nowProvider()
        activeRecorder?.resume()
        let pausedFor = recordingPauses?.log.resume(at: now) ?? 0
        silencePrompt.resumedSinceLastPoll = true
        update { next in
            next.pausedSince = nil
            next.detail = "Recording: \(detailTitle)"
        }
        diagnostics.notice("recording_resumed paused_s=\(Int(pausedFor.rounded()))")
        return .changed
    }

    /// The stopped recording's pauses for its job, a pause still open ending
    /// at `stop`, each at the position the capture measured for it. When the
    /// capture reported another number of positions than there were pauses,
    /// the positions are estimated from the wall clock and a warning says so.
    ///
    /// Taken straight after the recorder stops, before any cut: a cut that
    /// cannot put a track back returns a result without the capture's
    /// positions.
    func takeRecordingPauses(endingAt stop: Date, capturedOffsets: [TimeInterval]) -> [RecordingPause] {
        guard let record = recordingPauses else { return [] }
        recordingPauses = nil
        let pauses = record.log.pauses(endingAt: stop, recordingStartedAt: record.startedAt, capturedOffsets: capturedOffsets)
        if capturedOffsets.count != pauses.count {
            diagnostics.warning("recording_pause_offsets_fallback pauses=\(pauses.count) captured=\(capturedOffsets.count)")
        }
        return pauses
    }

    /// The title the status line shows while recording, as the two start
    /// paths put it there.
    private var detailTitle: String {
        manualRecordingInfo?.title ?? currentMeeting.map { Self.cleanTitle($0.windowTitle) } ?? ""
    }
}
