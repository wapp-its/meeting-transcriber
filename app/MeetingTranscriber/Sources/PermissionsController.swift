import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - PermissionsController

/// Owns live TCC permission-health state and when the check runs.
///
/// Extracted from `AppState` as the first concern-specific controller (see the
/// AppState god-class split). `AppState` exposes it as a sub-controller and
/// composes its `health` into `currentBadge`.
///
/// The check runs at launch, and again after an activation, a wake from sleep
/// and a change of the default input device (`recheck()`), so a false verdict
/// is replaced without anyone opening a window. Three rules keep that from
/// churning the microphone, which the probe opens for half a second:
/// - **One check at a time.** A request while a check runs is folded into one
///   follow-up that starts after it, so no two probes run side by side and no
///   older result can land after a newer one.
/// - **Never while a recording captures** (`setRecordingActive`). A request then
///   waits for the capture to end, and a check already running gives way before
///   its retry; one check runs once the capture has ended.
/// - **Debounced** by `recheckInterval` for events, measured from the last
///   completed check. A check that gave way to a recording did not complete.
///
/// The `probe` seam lets tests drive all of this without the real ~500 ms
/// `PermissionHealthCheck.runLive()` TCC probe, which churns the audio HAL.
@Observable
@MainActor
final class PermissionsController {
    /// The check, handed the question it asks before the microphone probe's
    /// retry opens the device a second time. Nil when that question was
    /// answered no: the check ended without a verdict.
    typealias Probe = (_ mayRetryMicrophone: @escaping @Sendable () async -> Bool) async -> HealthCheckResult?

    /// The shortest gap between two checks that system events ask for: rapid
    /// Cmd-Tab cycles and a headset reconnecting must not open the microphone
    /// once per event.
    static let recheckInterval: TimeInterval = 3

    /// Latest health result from `check()` / `handle(_:)`. Drives the menu-bar
    /// permission-problem overlay and the `currentBadge` `.error` state.
    private(set) var health: HealthCheckResult?

    /// When the last check completed, for the debounce.
    private(set) var lastCheckAt: Date?

    /// Latest notification visibility, refreshed by `check()`. Deliberately
    /// NOT folded into `HealthCheckResult`: it only matters while a watched app
    /// asks before recording (see `BrowserConsentReadiness`), and `handle(_:)`
    /// reports problems BY posting a notification, which cannot work when the
    /// problem is that notifications do not arrive. The recording consent
    /// prompt depends on it, so Settings warns there instead.
    private(set) var notificationVisibility: NotificationVisibility?

    private let notifier: any AppNotifying
    private let probe: Probe
    private let now: @MainActor () -> Date

    /// The running check and the follow-ups it picks up; nil while idle.
    @ObservationIgnored private var running: Task<Void, Never>?
    /// A check was asked for while one ran.
    @ObservationIgnored private var followUpPending = false
    /// A check was asked for, or gave way, while a recording captured.
    @ObservationIgnored private var pendingAfterRecording = false
    /// `WatchingController.isRecordingActivity`, as it last pushed it.
    @ObservationIgnored private var recordingActive = false
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    init(
        notifier: any AppNotifying,
        probe: @escaping Probe = { await PermissionHealthCheck.runLive(mayRetryMicrophone: $0) },
        now: @escaping @MainActor () -> Date = { Date() },
    ) {
        self.notifier = notifier
        self.probe = probe
        self.now = now
    }

    /// Store the latest health result and notify on a newly-appeared problem
    /// set. A repeated identical problem set is deduped (no re-notify); a
    /// recovery to healthy clears the dedup memory so the next problem notifies.
    func handle(_ result: HealthCheckResult) {
        let previousProblems = health?.problems ?? []
        health = result
        let line = "[PermissionHealthCheck] screen=\(result.screenRecording) mic=\(result.microphone) " +
            "ax=\(result.accessibility) healthy=\(result.isHealthy) problems=\(result.problems)"
        PermissionHealthCheck.debugLog(line)

        let problems = result.problems
        if !problems.isEmpty, problems != previousProblems {
            PermissionHealthCheck.debugLog("[PermissionHealthCheck] Sending notification: \(result.notificationBody)")
            notifier.notify(
                title: "Permission Problem",
                body: result.notificationBody,
            )
        }
    }

    /// Run the check and return once no check is running: at launch, and for the
    /// automation API before it answers. Joins a running check (with one
    /// follow-up) rather than starting a second probe, and returns at once when
    /// a recording captures, leaving the check for after it.
    ///
    /// - Parameter minimumInterval: if non-nil, skip the run when the last completed
    ///   check happened less than `minimumInterval` seconds ago.
    func check(minimumInterval: TimeInterval? = nil) async {
        await request(minimumInterval: minimumInterval)?.value
    }

    /// Run the check again after a system event (an activation, a wake, a new
    /// default input device), debounced by `recheckInterval`, without waiting.
    func recheck() {
        request(minimumInterval: Self.recheckInterval)
    }

    /// Run `recheck()` after every wake from sleep, for the app's lifetime.
    /// Installs one observer however often it is called.
    func recheckAfterWake(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard wakeObserver == nil else { return }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    /// Whether a recording captures, pushed by `WatchingController` whenever its
    /// `isRecordingActivity` may have changed (repeats are harmless). Its end
    /// starts the check a request or a check that gave way left pending.
    func setRecordingActive(_ active: Bool) {
        recordingActive = active
        guard !active, pendingAfterRecording else { return }
        pendingAfterRecording = false
        request(minimumInterval: nil)
    }

    /// The task to await for the requested check, or nil when nothing runs:
    /// debounced, or waiting for a recording to end.
    @discardableResult
    private func request(minimumInterval: TimeInterval?) -> Task<Void, Never>? {
        if recordingActive {
            pendingAfterRecording = true
            PermissionHealthCheck.debugLog("[PermissionHealthCheck] check deferred until the recording ends")
            return nil
        }
        if let running {
            followUpPending = true
            return running
        }
        if let minimumInterval, let last = lastCheckAt, now().timeIntervalSince(last) < minimumInterval {
            return nil
        }
        let task = Task { await runChecks() }
        running = task
        return task
    }

    /// Runs checks one after another until no follow-up is pending. A recording
    /// that started after the request (or before a follow-up) defers the next
    /// check to its end instead.
    private func runChecks() async {
        repeat {
            followUpPending = false
            if recordingActive {
                pendingAfterRecording = true
                break
            }
            await runOneCheck()
        } while followUpPending
        running = nil
    }

    private func runOneCheck() async {
        let result = await probe { [weak self] in await self?.mayRetryMicrophone() ?? false }
        // Cheap query, no HAL churn, so it rides along with the TCC probe
        // rather than needing its own schedule.
        notificationVisibility = await notifier.notificationVisibility()
        guard let result else {
            // Gave way to a recording: no verdict and no stamp, and the check is
            // owed again, after the recording or at once if it already ended.
            followUpPending = true
            return
        }
        lastCheckAt = now()
        handle(result)
    }

    private func mayRetryMicrophone() -> Bool {
        !recordingActive
    }
}
