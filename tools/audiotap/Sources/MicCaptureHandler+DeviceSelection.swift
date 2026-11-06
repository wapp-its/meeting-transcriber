import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// The capture-log lines a microphone selection writes, spelled out here so
/// their wording and level are under test.
///
/// **No device UID or name, deliberately.** The lines are unconditional and
/// public, and `PersistentDiagnosticLog` writes them into the file Settings
/// exports as redacted; see `MicDevicePinOutcome.logLine`.
enum MicSelectionLogLine: Equatable {
    /// A selection launched a restart.
    case restarting
    /// A selection waits for the restart that is already running.
    case deferred
    /// A selection restart was adopted, at this hardware rate.
    case adopted(rate: Double?)

    /// Notice (os_log's `.default`), because info lines are not retained.
    var level: OSLogType {
        .default
    }

    var text: String {
        switch self {
        case .restarting:
            "Mic: microphone selection changed during the recording, restarting capture"

        case .deferred:
            "Mic: microphone selection changed while a restart is running, applying it after that restart"

        case let .adopted(rate):
            "Mic: capture restarted on the newly selected microphone (\(Int(rate ?? 0)) Hz)"
        }
    }
}

/// Moving a running microphone capture to another device: the app's
/// microphone choice changed during a recording.
///
/// **Same path as a device change.** A selection goes through
/// `handleDeviceChange`, so it gets a fresh session, the arbiter's single
/// attempt, generation and deadline, the shared retry budget and the gap
/// written as silence, and on a capture that stalled for lack of audio
/// (`+Progress`) it is a revival: `mayRevive` decides whether it may, and
/// `noteRevival` bridges the stall, exactly as a change of the input. It is
/// charged to none of the progress watchdog's budgets, and to the arbiter it
/// is a plain `deviceChanged` event: its transition table knows nothing of
/// selections.
///
/// **Deferred, never dropped.** The arbiter launches an attempt only while
/// capturing normally and ignores the event during an outstanding attempt or
/// a backoff. For a device change that is right, since the retry re-resolves
/// the target, but a selection made while an attempt aimed at the previous
/// device is in flight would be lost. So it is marked pending: a retry
/// launched meanwhile aims at exactly what the new choice resolves to, and the
/// next adoption, if it landed elsewhere, claims one more restart. Only the
/// latest choice is stored, so the last of several selections wins.
///
/// **Sealed is final.** After a stop or a give-up nothing is restarted or
/// marked; the choice applies from the next recording.
///
/// Main queue throughout, like `start` and `stop`.
extension MicCaptureHandler {
    /// Record from the device with `uid` from now on, nil meaning the system
    /// default. A device that is not connected records the system default,
    /// as a device change does. Choosing the current device does nothing.
    public func selectDevice(uid: String?) {
        guard uid != selectedDeviceUID else { return }
        selectedDeviceUID = uid
        if launchSelectionRestart() { return }
        guard restartOutstanding else { return }
        selectionPending = true
        logSelection(.deferred)
    }

    /// Main queue, from every adoption, once the adopted session is published:
    /// apply a selection made while that restart ran, unless the restart
    /// already landed where the selection points.
    func applyPendingSelection(adoptedDeviceUID: String?) {
        guard selectionPending else { return }
        selectionPending = false
        guard adoptedDeviceUID != currentRestartTarget() else { return }
        launchSelectionRestart()
    }

    /// The capture stopped or gave up: nothing is recorded any more and no
    /// pending selection will be applied. Main queue.
    func endDeviceSelection() {
        activeInputDevice = nil
        selectionPending = false
        selectionRestartOutstanding = false
    }

    /// Production device lookup for `isDevicePresent`: plain CoreAudio, no
    /// engine, so it cannot reach the calls that wedge.
    static func isDevicePresentOnSystem(_ uid: String) -> Bool {
        deviceIDForUID(uid) != kAudioObjectUnknown
    }

    /// Ask for a restart the way a device change does, and log the line once
    /// it was granted and before it is launched, ahead of the attempt's own
    /// lines.
    @discardableResult
    private func launchSelectionRestart() -> Bool {
        handleDeviceChange {
            logSelection(.restarting)
            selectionRestartOutstanding = true
        }
    }

    /// Whether the arbiter declined because a restart is outstanding (an
    /// attempt in flight, its backoff or its commit), as opposed to a capture
    /// that never started, is sealed, or stalled and may not be revived.
    private var restartOutstanding: Bool {
        arbiter.withLock { state in
            switch state.phase {
            case .attemptInFlight, .backingOff, .committing: true
            case .idle, .capturing, .stalled, .gaveUp, .stopped: false
            }
        }
    }

    func logSelection(_ line: MicSelectionLogLine) {
        logger.log(level: line.level, "\(line.text, privacy: .public)")
    }
}
