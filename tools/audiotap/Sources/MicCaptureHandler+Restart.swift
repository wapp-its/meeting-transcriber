@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// The device-change restart path, split out of `MicCaptureHandler.swift` to keep
/// it under the 600-line lint cap (same pattern as `+Timeline`).
///
/// Everything here exists because a restart attempt can fail to return at all
/// (issue #588): `-[AVAudioEngine inputNode]` loops inside AVFAudio when the
/// default-device aggregate still references a Bluetooth device that just
/// vanished, holds the engine mutex while doing so, and cannot be cancelled.
/// Attempts therefore run off the main queue, carry a generation, and are bounded
/// by a deadline rather than only by a retry count.
extension MicCaptureHandler {
    /// A device change may launch at most one restart attempt, and the arbiter
    /// is what enforces that: an attempt already in flight may be wedged, and
    /// starting a second one would leak another thread into the same loop.
    ///
    /// `trigger` only names the cause for the log; both device triggers behave
    /// exactly as they always have. The stall watchdog does not come through
    /// here, because it has to count its launch and log its line between the
    /// arbiter's grant and the launch (see `+StallWatchdog`), but it takes the
    /// same `claimRestartAttempt` and the same `launchRestartAttempt`.
    func handleDeviceChange(_ trigger: MicRestartTrigger = .defaultInputChanged) {
        guard let claim = claimRestartAttempt() else { return }
        // Not the watchdog's budget, but it ends the wait for a stall
        // restart's first buffer: what arrives next is this restart's.
        stallWatchdog.withLock { _ = $0.restartLaunched(byStall: false) }
        launchRestartAttempt(deviceUID: claim.deviceUID, generation: claim.generation, trigger: trigger)
    }

    /// Choose the device a restart aims at and ask the arbiter for an attempt.
    /// Nil when there is nothing to restart or an attempt is already
    /// outstanding.
    ///
    /// The target is the pinned device whenever it is still present, the
    /// system default otherwise, whatever triggered the restart and however
    /// many restarts failed before. Falling back while the pinned device is
    /// there would bypass a headset's hardware mute.
    func claimRestartAttempt() -> (deviceUID: String?, generation: Int)? {
        let isDeviceAvailable = selectedDeviceUID.map(isDevicePresent) ?? false
        let action = MicRestartPolicy.decideRestart(
            isRecording: isRecording,
            // The arbiter owns "an attempt is outstanding" now, including the
            // backoff window, so this only asks the policy about the device.
            isRestarting: false,
            selectedDeviceUID: selectedDeviceUID,
            isSelectedDeviceAvailable: isDeviceAvailable,
        )
        guard case let .restart(deviceUID) = action else { return nil }
        guard case let .launchAttempt(generation) = arbiter.withLock({ $0.handle(.deviceChanged) })
        else { return nil }
        return (deviceUID, generation)
    }

    /// Runs one restart attempt off the main queue and arms a deadline for it.
    ///
    /// The deadline is the whole point: the call that brings an engine up can
    /// loop forever inside AVFAudio and cannot be cancelled, so the only way to
    /// find out is to stop waiting. `CaptureRestartRetryPolicy` still governs
    /// attempts that come back with an error; it never sees one that hangs.
    ///
    /// Known exposure, accepted for now: the OUTGOING session's teardown below
    /// runs synchronously on the main queue before the deadline is armed. If it
    /// blocked, the main thread would block with it and no deadline would
    /// notice. `MicCaptureHandlerStallWatchdogTests` pins where that happens.
    func launchRestartAttempt(deviceUID: String?, generation: Int, trigger: MicRestartTrigger) {
        if deviceUID == nil, let uid = selectedDeviceUID {
            logger.warning("Mic: selected device '\(uid)' no longer available, falling back to system default")
        }

        // Everything that owns the OUTGOING session happens here, on the main
        // queue, including its teardown. An AVAudioEngine must be released on the
        // thread that drove it: handing it to the restart queue and stopping it
        // there moves engine teardown off the main thread for the first time, and
        // the retain-grace comment in MicEngineSession records what that class of
        // mistake already cost once. The compiler says the same thing, since the
        // session is not Sendable.
        //
        // The attempt therefore carries nothing but its device and its generation.
        // It never reads `session`, so a stop running later on this same queue
        // cannot interleave with an adoption.
        removeConfigChangeObserver()
        session.teardown()

        DispatchQueue.main.asyncAfter(deadline: .now() + RestartArbiter.attemptTimeout) { [weak self] in
            self?.handleAttemptTimeout(generation: generation)
        }

        restartQueue.async { [weak self] in
            self?.runRestartAttempt(deviceUID: deviceUID, generation: generation, trigger: trigger)
        }
    }

