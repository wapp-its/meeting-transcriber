import Foundation

/// Pausing and resuming the running recording: the one entry point the menu's
/// Pause/Resume item and `POST /v1/record` share.
///
/// Split out of `WatchingController.swift` to keep that file under the line
/// cap. Unlike the record verbs, these act on whichever recording runs, a
/// detected meeting included: pausing one ends nothing and starts nothing, so
/// there is no recording of somebody else's to protect.
///
/// The live captions are left alone. Their flush retires both caption feeds,
/// and only the next recording's preparation binds new ones, so flushing here
/// would end the captions for the rest of the recording; the paused capture
/// simply hands them nothing.
@MainActor
extension WatchingController {
    /// Whether the running recording is paused.
    var isRecordingPaused: Bool {
        watchLoop?.isPaused == true
    }

    /// Whether a recording's capture is running, so it can be paused. False
    /// for the moment a detected meeting records before its recorder is up.
    var canPauseRecording: Bool {
        watchLoop?.canPause == true
    }

    func pauseRecording() -> RecordingPauseOutcome {
        watchLoop?.pauseRecording() ?? .nothingToPause
    }

    func resumeRecording() -> RecordingPauseOutcome {
        watchLoop?.resumeRecording() ?? .unchanged
    }

    /// The menu's item: resume a paused recording, pause a running one.
    func togglePause() {
        _ = isRecordingPaused ? resumeRecording() : pauseRecording()
    }
}
