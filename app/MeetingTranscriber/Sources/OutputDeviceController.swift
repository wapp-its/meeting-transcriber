import CoreAudio
import Foundation
import Observation

// MARK: - OutputDeviceController

/// The one owner of "which sound output" state in the app: the Mac's default
/// output and its list of outputs, which the menu bar's Output entry shows and
/// switches, and the routing warning for the recording in progress
/// (`OutputRoutingWarning`).
///
/// It reads the outputs at launch, whenever Core Audio reports a change of the
/// default output or of the device list, and when a recording starts. The
/// warning hangs off those same reads, not off the capture library: the
/// library's own listener rebuilds the tap on an output change, but it drops
/// changes while a restart is in flight or backing off, and the warning must
/// see every routing the recording lives through.
///
/// `WatchingController` attaches it to each recording, and detaches it, on the
/// same transitions as `MicrophoneController`; the attachment is what scopes
/// the warning and the icon flag to the recording's lifetime.
@Observable
@MainActor
final class OutputDeviceController {
    /// The outputs the Mac offers, in Core Audio's order.
    private(set) var devices: [OutputDevice] = []

    /// The Mac's default output; nil when Core Audio does not answer.
    private(set) var current: OutputDevice?

    /// True while an attached recording with an app track runs and the
    /// default output is the Teams loopback device.
    private(set) var routingWarningActive = false

    /// The recording attached to, nil while none runs.
    @ObservationIgnored private var attachedSource: RecordingSource?
    /// The attached recording's once-per-routing memory.
    @ObservationIgnored private var warnedForCurrentRouting = false

    private let notifier: any AppNotifying
    private let log: any DiagnosticsLogging
    private let indicatorEnabled: () -> Bool
    private let listDevices: () -> [OutputDevice]
    private let readDefault: () -> OutputDevice?
    private let setDefault: (String) -> OSStatus

    /// - Parameter observeChanges: installs the change handler; production
    ///   installs Core Audio listeners, a test keeps the handler to fire it.
    init(
        notifier: any AppNotifying = SilentNotifier(),
        log: any DiagnosticsLogging = OSLogDiagnostics(category: "OutputRouting"),
        indicatorEnabled: @escaping () -> Bool = { true },
        listDevices: @escaping () -> [OutputDevice] = OutputDevices.available,
        readDefault: @escaping () -> OutputDevice? = OutputDevices.systemDefault,
        setDefault: @escaping (String) -> OSStatus = OutputDevices.setSystemDefault(uid:),
        observeChanges: (@escaping @MainActor () -> Void) -> Void = OutputDevices.observeChanges,
    ) {
        self.notifier = notifier
        self.log = log
        self.indicatorEnabled = indicatorEnabled
        self.listDevices = listDevices
        self.readDefault = readDefault
        self.setDefault = setDefault
        refresh()
        observeChanges { [weak self] in self?.outputChanged() }
    }

    /// Red tint for the menu bar's **bottom** (app-audio) half while the
    /// routing warning holds, under the same per-channel indicator setting as a
    /// silent app channel.
    var appChannelOverlay: Bool {
        let active = routingWarningActive
        return indicatorEnabled() && active
    }

    /// Attach to a recording that has just started and judge the routing it
    /// starts on.
    func recordingStarted(source: RecordingSource) {
        attachedSource = source
        warnedForCurrentRouting = false
        refresh()
        evaluate(trigger: .start)
    }

    /// Detach: a change reported after this changes nothing but the menu.
    func recordingStopped() {
        attachedSource = nil
        warnedForCurrentRouting = false
        if routingWarningActive { routingWarningActive = false }
    }

    /// Make `uid` the Mac's default output. A refused change leaves the
    /// default as it was; the read-back below keeps the entry on the device
    /// that is actually current. An accepted one also arrives through the
    /// change listener, which judges the routing.
    func select(uid: String) {
        let status = setDefault(uid)
        if status != noErr {
            log.warning("Output device not set: status \(status)")
        }
        refresh()
    }

    /// Read the device list and the default output again. Assigns only on a
    /// change, since every assignment of an observed property notifies its
    /// observers.
    func refresh() {
        let list = listDevices()
        if devices != list { devices = list }
        let device = readDefault()
        if current != device { current = device }
    }

    private func outputChanged() {
        refresh()
        evaluate(trigger: .outputChange)
    }

    private func evaluate(trigger: OutputRoutingWarning.Trigger) {
        guard let source = attachedSource else { return }
        let uid = current?.uid
        let decision = OutputRoutingWarning.decide(
            uid: uid, capturesApp: source.capturesAppAudio, warnedForCurrentRouting: warnedForCurrentRouting,
        )
        warnedForCurrentRouting = decision.warnedForCurrentRouting
        let active = source.capturesAppAudio && OutputRoutingWarning.isTeamsLoopback(uid)
        if routingWarningActive != active { routingWarningActive = active }
        guard decision.warn, let uid else { return }
        log.warning(OutputRoutingWarning.logLine(trigger: trigger, uid: uid))
        notifier.notify(
            title: OutputRoutingWarning.notificationTitle,
            body: OutputRoutingWarning.notificationBody(deviceName: current?.name),
            urgency: .timeSensitive,
        )
    }
}
