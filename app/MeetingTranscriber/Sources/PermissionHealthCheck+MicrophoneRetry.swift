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

        /// Whether the failure only shows that there is no input device, or that
        /// the one there is not ready yet (a format of 0 Hz or 0 channels, which an
        /// input device reported for minutes after a wake from sleep while the
        /// grant was fine). Neither says anything about the grant, so a probe that
        /// ends on one is inconclusive and reports healthy, the way an inconclusive
        /// Accessibility probe does. A probe that opened the device and got no
        /// buffer stays the signature of a broken grant.
        var isInconclusive: Bool {
            switch self {
            case .noInputDevice, .invalidFormat: true
            case .tapInstallFailed, .engineStartFailed, .noBufferBeforeTimeout: false
            }
        }
    }

    /// What one microphone probe attempt observed.
    enum MicProbeOutcome {
        case delivered
        case failed(MicProbeFailure)

        /// Whether an allowed grant still stands after this outcome: the probe
        /// delivered, or it failed only in a way that says nothing about the grant.
        var leavesGrantStanding: Bool {
            switch self {
            case .delivered: true
            case let .failed(failure): failure.isInconclusive
            }
        }

        /// Compact, PII-free token for the debug log.
        var logToken: String {
            switch self {
            case .delivered: "delivered"
            case let .failed(failure): "\(failure.isInconclusive ? "inconclusive" : "failed")(\(failure.logToken))"
            }
        }
    }

    /// A failed probe is retried once after `micProbeRetryPause` before the microphone
    /// counts as broken. Right after a relaunch the audio system can refuse the
    /// probe's engine start with "try again" (error 35) while the microphone works,
    /// and the notification's dedup does not survive a restart, so without the retry
    /// every launch could tell the user to toggle a grant that is fine. A probe that
    /// delivers on its first attempt is not retried. When both attempts fail, the
    /// retry's failure decides: it is the later look at the device.
    ///
    /// `mayRetry` is asked after the pause, right before the retry would open the
    /// microphone a second time. When it says no (a recording started meanwhile,
    /// and opening an input can switch a Bluetooth headset out of its music profile
    /// underneath that recording), the check ends without a verdict and returns nil.
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
        mayRetry: @Sendable () async -> Bool = { true },
    ) async -> PermissionStatus? {
        if authStatus != .authorized {
            let r = checkMicrophone(authStatus: authStatus, probeSucceeds: false)
            debugLog("checkMicrophoneLive: authStatus=\(authStatus.rawValue) probe=skipped → \(r)")
            return r
        }
        guard let outcome = await probeWithOneRetry(probe: probe, sleep: sleep, logFailure: logFailure, mayRetry: mayRetry) else {
            debugLog("checkMicrophoneLive: authStatus=authorized probe=yielded (a recording started before the retry) → no verdict")
            return nil
        }
        let r = checkMicrophone(authStatus: authStatus, probeSucceeds: outcome.leavesGrantStanding)
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
        guard case let .failed(first) = await probe() else { return .delivered }
        logFailure(1, first)
        await sleep(micProbeRetryPause)
        guard await mayRetry() else { return nil }
        let second = await probe()
        if case let .failed(failure) = second { logFailure(2, failure) }
        return second
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
