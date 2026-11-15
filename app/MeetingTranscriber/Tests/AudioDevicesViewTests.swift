@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The Audio Devices window renders its state value: the groups, rows, marks,
/// level column and footer, and no control anywhere.
@MainActor
final class AudioDevicesViewTests: XCTestCase {
    private typealias State = AudioDevicesWindowState

    private func makeState(recording: State.Recording?, outputs: [OutputDevice]) -> State {
        let headset = MicrophoneDevice(uid: "HeadsetUID", name: "USB Headset")
        return State(State.Inputs(
            microphones: [headset], defaultInputUID: "HeadsetUID", configuredMicrophoneUID: "",
            outputs: outputs, defaultOutput: outputs.first, meetingAppHint: "Teams uses USB Headset",
            recording: recording,
            status: AudioDeviceStatus(running: ["HeadsetUID": true], meetingApp: nil),
        ))
    }

    private func texts(of view: AudioDevicesView) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    func testTheWindowRendersItsGroupsRowsMarksAndFooterWithNoControl() throws {
        let recording = State.Recording(
            capturesApp: true, appName: "Teams", recordedMicrophoneUID: "HeadsetUID", paused: false,
            micLitSegments: 7, appLitSegments: 4,
        )
        let state = makeState(recording: recording, outputs: [])
        let sut = AudioDevicesView(state: state)

        let shown = try texts(of: sut)
        for expected in [
            "Microphones", "USB Headset", "Recording", "In use", "Default", "Teams uses USB Headset",
            "Outputs", "None found", "Meeting audio", "Teams", state.footer,
        ] {
            XCTAssertTrue(shown.contains(expected), "\(expected) missing from \(shown)")
        }
        let bars = try sut.inspect().findAll(AudioDeviceLevelBar.self).map { try $0.actualView().litSegments }
        XCTAssertEqual(bars, [7, 4])
        XCTAssertTrue(try sut.inspect().findAll(ViewType.Button.self).isEmpty)
        XCTAssertTrue(try sut.inspect().findAll(ViewType.Toggle.self).isEmpty)
        XCTAssertTrue(try sut.inspect().findAll(ViewType.Picker.self).isEmpty)
        XCTAssertTrue(try sut.inspect().findAll(ViewType.Menu.self).isEmpty)
    }

    /// The level column shows "no level" for rows without a bar during a
    /// recording, and is left out with the bars outside one.
    func testTheLevelColumnShowsOnlyDuringARecording() throws {
        let speakers = OutputDevice(uid: "SpeakerUID", name: "MacBook Pro Speakers")
        let recording = State.Recording(
            capturesApp: false, appName: nil, recordedMicrophoneUID: "HeadsetUID", paused: false,
            micLitSegments: 3, appLitSegments: 0,
        )

        let during = AudioDevicesView(state: makeState(recording: recording, outputs: [speakers]))
        XCTAssertEqual(try texts(of: during).filter { $0 == State.noLevel }.count, 1)
        XCTAssertEqual(try during.inspect().findAll(AudioDeviceLevelBar.self).count, 1)
        XCTAssertFalse(try texts(of: during).contains("Meeting audio"))

        let idle = AudioDevicesView(state: makeState(recording: nil, outputs: [speakers]))
        XCTAssertFalse(try texts(of: idle).contains(State.noLevel))
        XCTAssertTrue(try idle.inspect().findAll(AudioDeviceLevelBar.self).isEmpty)
        XCTAssertTrue(try texts(of: idle).contains(State.idleFooter))
    }

    /// The window's appearing and disappearing start and stop its reader.
    func testTheWindowContentRunsTheReaderOnlyWhileItIsShown() throws {
        let noHardware: AudioDevicesWindowReader.Read = { _ in
            AudioDeviceStatusReading(running: [:], selfRunningInput: nil, meetingApp: nil)
        }
        let appState = try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(), settings: makeIsolatedSettings(),
            audioDeviceRead: noHardware,
        )
        let sut = AudioDevicesWindowContent(appState: appState)
        defer { appState.audioDevices.windowClosed() }

        try sut.inspect().find(AudioDevicesView.self).callOnAppear()
        XCTAssertTrue(appState.audioDevices.isOpen)
        try sut.inspect().find(AudioDevicesView.self).callOnDisappear()
        XCTAssertFalse(appState.audioDevices.isOpen)
    }
}
