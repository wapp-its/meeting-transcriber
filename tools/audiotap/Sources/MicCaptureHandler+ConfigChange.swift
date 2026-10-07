@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// The `AVAudioEngineConfigurationChange` path, split out of
/// `MicCaptureHandler.swift` to keep it under the 600-line lint cap (same
/// pattern as `+StallWatchdog`).
///
/// **Paced and capped.** By AVFAudio's header the engine has already stopped
/// itself when it posts this notification, so a restart is still the answer
/// to one. But a pinned headset posted one after every engine start: the
/// handler restarted on each, the fresh engine's start posted the next, and
/// 233 engine starts in 35 seconds delivered not one buffer while every
/// adoption reopened the stall watchdog's grace. Every notification therefore
/// goes through `MicConfigChangePolicy`: the first restart in its window runs
/// at once, as before, later ones wait out a backoff, and beyond the cap
/// nothing is launched and the stall watchdog is left to act.
///
/// **Same path as a device change.** A restart, immediate or delayed, takes
/// `handleDeviceChange(.configurationChanged)`: the arbiter's single attempt
/// and the usual target, the pinned device while it is present. It is charged
/// to the policy only when the arbiter granted it.
///
/// **One delayed restart at most**, in `pendingConfigChangeRestart`, dropped
/// through `cancelPendingConfigChangeRestart()` by `stop()`, by either
/// give-up and by every adoption, since a newer session supersedes it.
///
/// Main queue throughout: the observer delivers there, and the delayed
/// restart runs there.
extension MicCaptureHandler {
    /// Listen for AVAudioEngine configuration changes on the current session's
    /// engine.
    func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: session.notificationObject,
            queue: .main,
        ) { [weak self] _ in
            self?.handleEngineConfigChange()
        }
        logger.info("Mic: listening for engine configuration changes")
    }

    /// The current engine posted a configuration change. Internal so a test
    /// can drive it like `pollStallWatchdog()`.
    ///
    /// The line is written here, when the notification arrives, not when a
    /// delayed restart fires, so its timing and its seconds since the engine
    /// started are the notification's.
    func handleEngineConfigChange() {
        let now = stallClock()
        let decision = configChangePolicy.decide(at: now, restartPending: pendingConfigChangeRestart != nil)
        let line = configChangePolicy.logLine(for: decision, at: now)
        switch decision {
        case let .restart(afterSeconds):
            if let line { logger.notice("\(line, privacy: .public)") }
            if afterSeconds > 0 {
                scheduleConfigChangeRestart(after: afterSeconds)
            } else {
                launchConfigChangeRestart()
            }

        case .ignore(.restartPending, _):
            if let line { logger.notice("\(line, privacy: .public)") }

        case .ignore(.capReached, _):
            if let line { logger.error("\(line, privacy: .public)") }
        }
    }

    /// Drop the delayed restart, if one is waiting. Main queue.
    func cancelPendingConfigChangeRestart() {
        pendingConfigChangeRestart?.cancel()
        pendingConfigChangeRestart = nil
    }

    private func scheduleConfigChangeRestart(after delay: TimeInterval) {
        let restart = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingConfigChangeRestart = nil
            launchConfigChangeRestart()
        }
        pendingConfigChangeRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: restart)
    }

    /// Ask the arbiter, and charge the policy only for what it launched.
    private func launchConfigChangeRestart() {
        guard handleDeviceChange(.configurationChanged) else { return }
        configChangePolicy.restartLaunched(at: stallClock())
    }
}
