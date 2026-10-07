import Foundation

/// Decides whether an `AVAudioEngineConfigurationChange` restarts the
/// microphone at once, after a backoff, or not at all.
///
/// Why this exists: a user had a headset pinned as the microphone. Every
/// engine start made AVAudioEngine post a configuration change about 50 to
/// 100 ms later, the handler restarted the capture on each one, and the fresh
/// engine's start posted the next change. 233 engine starts in 35 seconds, not
/// one buffer delivered. The stall watchdog (`MicStallWatchdogPolicy`) never
/// fired, because every adoption opens its grace and it does not judge while
/// an attempt is outstanding, so a restart every 150 ms kept it silent for
/// good. Nothing in the restart path limited how often a configuration change
/// may restart.
///
/// **The rule.** Of the configuration-change restarts launched in any
/// `Limits.windowSeconds`, at most `Limits.maxRestartsPerWindow`; a launch at
/// `t` counts while `now - t < windowSeconds`. With `k` of them in the window,
/// the next one waits `Limits.backoffSeconds[k]` (the schedule's last entry
/// once `k` runs past it), so the first in a window still restarts at once,
/// as before. A notification while a delayed restart is pending adds nothing,
/// and that is checked first. Once the cap is reached, notifications launch
/// nothing until the oldest launch leaves the window.
///
/// **A decision is not a launch.** `decide` charges nothing: the caller asks
/// the restart arbiter for the attempt afterwards, and the arbiter declines
/// while another attempt is in flight. Only `restartLaunched`, called for an
/// attempt the arbiter granted, counts, exactly as the stall watchdog counts
/// only the restarts the arbiter launched.
///
/// **Logged, but bounded.** Every restart decision gets a line. A decision
/// that launches nothing is logged the first time for its reason and then
/// again only once `windowSeconds` passed since that reason was last logged,
/// so a device that posts changes all the time cannot flood the log.
///
/// **Worst case**, production limits: 3 configuration-change restarts in any
/// 60 seconds, so the first minute of a recording sees at most 4 engine starts
/// besides stall restarts and failed-attempt retries. Each restart is one
/// arbiter attempt sequence that retries up to
/// `CaptureRestartRetryPolicy.maxAttempts` (5) times, so a window sees at most
/// 3 × (1 + 5) = 18 engine bring-ups from configuration changes, against 233 in
/// 35 seconds before. The stall watchdog stays able to act: the 3 adoptions
/// open at most 3 × 15 = 45 seconds of its grace in a 60-second window, so at
/// least 15 seconds of every window lie outside any grace they open, and a
/// capture that delivers nothing reaches its stall restart there.
///
/// The clock is monotonic seconds passed in by the caller, the same clock the
/// stall watchdog reads (`MicStallWatchdogPolicy.monotonicNow`). Pure and
/// main-queue state in the handler, so it needs no lock, and every boundary is
/// testable without an engine.
struct MicConfigChangePolicy: Equatable {
    struct Limits: Equatable, Sendable {
        /// The sliding window the cap and the ignore logging are counted over.
        var windowSeconds: TimeInterval
        /// Configuration-change restarts launched per window.
        var maxRestartsPerWindow: Int
        /// The delay before the restart that follows `k` launches in the
        /// window, at index `k`.
        var backoffSeconds: [TimeInterval]

        static let production = Self(windowSeconds: 60, maxRestartsPerWindow: 3, backoffSeconds: [0, 1, 2])

        /// The delay after `launched` launches in the window. An empty schedule
        /// has no delay.
        fileprivate func backoff(afterLaunches launched: Int) -> TimeInterval {
            backoffSeconds.isEmpty ? 0 : backoffSeconds[min(launched, backoffSeconds.count - 1)]
        }
    }

    /// Why a notification launches nothing.
    enum IgnoreReason: Hashable {
        /// A delayed restart is already waiting; it will rebuild the engine.
        case restartPending
        /// `Limits.maxRestartsPerWindow` were already launched in the window.
        case capReached
    }

