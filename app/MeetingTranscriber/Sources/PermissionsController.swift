import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - PermissionsController

/// Owns live TCC permission-health state and the debounced re-check.
///
/// Extracted from `AppState` as the first concern-specific controller (see the
/// AppState god-class split). `AppState` exposes it as a sub-controller and
/// composes its `health` into `currentBadge`.
///
/// The `probe` seam lets tests exercise the debounce + notification logic
/// without the real ~500 ms `PermissionHealthCheck.runLive()` TCC probe, which
/// churns the audio HAL and was untestable while wired directly into AppState.
@Observable
@MainActor
final class PermissionsController {
    /// The check, handed the question it asks before the microphone probe's
    /// retry opens the device a second time. Nil when that question was
    /// answered no: the check ended without a verdict.
    typealias Probe = (_ mayRetryMicrophone: @escaping @Sendable () async -> Bool) async -> HealthCheckResult?

    /// The shortest gap between two checks that system events ask for.
    static let recheckInterval: TimeInterval = 3

    /// Latest health result from `check()` / `handle(_:)`. Drives the menu-bar
    /// permission-problem overlay and the `currentBadge` `.error` state.
    private(set) var health: HealthCheckResult?

    /// Timestamp of the last completed `check()` run. Used to debounce repeated
    /// calls triggered by `NSApplication.didBecomeActiveNotification` so the
    /// 500 ms mic probe doesn't churn the audio HAL on every Cmd-Tab.
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

    init(
        notifier: any AppNotifying,
        probe: @escaping Probe = { _ in await PermissionHealthCheck.runLive() },
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

    /// Run the live permission health check.
    ///
    /// - Parameter minimumInterval: if non-nil, skip the run when the last completed check
    ///   happened less than `minimumInterval` seconds ago. The initial startup call passes
    ///   `nil` so it always runs; the `didBecomeActive` handler passes a small value to
    ///   avoid HAL churn on rapid re-activations.
    func check(minimumInterval: TimeInterval? = nil) async {
        if let minimumInterval, let last = lastCheckAt,
           now().timeIntervalSince(last) < minimumInterval {
            return
        }
        let result = await probe { true }
        // Cheap query, no HAL churn, so it rides along with the debounced TCC
        // probe rather than needing its own schedule.
        notificationVisibility = await notifier.notificationVisibility()
        lastCheckAt = now()
        if let result { handle(result) }
    }

    /// Today's activation re-check, as `MeetingTranscriberApp` runs it.
    func recheck() {
        Task { @MainActor in
            await check(minimumInterval: Self.recheckInterval)
        }
    }

    /// No wake trigger exists yet.
    func recheckAfterWake(center _: NotificationCenter = NSWorkspace.shared.notificationCenter) {}

    /// Nothing reads the recording yet.
    func setRecordingActive(_: Bool) {}
}
