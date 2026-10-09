import AudioTapLib
import Foundation

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(source: RecordingSource, micDeviceUID: String?, debugLogging: Bool) throws
    func stop() throws -> RecordingResult

    /// Instantaneous app-audio level in dBFS. -120 when no capture session is
    /// active or the tap stopped delivering buffers in the last 0.5 s.
    /// Drives the menu-bar asymmetric-silence indicator. Default: -120
    /// (mocks that don't simulate audio levels stay silent).
    var appLevelDBFS: Double { get }

    /// Instantaneous mic level in dBFS, with the same semantics as
    /// `appLevelDBFS`.
    var micLevelDBFS: Double { get }

    /// True once a channel's capture was abandoned for good (issue #588),
    /// whether a restart attempt never returned or the retry budget ran out.
    /// The level alone cannot say this: a channel that fell silent may come
    /// back, one that gave up will not.
    /// Default false so mocks that do not simulate capture failures stay quiet.
    var appCaptureGaveUp: Bool { get }
    var micCaptureGaveUp: Bool { get }

    /// True once the opt-in silent-track watchdog stopped rebuilding the app
    /// capture because its rebuilds did not restore signal (issue #672). Not a
    /// give-up: the channel still captures. Default false.
    var appSilentTrackWatchdogGaveUp: Bool { get }

    /// How long each channel has gone without a buffer, and without one
    /// carrying signal. This is what says whether a channel is broken;
    /// `appLevelDBFS` / `micLevelDBFS` only say how loud it is, and report the
    /// same -120 for a muted device, a dead tap and a channel that was never
    /// opened. Defaults describe a channel delivering normally, so a double
    /// that does not simulate capture never looks broken.
    var appSignalAges: ChannelSignalAges { get }
    var micSignalAges: ChannelSignalAges { get }

    /// The microphone the running capture reports it records from, nil
    /// without a microphone capture. Default nil.
    var micInputDevice: MicInputDevice? { get }

    /// Whether a microphone is being captured right now: one was requested,
    /// it started and it has not given up. Default false.
    var microphoneTrackActive: Bool { get }

    /// The process ids this recording tapped when it started: empty for a
    /// microphone-only recording and outside a recording, and without the
    /// helper processes an app starts later. Default empty.
    var tappedPIDs: [pid_t] { get }

    /// Move the running microphone capture to the device with `deviceUID`,
    /// nil meaning the system default. Does nothing without a microphone
    /// capture; the next recording reads the choice when it starts. Default:
    /// does nothing.
    func selectMicrophone(deviceUID: String?)
}

extension ChannelSignalAges {
    /// A channel that delivered a buffer carrying signal just now. What a
    /// provider reports when it does not simulate capture at all, so a double
    /// has to say explicitly that a channel is broken before it can be
    /// reported as such.
    static let deliveringSignalNow = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 0)
}

extension RecordingProvider {
    var appLevelDBFS: Double {
        -120
    }

    var micLevelDBFS: Double {
        -120
    }

    var appCaptureGaveUp: Bool {
        false
    }

    var micCaptureGaveUp: Bool {
        false
    }

    var appSilentTrackWatchdogGaveUp: Bool {
        false
    }

    var appSignalAges: ChannelSignalAges {
        .deliveringSignalNow
    }

    var micSignalAges: ChannelSignalAges {
        .deliveringSignalNow
    }

    var micInputDevice: MicInputDevice? {
        nil
    }

    var microphoneTrackActive: Bool {
        false
    }

    var tappedPIDs: [pid_t] {
        []
    }

    func selectMicrophone(deviceUID _: String?) {}
}
