import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// What launched a restart. Passed through the attempt, its retries and its
/// adoption, so the log names the cause and only the watchdog's own restarts
/// are charged to its budget.
enum MicRestartTrigger: Equatable {
    /// `kAudioHardwarePropertyDefaultInputDevice` changed.
    case defaultInputChanged
    /// `AVAudioEngineConfigurationChange` for the running engine. Paced and
    /// capped by `MicConfigChangePolicy` (see `+ConfigChange`): a pinned
    /// headset posted one after every engine start, and restarting on each
    /// one never let a buffer arrive.
    case configurationChanged
    /// The stall watchdog, with the restart's number in this recording.
    case stall(restart: Int)
    /// Another microphone was chosen during the recording (see
    /// `+DeviceSelection`). Charged to no budget, like a device change.
    case deviceSelected

    var stallRestart: Int? {
        guard case let .stall(restart) = self else { return nil }
        return restart
    }

    /// Both device triggers keep the wording the retry line always had.
    var logDescription: String {
        switch self {
        case .defaultInputChanged, .configurationChanged: "device change"
        case let .stall(restart): "stall restart \(restart)"
        case .deviceSelected: "device selection"
        }
    }
}

/// The microphone stall watchdog: when the input stops delivering buffers
/// without any device or configuration change to say so, restart it through
/// the path a device change takes. The judgement lives in
/// `MicStallWatchdogPolicy`; this file is the wiring and the log lines.
///
/// **Three inputs, two threads.** The render thread reports every buffer that
/// passes the tap block's capturing check, zeros included. A main-queue timer
/// ticks the policy every `Limits.pollIntervalSeconds`. Adoptions report from
/// the main queue, where every restart is published. The policy sits behind a
/// lock so the per-buffer report and the tick do not race.
///
/// **Same path as a device change.** A stall restart takes `claimRestartAttempt`
/// (the pinned device while it is present, the system default otherwise) and
/// `launchRestartAttempt`, so it gets a fresh session, the arbiter's
/// generation and deadline, the shared retry budget, and `TimelineAnchor`
/// turning the gap into silence.
///
/// **The log is the evidence.** Whether a restart brings a stalled headset
/// back is unmeasured; these lines measure it. They are at notice, warning and
/// error, because info lines are not retained in the unified log, and they
/// carry durations and counts, never a device name or UID. Bounded: one line
/// per stall restart, its adoption and its first buffer, and one for the
/// exhaustion.
extension MicCaptureHandler {
    /// Production device lookup for `isDevicePresent`: plain CoreAudio, no
    /// engine, so it cannot reach the calls that wedge.
    static func isDevicePresentOnSystem(_ uid: String) -> Bool {
        MicEngineSession.deviceIDForUID(uid) != kAudioObjectUnknown
    }

    /// Start watching. Called once capture is running; main queue.
    ///
    /// The timer holds the handler weakly: a dropped handler stops being
    /// polled at once, and its `deinit` runs `stop()`, which cancels the timer.
    func startStallWatchdog() {
        let now = stallClock()
        let limits = stallWatchdog.withLock { policy in
            policy.captureStarted(at: now)
            return policy.limits
        }
        guard stallTimer == nil else { return }
        let interval = limits.pollIntervalSeconds
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(max(1, Int(interval * 100))),
        )
        timer.setEventHandler { [weak self] in
            self?.pollStallWatchdog()
        }
        timer.resume()
        stallTimer = timer
        logger.notice(
            "Mic: stall watchdog on (restart after \(Self.seconds(limits.stallSeconds), privacy: .public) s without a buffer, \(Self.seconds(limits.graceAfterAdoptionSeconds), privacy: .public) s grace after a restart, at most \(limits.maxConsecutiveFruitlessRestarts, privacy: .public) in a row without a buffer and \(limits.maxRestartsPerRecording, privacy: .public) per recording)",
        )
    }

    /// Stop watching, for good: the recording stopped or the track was given
    /// up. Main queue.
    func stopStallWatchdog() {
        stallTimer?.cancel()
        stallTimer = nil
        stallWatchdog.withLock { $0.stop() }
    }

    /// Render thread, once per buffer that passed the capturing check. Only
    /// stores: the tick on the main queue does the judging and the logging.
    func noteBufferForStallWatchdog() {
        let now = stallClock()
        stallWatchdog.withLock { $0.bufferArrived(at: now) }
    }

    /// Main queue, from every adoption. `adoptedAt` was read before the
    /// arbiter resumed capturing.
    func noteAdoptionForStallWatchdog(
        at adoptedAt: TimeInterval, trigger: MicRestartTrigger, onSelectedDevice: Bool, rate: Double?,
    ) {
        stallWatchdog.withLock { $0.restartAdopted(at: adoptedAt, stallRestart: trigger.stallRestart) }
        guard let restart = trigger.stallRestart else { return }
        logger.notice(
            "Mic: stall restart \(restart, privacy: .public)/\(self.stallRestartCap, privacy: .public) adopted on the \(onSelectedDevice ? "selected" : "default", privacy: .public) device (\(Int(rate ?? 0), privacy: .public) Hz), waiting for its first buffer",
        )
    }

    /// One tick: ask the policy and act on what it says. Main queue. Returns
    /// the decision so a test can drive the watchdog without the timer.
    @discardableResult
    func pollStallWatchdog() -> MicStallWatchdogPolicy.Decision? {
        let now = stallClock()
        let capturing = isRecording
        guard let decision = stallWatchdog.withLock({ $0.tick(now: now, capturing: capturing) }) else { return nil }
        switch decision {
        case let .resumed(restart, secondsAfterAdoption):
            logger.notice(
                "Mic: buffers resumed after stall restart \(restart, privacy: .public)/\(self.stallRestartCap, privacy: .public), \(Self.seconds(secondsAfterAdoption), privacy: .public) s after adoption",
            )

        case let .restart(silentSeconds):
            launchStallRestart(silentSeconds: silentSeconds)

        case let .exhausted(reason, silentSeconds):
            let why = switch reason {
            case .fruitlessStreak:
                "the last \(stallWatchdog.withLock { $0.consecutiveFruitless }) stall restarts brought no buffer back"

            case .perRecordingCap:
                "\(stallRestartCap) stall restarts already in this recording"
            }
            logger.error(
                "Mic: no buffers for \(Self.seconds(silentSeconds), privacy: .public) s, but \(why, privacy: .public); not restarting on a stall again in this recording",
            )
        }
        return decision
    }

    /// Ask the arbiter, count only what it launched, then launch. A decline
    /// (an attempt already outstanding) costs the budget nothing.
    private func launchStallRestart(silentSeconds: TimeInterval) {
        guard let claim = claimRestartAttempt() else { return }
        // Nil only for a stopped watchdog, and a stopped capture is never
        // granted an attempt. A granted one is launched regardless: dropping it
        // would leave the arbiter waiting on an attempt with no deadline.
        let number = stallWatchdog.withLock { $0.restartLaunched(byStall: true) } ?? 0
        logger.warning(
            "Mic: no buffers for \(Self.seconds(silentSeconds), privacy: .public) s, restarting capture (stall restart \(number, privacy: .public)/\(self.stallRestartCap, privacy: .public))",
        )
        launchRestartAttempt(deviceUID: claim.deviceUID, generation: claim.generation, trigger: .stall(restart: number))
    }

    private var stallRestartCap: Int {
        stallWatchdog.withLock { $0.limits.maxRestartsPerRecording }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}