    /// Builds a fresh session and brings it up. Everything it produces stays
    /// local until the arbiter agrees this attempt is still the current one, so
    /// an attempt that returns after its deadline cannot adopt anything.
    private func runRestartAttempt(deviceUID: String?, generation: Int, trigger: MicRestartTrigger) {
        // AVAudioEngine can be in a bad state after a config change, so an
        // attempt always builds a new session rather than reusing the engine.
        let candidate = sessionFactory()
        var rate: Double?
        var thrown: (any Error)?
        do {
            rate = try startEngine(deviceUID: deviceUID, on: candidate)
        } catch {
            thrown = error
        }
        let failure = thrown
        let succeeded = failure == nil

        let outcome = arbiter.withLock { state in
            state.handle(.attemptReturned(generation: generation, succeeded: succeeded))
        }

        switch outcome {
        case .commit:
            // Publication happens on the main queue, where stop() also runs, so
            // the two are totally ordered instead of racing on `session`.
            DispatchQueue.main.async { [weak self] in
                self?.adopt(candidate, deviceUID: deviceUID, generation: generation, rate: rate, trigger: trigger)
            }

        case .retry:
            // A transient invalid format / installTap raise (issue #379) is
            // recoverable: the device usually settles within a few hundred ms.
            let reason = failure?.localizedDescription ?? "unknown error"
            logger.error(
                "Failed to restart mic after \(trigger.logDescription, privacy: .public): \(reason, privacy: .public) — scheduling retry",
            )
            candidate.teardown()
            DispatchQueue.main.async { [weak self] in
                self?.scheduleRestartRetry(deviceUID: deviceUID, trigger: trigger)
            }

        default:
            // The session was sealed while this attempt was outstanding. It owns
            // nothing shared, so it tears its own work down and says nothing.
            logger.info("Mic: discarding a restart attempt that outlived its deadline")
            candidate.teardown()
        }
    }

    /// Publish a successful attempt, or discard it if the session was sealed
    /// while it was on its way here. Main queue only.
    private func adopt(
        _ candidate: any MicEngineSessionProviding,
        deviceUID: String?,
        generation: Int,
        rate: Double?,
        trigger: MicRestartTrigger,
    ) {
        // Read before the arbiter resumes capturing, so a buffer the render
        // thread delivers in between is still credited to this adoption.
        let adoptedAt = stallClock()
        guard case .adopt = arbiter.withLock({ $0.handle(.commitReady(generation: generation)) }) else {
            logger.info("Mic: discarding a restart that succeeded after the session was sealed")
            candidate.teardown()
            return
        }
        session = candidate
        restartRetryCount = 0
        installConfigChangeObserver()
        noteAdoptionForStallWatchdog(at: adoptedAt, trigger: trigger, onSelectedDevice: deviceUID != nil, rate: rate)
        // A stall restart's adoption is logged by the watchdog, at a retained
        // level; a device change keeps its line as it was.
        if trigger.stallRestart == nil {
            logger.info(
                "Mic: engine restarted on \(deviceUID != nil ? "selected" : "default") device (\(Int(rate ?? 0)) Hz)",
            )
        }
        if let rate, rate <= 0 {
            logger.warning("Mic: hardware format rate is \(rate) after restart — may produce incorrect audio")
        }
    }

    /// The attempt for `generation` never came back. Abandon the microphone
    /// track without touching the engine it is stuck inside.
    private func handleAttemptTimeout(generation: Int) {
        guard case .giveUp = arbiter.withLock({ $0.handle(.attemptTimedOut(generation: generation)) })
        else { return }

        logger.error(
            "Mic: restart attempt did not return within \(RestartArbiter.attemptTimeout, privacy: .public)s — giving up on the microphone track",
        )
        // Closing the file is the only cleanup that is safe here: the attempt
        // may be inside a call that holds the engine's mutex, so any engine
        // teardown would block this thread behind it.
        outputFile = nil
        stopStallWatchdog()
        onGiveUp?()
    }

    private func removeConfigChangeObserver() {
        guard let observer = configChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
    }

    /// Re-attempt a restart that came back with an error, bounded by
    /// `maxRestartRetries`. An attempt that never came back does not reach here:
    /// the deadline gives up instead, because each wedged attempt costs a thread
    /// and a good fraction of a core for the rest of the process's life.
    /// No `isRecording` guard anywhere in here: during the backoff the phase is
    /// `.backingOff`, so capture is deliberately not "running". The arbiter is the
    /// guard, and it answers `.ignore` for both events once the session is sealed.
    ///
    /// The retries belong to the restart that failed, so they carry its
    /// trigger: a stall restart's retries are not new stall restarts and are
    /// not charged to the watchdog's budget.
    private func scheduleRestartRetry(deviceUID: String?, trigger: MicRestartTrigger) {
        switch decideRetry(restartRetryCount) {
        case .giveUp:
            guard case .giveUp = arbiter.withLock({ $0.handle(.retryBudgetExhausted) }) else { return }
            logger.error("Mic: giving up restart after \(self.restartRetryCount) failed attempts")
            outputFile = nil
            stopStallWatchdog()
            onGiveUp?()

        case let .retry(delay):
            restartRetryCount += 1
            let attempt = restartRetryCount
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard case let .launchAttempt(generation) = self.arbiter.withLock({ $0.handle(.retryDue) })
                else { return }
                logger.info("Mic: restart retry \(attempt)/\(CaptureRestartRetryPolicy.maxAttempts)")
                // Re-resolve the target now rather than reusing the one captured
                // when the backoff started: a device change during the backoff is
                // ignored by design, so this is where a newer reality is picked up.
                self.launchRestartAttempt(
                    deviceUID: self.currentRestartTarget() ?? deviceUID,
                    generation: generation,
                    trigger: trigger,
                )
            }
        }
    }

    /// The device a restart should aim at right now, or nil to take the default.
    private func currentRestartTarget() -> String? {
        guard let uid = selectedDeviceUID else { return nil }
        return isDevicePresent(uid) ? uid : nil
    }
}
