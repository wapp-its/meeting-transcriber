import AudioTapLib
import Foundation
import Observation

// MARK: - MicrophoneController

/// The one owner of "which microphone" state in the app.
///
/// `WatchingController` attaches it to each recording, and detaches it, on the
/// same state transitions that start and stop channel-health monitoring. While
/// attached it does two things:
/// - It hands a changed `AppSettings.micDeviceUID` to the running recording, so
///   a choice made in Settings → Audio or in the menu applies at once rather
///   than from the next recording. The recorder moves only its microphone
///   capture, through the capture library's device-change restart path, which
///   also ignores a repeat of the current choice. A choice made while nothing
///   is attached needs no hand-off: `WatchLoop` reads the setting at every
///   recording start.
/// - It publishes `recordedDevice`, the device the recording reports it
///   captures from, refreshed once a second from a value the capture layer
///   keeps, so no tick reads the hardware.
///
/// The recorder arrives through a provider, not as a value: a detected
/// meeting's `.recording` transition fires before `WatchLoop` assigns
/// `activeRecorder`, so a provider that returns nil at first is normal, and
/// the next tick or change picks the recorder up.
@Observable
@MainActor
final class MicrophoneController {
    /// The recording the controller is attached to. One value, so a stop
    /// clears all of it at once.
    struct Attachment {
        let source: RecordingSource
        /// The meeting app's name, or the manual recording's label.
        let meetingAppName: String?
        let recorderProvider: @MainActor () -> (any RecordingProvider)?
    }

    /// The microphone the attached recording reports it captures from. Nil
    /// while detached, until the recorder exists, and for a recording without
    /// a microphone capture.
    private(set) var recordedDevice: MicInputDevice?

    private(set) var attachment: Attachment?

    private let settings: AppSettings

    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        observeMicrophoneChoice()
    }

    /// Attach to a recording that has just started, and start the once-a-second
    /// tick. A second call while attached replaces the attachment and keeps the
    /// one tick loop.
    func recordingStarted(
        source: RecordingSource,
        meetingAppName: String?,
        recorderProvider: @escaping @MainActor () -> (any RecordingProvider)?,
    ) {
        attachment = Attachment(source: source, meetingAppName: meetingAppName, recorderProvider: recorderProvider)
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Detach: end the tick loop and forget the recording and its device.
    func recordingStopped() {
        tickTask?.cancel()
        tickTask = nil
        attachment = nil
        recordedDevice = nil
    }

    /// Publish the attached recorder's device. Assigns only on a change, since
    /// every assignment of an observed property notifies its observers.
    func tick() {
        guard let attachment else { return }
        let device = attachment.recorderProvider()?.micInputDevice
        if recordedDevice != device { recordedDevice = device }
    }

    private func applyMicrophoneChoice() {
        guard let attachment, attachment.source.capturesMicrophone else { return }
        let uid = settings.micDeviceUID
        attachment.recorderProvider()?.selectMicrophone(deviceUID: uid.isEmpty ? nil : uid)
    }

    /// `withObservationTracking` is one-shot, so this re-arms after each fire,
    /// the same shape as `EngineController.observeEngineSettings`. `onChange`
    /// runs before the new value is stored, so the value is read in the
    /// main-actor hop, never in `onChange` itself.
    private func observeMicrophoneChoice() {
        withObservationTracking {
            _ = settings.micDeviceUID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyMicrophoneChoice()
                self.observeMicrophoneChoice()
            }
        }
    }
}
