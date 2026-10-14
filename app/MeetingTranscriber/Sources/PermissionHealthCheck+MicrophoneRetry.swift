import AVFoundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PermissionHealthCheck")

/// The live microphone verdict and its one probe retry, split out of
/// `PermissionHealthCheck.swift` to keep that file under the line-length cap.
extension PermissionHealthCheck {
    /// Pause before the one retry of a failed microphone probe. Short, because a caller
    /// may be waiting on the check (a manual recording start); long enough for the
    /// audio system's "try again" refusal right after launch to clear.
    static let micProbeRetryPause: TimeInterval = 2.0

    /// Why one microphone probe attempt failed: one case per way `probeMicrophone`
    /// gives up.
    enum MicProbeFailure: CaseIterable {
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
    }

    /// What one microphone probe attempt observed.
    enum MicProbeOutcome {
        case delivered
        case failed(MicProbeFailure)
    }

    /// A failed probe is retried once after `micProbeRetryPause` before the microphone
    /// counts as broken. Right after a relaunch the audio system can refuse the
    /// probe's engine start with "try again" (error 35) while the microphone works,
    /// and the notification's dedup does not survive a restart, so without the retry
    /// every launch could tell the user to toggle a grant that is fine. A probe that
    /// delivers on its first attempt is not retried.
    ///
    /// `authStatus`, `probe`, `sleep` and `logFailure` are injected so tests can drive
    /// the probe outcomes on a virtual clock, without a microphone.
    static func checkMicrophoneLive(
        authStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio),
        probe: @Sendable () async -> MicProbeOutcome = { await probeMicrophone() },
        sleep: @Sendable (TimeInterval) async -> Void = { duration in
            try? await Task.sleep(for: .seconds(duration))
        },
        logFailure: @Sendable (_ attempt: Int, _ failure: MicProbeFailure) -> Void = { attempt, failure in
            logMicProbeFailure(attempt: attempt, failure: failure)
        },
    ) async -> PermissionStatus {
        if authStatus != .authorized {
            let r = checkMicrophone(authStatus: authStatus, probeSucceeds: false)
            debugLog("checkMicrophoneLive: authStatus=\(authStatus.rawValue) probe=skipped → \(r)")
            return r
        }
        let probeSucceeds = await probeWithOneRetry(probe: probe, sleep: sleep, logFailure: logFailure)
        let r = checkMicrophone(authStatus: authStatus, probeSucceeds: probeSucceeds)
        debugLog("checkMicrophoneLive: authStatus=authorized probe=\(probeSucceeds) → \(r)")
        return r
    }

    private static func probeWithOneRetry(
        probe: @Sendable () async -> MicProbeOutcome,
        sleep: @Sendable (TimeInterval) async -> Void,
        logFailure: @Sendable (_ attempt: Int, _ failure: MicProbeFailure) -> Void,
    ) async -> Bool {
        guard case let .failed(first) = await probe() else { return true }
        logFailure(1, first)
        await sleep(micProbeRetryPause)
        guard case let .failed(second) = await probe() else { return true }
        logFailure(2, second)
        return false
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