    enum Decision: Equatable {
        /// Ask the arbiter for an attempt after this delay, and report it with
        /// `restartLaunched` only if the arbiter granted one.
        case restart(afterSeconds: TimeInterval)
        /// Launch nothing. `log` says whether this one is worth a line.
        case ignore(IgnoreReason, log: Bool)
    }

    let limits: Limits
    /// When the configuration-change restarts in the window were launched,
    /// oldest first.
    private var launches: [TimeInterval] = []
    private var engineStartedAt: TimeInterval?
    private var lastLoggedAt: [IgnoreReason: TimeInterval] = [:]

    init(limits: Limits = .production) {
        self.limits = limits
    }

    /// The current engine started: the recording's first start and every
    /// adoption, whichever trigger launched it.
    mutating func engineStarted(at now: TimeInterval) {
        engineStartedAt = now
    }

    /// Seconds since the current engine started, nil when no start was
    /// recorded.
    func secondsSinceEngineStart(at now: TimeInterval) -> TimeInterval? {
        engineStartedAt.map { max(0, now - $0) }
    }

    /// Configuration-change restarts launched in the window that ends at `now`.
    func launchedInWindow(at now: TimeInterval) -> Int {
        launches.count { now - $0 < limits.windowSeconds }
    }

    /// A configuration change arrived. `restartPending` is whether a delayed
    /// restart from an earlier decision is still waiting.
    mutating func decide(at now: TimeInterval, restartPending: Bool) -> Decision {
        forgetLaunches(outsideWindowAt: now)
        if restartPending {
            return .ignore(.restartPending, log: shouldLog(.restartPending, at: now))
        }
        let launched = launches.count
        if launched >= limits.maxRestartsPerWindow {
            return .ignore(.capReached, log: shouldLog(.capReached, at: now))
        }
        return .restart(afterSeconds: limits.backoff(afterLaunches: launched))
    }

    /// The arbiter launched a configuration-change restart. The only thing
    /// that charges the budget.
    mutating func restartLaunched(at now: TimeInterval) {
        forgetLaunches(outsideWindowAt: now)
        launches.append(now)
    }

    /// The capture-log line for `decision`, taken at `now`, or nil when the
    /// decision says not to log. Rendered when the notification arrives, so
    /// its count is the launches before this one: a launch the arbiter may
    /// still decline is never claimed. Spelled out here so the wording is under
    /// test.
    ///
    /// **No device UID or name, deliberately.** The lines are unconditional
    /// and public, and `PersistentDiagnosticLog` writes them into the file
    /// Settings exports as redacted; see `MicDevicePinOutcome.logLine`. They
    /// carry durations, counts and decisions only.
    func logLine(for decision: Decision, at now: TimeInterval) -> String? {
        let since = secondsSinceEngineStart(at: now).map { String(format: "%.2f", $0) } ?? "?"
        let changed = "Mic: engine configuration changed \(since) s after the engine started"
        let budget = "\(launchedInWindow(at: now)) of at most \(limits.maxRestartsPerWindow) configuration-change restarts already launched in the last \(Self.seconds(limits.windowSeconds)) s"
        switch decision {
        case let .restart(afterSeconds):
            let when = afterSeconds > 0 ? "in \(Self.seconds(afterSeconds)) s" : "now"
            return "\(changed); restarting \(when) (\(budget))"

        case .ignore(_, log: false):
            return nil

        case .ignore(.restartPending, log: true):
            return "\(changed); a configuration-change restart is already pending, not scheduling another"

        case .ignore(.capReached, log: true):
            return "\(changed); \(budget); not restarting on configuration changes until the window frees a slot, the stall watchdog stays armed"
        }
    }

    private mutating func forgetLaunches(outsideWindowAt now: TimeInterval) {
        launches.removeAll { now - $0 >= limits.windowSeconds }
    }

    /// True for the first ignore of `reason`, then again once a window passed
    /// since it was last logged.
    private mutating func shouldLog(_ reason: IgnoreReason, at now: TimeInterval) -> Bool {
        if let last = lastLoggedAt[reason], now - last < limits.windowSeconds { return false }
        lastLoggedAt[reason] = now
        return true
    }

    /// A configured duration as configured: `60`, `1`, `0.05`.
    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%g", value)
    }
}
