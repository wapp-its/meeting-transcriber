import Foundation

/// The Audio Devices window's state, split out of `AppState.swift`, which sits
/// at its line cap.
extension AppState {
    /// The window's reader, sampling the levels `channelHealth` keeps and the
    /// recorder the microphone controller is attached to.
    static func makeAudioDevicesReader(
        channelHealth: ChannelHealthController, microphone: MicrophoneController,
        read: @escaping AudioDevicesWindowReader.Read,
    ) -> AudioDevicesWindowReader {
        AudioDevicesWindowReader(
            read: read,
            levels: { [channelHealth] in (channelHealth.micLevelDBFS, channelHealth.appLevelDBFS) },
            recorder: { [microphone] in microphone.attachment?.recorderProvider() },
        )
    }

    /// What the Audio Devices window shows. Reads only values the app holds
    /// and the reader's last results, so it makes no Core Audio call.
    var audioDevicesWindowState: AudioDevicesWindowState {
        AudioDevicesWindowState(AudioDevicesWindowState.Inputs(
            microphones: microphone.devices,
            defaultInputUID: microphone.defaultInputUID,
            configuredMicrophoneUID: settings.micDeviceUID,
            outputs: output.devices,
            defaultOutput: output.current,
            meetingAppHint: microphone.meetingAppHint,
            recording: audioDevicesRecording,
            status: audioDevices.status,
        ))
    }

    /// The running recording as the window shows it: the one the microphone
    /// controller is attached to, never the settings, so turning "No
    /// Microphone" on or off during it changes nothing here.
    var audioDevicesRecording: AudioDevicesWindowState.Recording? {
        guard let attachment = microphone.attachment else { return nil }
        let recordedUID = audioDevices.microphoneTrackActive ? microphone.recordedDevice?.uid : nil
        return AudioDevicesWindowState.Recording(
            capturesApp: attachment.source.capturesAppAudio,
            appName: attachment.meetingAppName,
            recordedMicrophoneUID: recordedUID,
            paused: watching.isRecordingPaused,
            micLitSegments: audioDevices.micLitSegments,
            appLitSegments: audioDevices.appLitSegments,
        )
    }
}
