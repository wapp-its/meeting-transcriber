@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Spends the configuration change that pinning the microphone causes, before
/// the engine starts.
///
/// Moving the engine's input unit to the configured device with
/// `kAudioOutputUnitProperty_CurrentDevice` makes AVAudioEngine post an
/// `AVAudioEngineConfigurationChange` of its own, typically about 100 ms later
/// and from a private queue. AVFAudio's header says what that notification
/// means: the engine's I/O unit saw the hardware's channel count or sample rate
/// change, and the engine has stopped itself. Arriving after `start()`, it
/// stopped an engine that had not delivered its first buffer yet, and the
/// capture handler's long-lived observer took it for a route change and built
/// a fresh engine, whose pin posted the next one: hundreds of engine starts a
/// minute and not one buffer. Waiting for it here, on an observer scoped to
/// this engine, lets it land on an engine that has not started, where it stops
/// nothing and reaches no restart path.
enum MicPinSettle {
    /// What the settle observed. Durations, never a device: see `logLine`.
    enum Outcome: Equatable, Sendable {
        /// The pin did not move the unit, so no change was coming and nothing
        /// was waited for.
        case notNeeded
        /// The pin's change arrived and was spent this long after the pin
        /// returned.
        case settled(afterSeconds: TimeInterval)
        /// No change arrived within the timeout; the engine starts anyway, and
        /// a change arriving later goes to the capture handler's observer.
        case timedOut(afterSeconds: TimeInterval)

        /// What the capture log prints, nil when there is nothing to say.
        ///
        /// No device UID or name, deliberately, for the reason on
        /// `MicDevicePinOutcome.logLine`: the line is unconditional and lands
        /// in the exported diagnostics, whose redaction is os_log's own.
        var logLine: String? {
            switch self {
            case .notNeeded:
                nil

            case let .settled(afterSeconds):
                "Mic: the configured microphone's configuration change arrived \(Self.milliseconds(afterSeconds)) ms after binding it and was absorbed before the engine started"

            case .timedOut:
                "Mic: no configuration change within \(Self.milliseconds(MicPinSettle.timeoutSeconds)) ms of binding the configured microphone; starting the engine anyway"
            }
        }

        private static func milliseconds(_ seconds: TimeInterval) -> Int {
            Int((seconds * 1000).rounded())
        }
    }

    /// How long a start that moved the unit waits for the change. The change is
    /// typically about 100 ms after the pin, and at a recording's first start
    /// the wait blocks the main queue, so this bounds that block; it also sits
    /// far inside `RestartArbiter.attemptTimeout` when a restart attempt waits.
    static let timeoutSeconds: TimeInterval = 0.5

    /// Run `pin`, and when it reports that it moved the unit, wait up to
    /// `timeout` for `object`'s configuration change.
    ///
    /// The order is load-bearing: the observer is registered before `pin`
    /// runs, so a change posted synchronously inside the set, or microseconds
    /// after it, is not missed. The observer's block runs on whatever queue
    /// AVFAudio posts from and does nothing but signal; the header warns
    /// against tearing the engine down from inside that handler. The observer
    /// is removed on every path.
    ///
    /// - Parameter pin: points the unit at the device and returns whether that
    ///   moved it, which is whether a change is expected (`pinMovedUnit`).
    static func run(
        observing object: AnyObject,
        center: NotificationCenter = .default,
        timeout: TimeInterval = timeoutSeconds,
        clock: () -> TimeInterval = MicStallWatchdogPolicy.monotonicNow,
        pin: () -> Bool,
    ) -> Outcome {
        let changeArrived = DispatchSemaphore(value: 0)
        let observer = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: object,
            queue: nil,
        ) { _ in
            changeArrived.signal()
        }
        defer { center.removeObserver(observer) }

        guard pin() else { return .notNeeded }

        let waitStarted = clock()
        let result = changeArrived.wait(timeout: .now() + timeout)
        let waited = clock() - waitStarted
        switch result {
        case .success:
            return .settled(afterSeconds: waited)

        case .timedOut:
            return .timedOut(afterSeconds: waited)
        }
    }

    /// Whether a pin moved the unit, so that its own configuration change is
    /// on its way: the set was accepted and the unit was on another device
    /// before it. Nothing pinned and an unresolvable UID never reach a set, a
    /// refused set moved nothing, and a unit already on the device has nothing
    /// to change, so none of those starts waits.
    ///
    /// A unit whose device could not be read before the set counts as moved:
    /// waiting costs at most `timeoutSeconds`, and a change missed costs the
    /// engine it stops.
    static func pinMovedUnit(_ outcome: MicDevicePinOutcome, deviceBefore: AudioDeviceID?) -> Bool {
        guard case let .set(_, requested, status, _) = outcome else { return false }
        return status == noErr && deviceBefore != requested
    }
}
