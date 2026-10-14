import Foundation

/// The controllers that watch a recording while it runs: channel health, the
/// microphone and the sound output. Attached on the `.recording` transition and
/// detached on the one that ends the recording, from `attachStateChangeHandler`.
extension WatchingController {
    /// The recorder arrives through a provider: a detected meeting's
    /// `.recording` transition fires before `WatchLoop` assigns
    /// `activeRecorder`, so a provider that returns nil at first is normal.
    func attachRecordingObservers(source: RecordingSource, meetingAppName: String?) {
        channelHealth.start(source: source) { [weak self] in
            self?.watchLoop?.activeRecorder
        }
        microphone?.recordingStarted(source: source, meetingAppName: meetingAppName) { [weak self] in
            self?.watchLoop?.activeRecorder
        }
        output?.recordingStarted(source: source)
    }

    func detachRecordingObservers() {
        channelHealth.stop()
        microphone?.recordingStopped()
        output?.recordingStopped()
    }
}
