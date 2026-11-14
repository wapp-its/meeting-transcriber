import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// What `AppState` hands the Audio Devices window about the running
/// recording: the recording's own report, never the settings.
@MainActor
final class AppStateAudioDevicesTests: XCTestCase {
    /// An app whose window reads no hardware.
    private func makeState() throws -> AppState {
        let noHardware: AudioDevicesWindowReader.Read = { _ in
            AudioDeviceStatusReading(running: [:], selfRunningInput: nil, meetingApp: nil)
        }
        return try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(), settings: makeIsolatedSettings(),
            audioDeviceRead: noHardware,
        )
    }

    private func attach(_ source: RecordingSource, recorder: MockRecorder, to state: AppState) {
        state.microphone.recordingStarted(source: source, meetingAppName: "Teams") { recorder }
        state.microphone.tick()
        state.audioDevices.windowOpened()
    }

    private func detach(_ state: AppState) {
        state.audioDevices.windowClosed()
        state.microphone.recordingStopped()
    }

    /// "No Microphone" applies at the next recording start, so turning it on
    /// or off during a microphone-only and during an app-and-microphone
    /// recording changes neither that recording's marks nor its bars.
    func testNoMicrophoneTurnedOnOrOffDuringARecordingChangesNothingInTheWindow() throws {
        let state = try makeState()
        let recorder = MockRecorder()
        recorder.micInputDevice = MicInputDevice(uid: "HeadsetUID", name: "USB Headset")
        recorder.microphoneTrackActive = true
        let cases: [(source: RecordingSource, meetingAudio: Bool)] = [(.micOnly, false), (.appAndMic(pid: 4242), true)]
        for testCase in cases {
            attach(testCase.source, recorder: recorder, to: state)
            let before = state.audioDevicesWindowState
            XCTAssertEqual(state.audioDevicesRecording?.recordedMicrophoneUID, "HeadsetUID", "\(testCase.source)")
            XCTAssertEqual(before.meetingAudio != nil, testCase.meetingAudio, "\(testCase.source)")

            for noMic in [true, false] {
                state.settings.noMic = noMic
                XCTAssertEqual(state.audioDevicesWindowState, before, "\(testCase.source), No Microphone \(noMic)")
                XCTAssertEqual(state.audioDevicesRecording?.recordedMicrophoneUID, "HeadsetUID", "\(testCase.source)")
            }
            detach(state)
        }
    }

    /// A microphone track that gave up records nothing more, although the
    /// capture still names its device: no row is marked recorded and no
    /// microphone bar shows.
    func testAMicrophoneTrackThatGaveUpIsNoLongerTheRecordedMicrophone() throws {
        let state = try makeState()
        let recorder = MockRecorder()
        recorder.micInputDevice = MicInputDevice(uid: "HeadsetUID", name: "USB Headset")
        recorder.microphoneTrackActive = true
        attach(.appAndMic(pid: 4242), recorder: recorder, to: state)
        defer { detach(state) }
        XCTAssertEqual(state.audioDevicesRecording?.recordedMicrophoneUID, "HeadsetUID")

        recorder.microphoneTrackActive = false
        state.audioDevices.tick()

        XCTAssertEqual(state.microphone.recordedDevice?.uid, "HeadsetUID")
        XCTAssertNil(state.audioDevicesRecording?.recordedMicrophoneUID)
        XCTAssertNotNil(state.audioDevicesWindowState.meetingAudio)
    }

    /// The bars show the levels the channel-health tick last stored for the
    /// two recorded tracks.
    func testTheBarsShowTheRecordedTracksLevels() throws {
        let state = try makeState()
        let recorder = MockRecorder()
        recorder.microphoneTrackActive = true
        recorder.micLevelDBFS = -30
        recorder.appLevelDBFS = 0
        attach(.appAndMic(pid: 4242), recorder: recorder, to: state)
        defer { detach(state) }

        state.channelHealth.applyTick(recorder: recorder, now: Date())
        state.audioDevices.tick()

        XCTAssertEqual(state.audioDevicesRecording?.micLitSegments, 6)
        XCTAssertEqual(state.audioDevicesRecording?.appLitSegments, 12)
    }

    /// The window lists the devices the two menu entries offer, marks the
    /// default input, and lists a configured microphone that is not
    /// connected; outside a recording no row is recorded or used by an app.
    func testTheWindowListsTheDevicesTheMenuEntriesOffer() throws {
        let state = try makeState()
        state.settings.micDeviceUID = "NotConnectedTestUID"

        let window = state.audioDevicesWindowState
        let microphones = state.microphone.devices
        XCTAssertEqual(window.microphones.rows.count, microphones.count + 1)
        XCTAssertEqual(window.microphones.rows.last?.name, "Selected microphone")
        XCTAssertEqual(window.microphones.rows.last?.marks, [.notConnected])
        let outputs = OutputMenuState.resolve(devices: state.output.devices, current: state.output.current).items
        XCTAssertEqual(window.outputs.rows.count, outputs.count)
        if let index = microphones.firstIndex(where: { $0.uid == state.microphone.defaultInputUID }) {
            XCTAssertTrue(window.microphones.rows[index].marks.contains(.systemDefault))
        }
        XCTAssertFalse(window.rows.contains { $0.marks.contains(.recording) || $0.marks.contains(.meetingApp) })
    }
}
