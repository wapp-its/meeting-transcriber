@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the menu bar's Output entry. Its arms are `OutputMenuStateTests`;
/// the dropdown's own behaviour is manual QA.
@MainActor
final class MenuBarOutputTests: XCTestCase {
    private func makeView(
        outputMenu: OutputMenuState,
        onSelectOutput: @escaping (String) -> Void = { _ in },
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
            onOpenProtocol: { _ in },
            onOpenLastProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
            onSelectOutput: onSelectOutput,
            outputMenu: outputMenu,
        )
    }

    func testChoosingAnOutputHandsItsUIDToTheSelection() throws {
        var selected: [String] = []
        let menu = OutputMenuState.resolve(
            devices: [
                OutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"),
                OutputDevice(uid: "HeadsetUID", name: "Headset"),
            ],
            current: OutputDevice(uid: OutputRoutingWarning.teamsLoopbackUID, name: "Microsoft Teams Audio"),
        )
        let view = makeView(outputMenu: menu) { selected.append($0) }

        let picker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.menuOutputPicker)
            .find(ViewType.Picker.self)
        try picker.select(value: "HeadsetUID")

        XCTAssertEqual(selected, ["HeadsetUID"])
    }

    func testTheTeamsRoutingShowsItsHintLine() throws {
        let menu = OutputMenuState.resolve(
            devices: [OutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")],
            current: OutputDevice(uid: OutputRoutingWarning.teamsLoopbackUID, name: "Microsoft Teams Audio"),
        )

        let body = try makeView(outputMenu: menu).inspect()

        XCTAssertNoThrow(try body.find(text: OutputRoutingWarning.menuHint))
    }

    func testNoOutputShowsTheDisabledLineAndNoPicker() throws {
        let body = try makeView(outputMenu: .resolve(devices: [], current: nil)).inspect()

        XCTAssertNoThrow(try body.find(text: "Output: None available"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.menuOutputPicker))
    }
}
