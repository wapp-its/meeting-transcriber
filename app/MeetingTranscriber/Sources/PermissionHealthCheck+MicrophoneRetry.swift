import AVFoundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PermissionHealthCheck")

/// The live microphone verdict and its one probe retry, split out of
/// `PermissionHealthCheck.swift` to keep that file under the line-length cap.
extension PermissionHealthCheck {
    /// Pause before the one retry of a failed microphone probe. Short, because a caller
    /// may be waiting on the check (a manual recording start); long enough for the
    /// audio system's "try again" refusal right after launch to clear.
    static let micProbeRetryPause: TimeInterval = 2.0

    /// Why one microphone probe attempt failed: one case per way `probeMicrophone`
    /// gives up. All but `.noBufferBeforeTimeout` arrive as `MicProbeOutcome.failed`;
    /// that one is an `.answered` probe that counted no buffer.
    enum MicProbeFailure: CaseIterable, Sendable {
        case noInputDevice
        case invalidFormat
        case tapInstallFailed
        case engineStartFailed
        case noBufferBeforeTimeout

        /// Compact, PII-free token for the unified log.
        var logToken: String {
            switch self {
            case .noInputDevice: "no-input-device"
            case .invalidFormat: "invalid-format"
            case .tapInstallFailed: "tap-install-failed"
            case .engineStartFailed: "engine-start-failed"
            case .noBufferBeforeTimeout: "no-buffer-before-timeout"
            }
        }

        /// Whether the failure only shows that there is no input device, or that
        /// the one there is not ready yet (a format of 0 Hz or 0 channels, which an
        /// input device reported for minutes after a wake from sleep while the
        /// grant was fine). Neither says anything about the grant, so a probe that
        /// ends on one is inconclusive and never reports broken on its own: the
        /// verdict stays the last one a probe had evidence for, healthy when there
        /// is none, the way an inconclusive Accessibility probe reports healthy. A
        /// probe that opened the device and got no buffer stays the signature of a
        /// broken grant.
        var isInconclusive: Bool {
            switch self {
            case .noInputDevice, .invalidFormat: true
            case .tapInstallFailed, .engineStartFailed, .noBufferBeforeTimeout: false
            }
        }
    }

    /// A failed probe is retried once after `micProbeRetryPause` before the microphone
    /// counts as broken. Right after a relaunch the audio system can refuse the
    /// probe's engine start with "try again" (error 35) while the microphone works,
    /// and the notification's dedup does not survive a restart, so without the retry
    /// every launch could tell the user to toggle a grant that is fine. A probe that
    /// delivers on its first attempt is not retried, and neither is one that did not
    /// answer: its bring-up still holds the probe lane, which refuses the retry at
    /// once. When both attempts fail, the retry's failure decides: it is the later
    /// look at the device. A retry that did not answer learned nothing, so the first
    /// attempt's failure stands.
    ///
    /// The verdict is `microphoneVerdict(afterAuthorizedProbe:lastAnswered:)`: an
    /// outcome that says nothing about the grant keeps the verdict of the last one
    /// that did, which `lastAnswered` holds. TCC saying anything but yes clears it.
    ///
    /// `mayRetry` is asked after the pause, right before the retry would open the
    /// microphone a second time. When it says no (a recording started meanwhile,
    /// and opening an input can switch a Bluetooth headset out of its music profile
    /// underneath that recording), the check ends without a verdict and returns nil.
    ///
    /// `authStatus`, `probe`, `sleep`, `logFailure` and `lastAnswered` are injected
    /// so tests can drive the probe outcomes on a virtual clock, without a
    /// microphone and without sharing the process-wide memory.
    static func checkMicrophoneLive(
        authStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio),
        probe: @Sendable () async -> MicProbeOutcome = { await probeMicrophone() },
        sleep: @Sendable (TimeInterval) async -> Void = { duration in
            try? await Task.sleep(for: .seconds(duration))
        },
        logFailure: @Sendable (_ attempt: Int, _ failure: MicProbeFailure) -> Void = { attempt, failure in
            logMicProbeFailure(attempt: attempt, failure: failure)
        },
        mayRetry: @Sendable () async -> Bool = { true },
        lastAnswered: OSAllocatedUnfairLock<PermissionStatus?> = lastAnsweredMicrophoneVerdict,
    ) async -> PermissionStatus? {
        if authStatus != .authorized {
            lastAnswered.withLock { $0 = nil }
            let r = checkMicrophone(authStatus: authStatus, probeSucceeds: false)
            debugLog("checkMicrophoneLive: authStatus=\(authStatus.rawValue) probe=skipped → \(r)")
            return r
        }
        guard let outcome = await probeWithOneRetry(probe: probe, sleep: sleep, logFailure: logFailure, mayRetry: mayRetry) else {
            debugLog("checkMicrophoneLive: authStatus=authorized probe=yielded (a recording started before the retry) → no verdict")
            return nil
        }
        let r = microphoneVerdict(afterAuthorizedProbe: outcome, lastAnswered: lastAnswered.withLock { $0 })
        if outcome.isEvidence { lastAnswered.withLock { $0 = r } }
        debugLog("checkMicrophoneLive: authStatus=authorized probe=\(outcome.logToken) → \(r)")
        return r
    }

    /// The outcome that decides the verdict, or nil when `mayRetry` declined the retry.
    private static func probeWithOneRetry(
        probe: @Sendable () async -> MicProbeOutcome,
        sleep: @Sendable (TimeInterval) async -> Void,
        logFailure: @Sendable (_ attempt: Int, _ failure: MicProbeFailure) -> Void,
        mayRetry: @Sendable () async -> Bool,
    ) async -> MicProbeOutcome? {
        let first = await probe()
        guard let firstFailure = first.failure else { return first }
        logFailure(1, firstFailure)
        await sleep(micProbeRetryPause)
        guard await mayRetry() else { return nil }
        let second = await probe()
        if let failure = second.failure { logFailure(2, failure) }
        return second == .didNotAnswer ? first : second
    }

    /// Writes one failed probe attempt to the unified log. The per-process debug file
    /// is truncated by the next launch, so it cannot tell a refusal that cleared on
    /// the retry from one that did not. Only the failure kind is logged.
    static func logMicProbeFailure(attempt: Int, failure: MicProbeFailure) {
        logger.notice(
            "Microphone probe attempt \(attempt) of 2 failed: \(failure.logToken, privacy: .public)",
        )
    }
}
