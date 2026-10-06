import Foundation

/// Decides when a microphone that stopped delivering buffers is worth
/// restarting, and when to stop trying.
///
/// Why this exists: a user had a USB headset pinned as the microphone. In a
/// Teams call it delivered buffers for about ninety seconds and then delivered
/// none at all, for the rest of the call. The track was gap-filled with exact
/// zeros from that point on, and nothing restarted the capture, because the
/// only two restart triggers are a change of the system default input device
/// and `AVAudioEngineConfigurationChange`, and a pinned device that simply
/// stalls changes neither. The app layer's `ChannelFaultMonitor` tells the
/// user after ninety seconds; it does not act.
///
/// **What triggers.** No buffer for `Limits.stallSeconds`, measured from the
/// latest of the last buffer, the last restart adoption and the capture start,
/// while the restart arbiter is capturing (never during an attempt or its
/// backoff, never after a give-up or a stop). Ten seconds is far above any
/// gap a working input shows (the tap asks for 4096-frame buffers, about ten a
/// second, and the shared retry schedule is sized for a device that needs about
/// three seconds to re-enumerate), while staying well under the ninety-second
/// notification, so a restart that works lands before the user is told the
/// channel is silent.
///
/// **Zeros are buffers.** Only the absence of buffers counts. A headset muted
/// in hardware, or by the call app, delivers buffers of exact zeros, and that
/// is ordinary call etiquette rather than a fault. Restarting on it would
/// expose a healthy capture to the restart wedge of issue #588 for nothing,
/// and the policy never sees a sample anyway: the handler reports every buffer
/// the same way, whatever it carries.
///
/// **No fallback to the default device.** The restart targets the pinned
/// device whenever it is still present, exactly as a device change does, and
/// fruitless restarts never change that. Switching to the built-in microphone
/// would bypass the headset's hardware mute and record a room the user
/// believes is not being recorded.
///
/// **Bounds**, all counted per recording:
/// - `Limits.graceAfterAdoptionSeconds` after every adoption, whichever trigger
///   launched it, before a stall can be judged again, so a fresh engine gets
///   time to deliver its first buffer;
/// - at most `Limits.maxConsecutiveFruitlessRestarts` stall restarts in a row
///   after which not a single buffer arrived. Only a buffer resets the streak:
///   an engine that starts and then delivers nothing is exactly the failure,
///   so a successful start is no evidence of recovery;
/// - at most `Limits.maxRestartsPerRecording` stall restarts in total, however
///   often the streak resets.
///
/// Only restarts the arbiter actually launched count. When either budget is
/// spent the watchdog stops restarting for the rest of the recording, once,
/// and says so; device-change restarts and a capture that recovers on its own
/// stay possible. It does not end the track: that is the arbiter's give-up,
/// which stays terminal and unchanged.
///
/// **Worst case.** Each stall restart is one arbiter attempt sequence, and a
/// sequence whose attempts come back with errors retries up to
/// `CaptureRestartRetryPolicy.maxAttempts` (5) more times; if the last retry
/// fails too, the arbiter gives the track up. So a recording sees at most
/// 6 × (1 + 5) = 36 engine bring-ups from this watchdog, and only if every stall
/// restart succeeds on its last retry. Each bring-up is bounded by
/// `RestartArbiter.attemptTimeout` (5 s), and one that never returns ends the
/// microphone track exactly as it would after a device change. Six stall
/// restarts also need at least one recovery in between (the streak cap is
/// three) and fifteen seconds of grace after each, so they cannot come in a
/// burst.
///
/// The clock is monotonic seconds passed in by the caller (`mach_absolute_time`
/// in production, which does not advance while the Mac sleeps, so a wake is not
/// mistaken for a stall). Pure, following `SilentTrackWatchdogPolicy` and
/// `RestartArbiter`, so every boundary is testable without an engine.
struct MicStallWatchdogPolicy: Equatable {
    struct Limits: Equatable, Sendable {
        /// How often the handler's main-queue timer asks `tick`.
        var pollIntervalSeconds: TimeInterval
        /// How long without a buffer counts as a stall.
        var stallSeconds: TimeInterval
        /// How long after any adoption no stall is judged.
        var graceAfterAdoptionSeconds: TimeInterval
        /// Stall restarts in a row without a buffer before the watchdog stops.
        var maxConsecutiveFruitlessRestarts: Int
        /// Stall restarts per recording before the watchdog stops.
        var maxRestartsPerRecording: Int

        static let production = Self(
            pollIntervalSeconds: 2,
            stallSeconds: 10,
            graceAfterAdoptionSeconds: 15,
            maxConsecutiveFruitlessRestarts: 3,
            maxRestartsPerRecording: 6,
        )
    }

    /// Which budget ran out.
    enum Exhaustion: Equatable {
        /// `maxConsecutiveFruitlessRestarts` stall restarts in a row brought
        /// no buffer back.
        case fruitlessStreak
        /// `maxRestartsPerRecording` stall restarts already in this recording.
        case perRecordingCap
    }

    enum Decision: Equatable {
        /// The first buffer after stall restart `restart` arrived
        /// `secondsAfterAdoption` after that restart was adopted. Only this
        /// proves a restart helped; a start that succeeds proves nothing.
        case resumed(restart: Int, secondsAfterAdoption: TimeInterval)
        /// No buffer for `silentSeconds`. Ask the arbiter for an attempt, and
        /// report it with `restartLaunched` only if the arbiter granted one.
        case restart(silentSeconds: TimeInterval)
        /// A restart is due but a budget is spent. Returned once; nothing is
        /// restarted by the watchdog after it.
        case exhausted(Exhaustion, silentSeconds: TimeInterval)
    }

