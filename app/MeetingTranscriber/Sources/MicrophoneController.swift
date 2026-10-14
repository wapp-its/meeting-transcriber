import AudioTapLib
import AVFoundation
import CoreAudio
import Foundation
import Observation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MicrophoneController")

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
/// - It probes, every five seconds, which input devices the tapped meeting app
///   uses, logs it, and warns once when the app can tell that the meeting app
///   records from another microphone (`MicrophoneController+MeetingProbe.swift`).
///
/// Attached or not, it also holds the microphone list and the default input's
/// name that the menu bar's Microphone entry shows.
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

    /// The microphones Settings → Audio → Microphone lists, in its order.
    private(set) var devices: [MicrophoneDevice] = []

    /// The macOS default input's name, which "System Default" records.
    private(set) var defaultInputName: String?

    /// `<App> uses <devices>` while the latest meeting-app probe found the
    /// meeting app on another microphone (`MicrophoneController+MeetingProbe.swift`).
    var meetingAppHint: String?

    let settings: AppSettings
    let notifier: any AppNotifying
    let log: any DiagnosticsLogging
    let probeReader: @Sendable ([pid_t]) -> [MeetingInputProcess]
    /// Where the probe's Core Audio reads run, never the main queue.
    let probeQueue = DispatchQueue(label: "com.meetingtranscriber.meeting-microphone-probe", qos: .utility)
    @ObservationIgnored var meetingProbe = MeetingProbeState()
    private let listDevices: () -> [MicrophoneDevice]
    private let readDefaultInputName: () -> String?

    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        notifier: any AppNotifying = SilentNotifier(),
        log: any DiagnosticsLogging = OSLogDiagnostics(category: "MeetingMicrophone"),
        probeReader: @escaping @Sendable ([pid_t]) -> [MeetingInputProcess] = { MeetingMicrophoneProbe.read(pids: $0) },
        listDevices: @escaping () -> [MicrophoneDevice] = MicrophoneDevices.available,
        readDefaultInputName: @escaping () -> String? = MicrophoneDevices.systemDefaultInputName,
        notificationCenter: NotificationCenter = .default,
    ) {
        self.settings = settings
        self.notifier = notifier
        self.log = log
        self.probeReader = probeReader
        self.listDevices = listDevices
        self.readDefaultInputName = readDefaultInputName
        observeMicrophoneChoice()
        refreshDevices()
        observeDeviceChanges(notificationCenter)
    }

    /// Attach to a recording that has just started, and start the once-a-second
    /// tick. A second call while attached replaces the attachment and keeps the
    /// one tick loop.
    func recordingStarted(
        source: RecordingSource,
        meetingAppName: String?,
        recorderProvider: @escaping @MainActor () -> (any RecordingProvider)?,
    ) {
        refreshDevices()
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

    /// Detach: end the tick loop and forget the recording, its device and its
    /// meeting-app probe.
    func recordingStopped() {
        tickTask?.cancel()
        tickTask = nil
        attachment = nil
        recordedDevice = nil
        endMeetingProbe()
    }

    /// Publish the attached recorder's device, and probe the meeting app's
    /// microphone when it is due. Assigns only on a change, since every
    /// assignment of an observed property notifies its observers.
    func tick() {
        guard let attachment else { return }
        let recorder = attachment.recorderProvider()
        let device = recorder?.micInputDevice
        if recordedDevice != device { recordedDevice = device }
        probeMeetingMicrophoneIfDue(recorder)
    }

    /// Read the device list and the default input's name again. Assigns only
    /// on a change, like `tick()`.
    func refreshDevices() {
        let list = listDevices()
        if devices != list { devices = list }
        let name = readDefaultInputName()
        if defaultInputName != name { defaultInputName = name }
    }

    private func applyMicrophoneChoice() {
        guard let attachment, attachment.source.capturesMicrophone else { return }
        let uid = settings.micDeviceUID
        attachment.recorderProvider()?.selectMicrophone(deviceUID: uid.isEmpty ? nil : uid)
    }

    /// Refresh the list when a device connects or disconnects and when the
    /// macOS default input changes, on the main queue. The controller lives as
    /// long as the app (`AppState.microphone`), so nothing is ever removed.
    private func observeDeviceChanges(_ center: NotificationCenter) {
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            // swiftlint:disable:next discarded_notification_center_observer
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main,
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        if status != noErr {
            logger.warning("Default input listener not installed (status: \(status))")
        }
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
