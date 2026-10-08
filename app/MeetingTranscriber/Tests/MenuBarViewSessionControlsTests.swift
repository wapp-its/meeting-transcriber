@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The control for the current state sits directly under the menu's status
/// line, with no divider in between. The order is the behaviour here, so it is
/// read in document order rather than by presence.
@MainActor
final class MenuBarViewSessionControlsTests: XCTestCase {
    /// One line of the menu as far as the order is concerned.
    private enum Line: Equatable {
        case status
        case divider
        case button(String)
    }

    /// Counts the two callbacks the controls under test call.
    private final class Taps {
        var stops = 0
        var toggles = 0
    }

    private static let stopRecording = "Stop Recording"
    private static let stopWatching = "Stop Watching for Meetings"
    private static let startWatching = "Start Watching for Meetings"

    /// `recording` sets the stop closure, as the menu scene does for every running recording.
    private func makeView(
        state: TranscriberState,
        isWatching: Bool,
        recording: Bool = false,
        meeting: MeetingInfo? = nil,
        error: String? = nil,
        taps: Taps = Taps(),
    ) -> MenuBarView {
        MenuBarView(
            status: TranscriberStatus(
                version: 1,
                timestamp: "2024-01-01T00:00:00",
                state: state,
                detail: "",
                meeting: meeting,
                protocolPath: nil,
                error: error,
                audioPath: nil,
                pid: nil,
            ),
            isWatching: isWatching,
            pipelineQueue: PipelineQueue(),
            updateChecker: nil,
            onStartStop: { taps.toggles += 1 },
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: false,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: recording ? { taps.stops += 1 } : nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
    }

    /// The status line, the dividers and the buttons, in document order
    /// (`findAll` searches depth-first, top to bottom as written).
    private func lines(of view: MenuBarView, state: TranscriberState) throws -> [Line] {
        let nodes = try view.inspect().findAll { node in
            (try? node.divider()) != nil || (try? node.button()) != nil
                || (try? node.text().string()) == state.label
        }
        return try nodes.map { node in
            if (try? node.divider()) != nil { return .divider }
            if let button = try? node.button() { return try .button(button.find(ViewType.Text.self).string()) }
            return .status
        }
    }

    // MARK: - The line under the status

    func testWhileRecordingStopRecordingIsTheFirstLineUnderTheStatus() throws {
        let taps = Taps()
        let sut = makeView(
            state: .recording,
            isWatching: true,
            recording: true,
            meeting: MeetingInfo(app: "Microsoft Teams", title: "Standup", pid: 42),
            taps: taps,
        )

        XCTAssertEqual(try Array(lines(of: sut, state: .recording).prefix(2)), [.status, .button(Self.stopRecording)])

        try XCTUnwrap(sut.inspect().findAll(ViewType.Button.self).first).tap()
        XCTAssertEqual(taps.stops, 1)
        XCTAssertEqual(taps.toggles, 0)
    }

    func testWithoutARecordingTheWatchToggleIsTheFirstLineUnderTheStatus() throws {
        let cases: [(state: TranscriberState, isWatching: Bool, error: String?, title: String)] = [
            (.watching, true, nil, Self.stopWatching),
            (.idle, false, nil, Self.startWatching),
            (.error, false, "Capture failed", Self.startWatching),
        ]
        for testCase in cases {
            let taps = Taps()
            let sut = makeView(state: testCase.state, isWatching: testCase.isWatching, error: testCase.error, taps: taps)

            XCTAssertEqual(
                try Array(lines(of: sut, state: testCase.state).prefix(2)),
                [.status, .button(testCase.title)],
                "\(testCase.state)",
            )

            try XCTUnwrap(sut.inspect().findAll(ViewType.Button.self).first).tap()
            XCTAssertEqual(taps.toggles, 1, "\(testCase.state)")
        }
    }

    // MARK: - Watching stays reachable while recording

    func testWhileRecordingStopWatchingStaysBelowTheFirstDivider() throws {
        let taps = Taps()
        let sut = makeView(state: .recording, isWatching: true, recording: true, taps: taps)

        let menu = try lines(of: sut, state: .recording)
        let toggle = try XCTUnwrap(menu.firstIndex(of: .button(Self.stopWatching)))
        let firstDivider = try XCTUnwrap(menu.firstIndex(of: .divider))
        XCTAssertGreaterThan(toggle, firstDivider)

        try sut.inspect().find(button: Self.stopWatching).tap()
        XCTAssertEqual(taps.toggles, 1)
        XCTAssertEqual(taps.stops, 0)
    }

    func testTheWatchToggleAppearsExactlyOnceInEveryState() throws {
        let cases: [(name: String, state: TranscriberState, isWatching: Bool, recording: Bool)] = [
            ("idle", .idle, false, false),
            ("watching", .watching, true, false),
            ("error", .error, false, false),
            ("detected meeting", .recording, true, true),
            ("manual recording, not watching", .recording, false, true),
            ("recording without a stop", .recording, true, false),
        ]
        for testCase in cases {
            let sut = makeView(state: testCase.state, isWatching: testCase.isWatching, recording: testCase.recording)
            let menu = try lines(of: sut, state: testCase.state)

            let toggles = menu.filter { $0 == .button(Self.stopWatching) || $0 == .button(Self.startWatching) }
            XCTAssertEqual(toggles.count, 1, testCase.name)
            XCTAssertEqual(menu.filter { $0 == .button(Self.stopRecording) }.count, testCase.recording ? 1 : 0, testCase.name)
        }
    }

    // MARK: - Keyboard shortcuts

    func testKeyboardShortcutsAreUnchanged() throws {
        let recording = try shortcutKeys(of: makeView(state: .recording, isWatching: true, recording: true))
        XCTAssertEqual(recording[Self.stopRecording], ["."])
        XCTAssertEqual(recording[Self.stopWatching], ["s"])

        let idle = try shortcutKeys(of: makeView(state: .idle, isWatching: false))
        XCTAssertEqual(idle[Self.startWatching], ["s"])
    }

    /// ViewInspector reads no `.keyboardShortcut`, so this walks the view value
    /// itself: each modifier carrying a `KeyEquivalent`, keyed by the title of
    /// the view it modifies.
    private func shortcutKeys(of view: MenuBarView) throws -> [String: Set<Character>] {
        var keys: [String: Set<Character>] = [:]
        try collectShortcutKeys(in: view.body, into: &keys)
        return keys
    }

    private func collectShortcutKeys(in value: Any, into keys: inout [String: Set<Character>]) throws {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return }
        if String(describing: type(of: value)).hasPrefix("ModifiedContent<"),
           let content = mirror.descendant("content") as? any View,
           let modifier = mirror.descendant("modifier") {
            let found = keyEquivalents(in: modifier)
            if !found.isEmpty {
                try keys[firstText(of: content), default: []].formUnion(found.map(\.character))
            }
        }
        for child in mirror.children {
            try collectShortcutKeys(in: child.value, into: &keys)
        }
    }

    private func keyEquivalents(in value: Any) -> [KeyEquivalent] {
        if let key = value as? KeyEquivalent { return [key] }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return [] }
        return mirror.children.flatMap { keyEquivalents(in: $0.value) }
    }

    private func firstText(of view: some View) throws -> String {
        try view.inspect().find(ViewType.Text.self).string()
    }
}