    /// A stall restart that was adopted and has not seen a buffer since.
    private struct AwaitedResume: Equatable {
        let restart: Int
        let adoptedAt: TimeInterval
    }

    let limits: Limits
    /// Stall restarts the arbiter launched in this recording.
    private(set) var restartsLaunched = 0
    /// Stall restarts launched since the last buffer. Only a buffer resets it.
    private(set) var consecutiveFruitless = 0
    /// A budget ran out; no stall restart for the rest of the recording.
    private(set) var isExhausted = false
    private(set) var isStopped = false
    private var isWatching = false
    private var captureStartedAt: TimeInterval = 0
    private var lastBufferAt: TimeInterval?
    private var lastAdoptionAt: TimeInterval?
    private var awaitedResume: AwaitedResume?
    /// A resume seen by `bufferArrived` (render thread) and not yet reported by
    /// `tick` (main queue), where it can be logged.
    private var unreportedResume: Decision?

    init(limits: Limits = .production) {
        self.limits = limits
    }

    /// The production clock. `mach_absolute_time` rather than wall-clock time,
    /// which can jump, and rather than `mach_continuous_time`, which counts
    /// sleep: after a wake the capture gets a fresh ten seconds instead of
    /// being judged stalled for the whole nap.
    @Sendable
    static func monotonicNow() -> TimeInterval {
        machTicksToSeconds(mach_absolute_time())
    }

    /// Capture started. The stall clock runs from here until the first buffer,
    /// so an input that never delivers anything is caught too.
    mutating func captureStarted(at now: TimeInterval) {
        guard !isWatching, !isStopped else { return }
        isWatching = true
        captureStartedAt = now
    }

    /// A buffer reached the handler, whatever it carried. Called from the
    /// render thread for every buffer, so it only stores.
    mutating func bufferArrived(at now: TimeInterval) {
        guard !isStopped else { return }
        lastBufferAt = now
        consecutiveFruitless = 0
        if let awaited = awaitedResume {
            awaitedResume = nil
            unreportedResume = .resumed(restart: awaited.restart, secondsAfterAdoption: max(0, now - awaited.adoptedAt))
        }
    }

    /// The timer's question: is a stall restart due? `capturing` is the
    /// arbiter's phase, read just before.
    ///
    /// A resume waiting to be reported is returned first, and the stall is
    /// judged on the next tick: a stall needs ten seconds without a buffer, and
    /// a resume means a buffer just came, so nothing is lost by waiting.
    mutating func tick(now: TimeInterval, capturing: Bool) -> Decision? {
        guard isWatching, !isStopped else { return nil }
        if let resume = unreportedResume {
            unreportedResume = nil
            return resume
        }
        guard capturing, !isExhausted else { return nil }
        if let lastAdoptionAt, now - lastAdoptionAt < limits.graceAfterAdoptionSeconds { return nil }

        let silentSince = max(captureStartedAt, lastBufferAt ?? -.infinity, lastAdoptionAt ?? -.infinity)
        let silentSeconds = now - silentSince
        guard silentSeconds >= limits.stallSeconds else { return nil }

        if consecutiveFruitless >= limits.maxConsecutiveFruitlessRestarts {
            isExhausted = true
            return .exhausted(.fruitlessStreak, silentSeconds: silentSeconds)
        }
        if restartsLaunched >= limits.maxRestartsPerRecording {
            isExhausted = true
            return .exhausted(.perRecordingCap, silentSeconds: silentSeconds)
        }
        return .restart(silentSeconds: silentSeconds)
    }

    /// The arbiter launched a restart. `byStall` says whether it was the one a
    /// `.restart` decision asked for; only those are counted. Returns the stall
    /// restart's number in this recording, nil for any other trigger.
    ///
    /// Every launch, whatever its trigger, ends the wait for the previous stall
    /// restart's first buffer: a buffer after this point belongs to this one.
    @discardableResult
    mutating func restartLaunched(byStall: Bool) -> Int? {
        guard !isStopped else { return nil }
        awaitedResume = nil
        guard byStall else { return nil }
        restartsLaunched += 1
        consecutiveFruitless += 1
        return restartsLaunched
    }

    /// A restart was adopted, whichever trigger launched it. Opens the grace.
    /// `stallRestart` is the number `restartLaunched` handed out when a stall
    /// launched it, so that restart's first buffer can be reported.
    ///
    /// `now` must be read before the arbiter starts capturing again: the render
    /// thread can deliver in the moment between that and this call, and a
    /// buffer stamped at or after `now` is then credited to this restart.
    mutating func restartAdopted(at now: TimeInterval, stallRestart: Int?) {
        guard !isStopped else { return }
        lastAdoptionAt = now
        guard let stallRestart else {
            awaitedResume = nil
            return
        }
        if let lastBufferAt, lastBufferAt >= now {
            unreportedResume = .resumed(restart: stallRestart, secondsAfterAdoption: lastBufferAt - now)
        } else {
            awaitedResume = AwaitedResume(restart: stallRestart, adoptedAt: now)
        }
    }

    /// The recording stopped or the track was given up. Nothing is decided or
    /// reported after this.
    mutating func stop() {
        isStopped = true
        awaitedResume = nil
        unreportedResume = nil
    }
}
