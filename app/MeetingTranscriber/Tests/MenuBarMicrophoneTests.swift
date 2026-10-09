@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the menu bar's Microphone entry. Its arms are
/// `MicrophoneMenuStateTests`; the dropdown's own behaviour is manual QA.
@MainActor
final class MenuBarMicrophoneTests: XCTestCase {
    private func makeView(
        microphoneMenu: MicrophoneMenuState,
        onSelectMicrophone: @escaping (String) -> Void = { _ in },
    ) -> MenuBarView {
        MenuBarView(
            status: nil,
            isWatching: false,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
            onSelectMicrophone: onSelectMicrophone,
            microphoneMenu: microphoneMenu,
        )
    }

    private func menuState(noMic: Bool) -> MicrophoneMenuState {
        .resolve(
            noMic: noMic,
            selectedUID: "",
            devices: [MicrophoneDevice(uid: "HeadsetUID", name: "Headset")],
            defaultInputName: "MacBook Pro Microphone",
            recordedDevice: nil,
        )
    }

    func testChoosingAMicrophoneHandsItsUIDToTheSelection() throws {
        var selected: [String] = []
        let view = makeView(microphoneMenu: menuState(noMic: false)) { selected.append($0) }

        let picker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.menuMicrophonePicker)
            .find(ViewType.Picker.self)
        try picker.select(value: "HeadsetUID")

        XCTAssertEqual(selected, ["HeadsetUID"])
    }

    func testNoMicShowsTheOffLineAndNoPicker() throws {
        let body = try makeView(microphoneMenu: menuState(noMic: true)).inspect()

        XCTAssertNoThrow(try body.find(text: "Microphone: Off (app audio only)"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.menuMicrophonePicker))
    }
}
