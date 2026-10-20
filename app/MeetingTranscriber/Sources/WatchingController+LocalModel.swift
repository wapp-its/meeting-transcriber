import Foundation

/// What the local model's gate is told about recordings (spec R5): one
/// recording-activity signal, composed here and nowhere else, pushed to the
/// gate whenever one of its inputs changes. The gate ends a running helper
/// when the signal turns on and admits nothing until it turns off; the
/// protocols a recording deferred then run again by themselves
/// (`PipelineQueue.generateWaitingOutRecordings`).
///
/// Pushed, not polled: every input changes on the main actor at a point this
/// controller already sees (`watchLoop` and `manualStartTask` are set here, the
/// loop reports each phase change to the state-change handler, and each
/// detected meeting's capture start and end to `onMeetingCapture`), so the
/// gate hears of a recording in the same turn it starts, and a recording
/// never waits for the model. Its own file because `WatchingController.swift`
/// sits at the line cap.
@MainActor
extension WatchingController {
    /// Whether a recording runs: from the start of any recording (a detected
    /// meeting, a manual one, a microphone-only one through `/v1/record`)
    /// until its recorder has stopped, paused included. A manual start counts
    /// from its registration, before its recorder is up, because it awaits the
    /// microphone gate first, and a manual stop stops the recorder before the
    /// loop leaves `.recording`. A detected meeting counts from the start of
    /// its capture until the recorder has stopped (`detectedCapturesRunning`),
    /// not by the loop's phase: Stop Watching wipes that phase at once, while
    /// the cancelled loop stops the recorder in a later turn.
    var isRecordingActivity: Bool {
        manualStartTask != nil || watchLoop?.state == .recording || detectedCapturesRunning > 0
    }

    /// Hooks a newly assigned loop's captures into the signal, then pushes it.
    /// The count of running captures lives on the controller rather than on the
    /// loop: Stop Watching drops the loop while its capture still finalizes,
    /// and a loop assigned meanwhile (Start Watching again) must not clear it.
    func watchLoopChanged() {
        watchLoop?.onMeetingCapture = { [weak self] capturing in
            self?.detectedCapturesRunning += capturing ? 1 : -1
            self?.recordingActivityChanged()
        }
        recordingActivityChanged()
    }

    /// Tells the gate whether to hold: while a recording runs, and in
    /// record-only mode, where this Mac makes no protocol (the copy Settings
    /// shows for it), so a local protocol due then waits in `.generatingProtocol`
    /// until record-only is off. Switching record-only on ends a running helper
    /// like a recording start does. Idempotent; the gate ignores a repeat.
    ///
    /// The permission check hears the same signal, without record-only: its
    /// probe opens the microphone, which must not happen under a recording.
    func recordingActivityChanged() {
        permissions.setRecordingActive(isRecordingActivity)
        #if !APPSTORE
            pipeline.localModelGate.setRecordingActive(isRecordingActivity || settings.recordOnly)
        #endif
    }

    /// Pushes the current state once and again on every record-only switch.
    /// Called once, from `init`. `withObservationTracking` fires once, so each
    /// firing re-arms.
    func holdLocalModelInRecordOnlyMode() {
        #if !APPSTORE
            recordingActivityChanged()
            withObservationTracking {
                _ = settings.recordOnly
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.holdLocalModelInRecordOnlyMode() }
            }
        #endif
    }
}
