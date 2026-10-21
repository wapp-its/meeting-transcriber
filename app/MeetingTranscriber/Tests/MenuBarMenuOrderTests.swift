@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The order of the menu's own lines, read top to bottom as the menu shows
/// them. Which arms a line has is tested where its decision lives; here the
/// place of each line is the behaviour.
@MainActor
final class MenuBarMenuOrderTests: XCTestCase {
    /// One line of the menu as far as the order is concerned. What sits inside
    /// a submenu or a button belongs to that line.
    private enum Line: Equatable {
        /// A section's header, a heading line rather than an item.
        case heading(String)
        /// An inert line: the status, a job group's caption.
        case label(String)
        /// A button or a submenu, by its title.
        case item(String)
        case divider
    }

    private func makeJob(_ title: String, state: JobState) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/\(title)_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = state
        return job
    }

    private func makeView(
        pipelineQueue: PipelineQueue = PipelineQueue(),
        history: [TerminalJobRecord] = [],
        microphoneMenu: MicrophoneMenuState? = nil,
        outputMenu: OutputMenuState? = nil,
        actions: MenuActions = .noop,
    ) -> MenuBarView {
        MenuBarView(
            status: nil,
            isWatching: false,
            pipelineQueue: pipelineQueue,
            updateChecker: nil,
            history: history,
            noMic: false,
            manualRecordingPendingOrActive: false,
            microphoneMenu: microphoneMenu,
            outputMenu: outputMenu,
            actions: actions,
        )
    }

    private static let microphone = MicrophoneMenuState.resolve(
        noMic: false, selectedUID: "", devices: [MicrophoneDevice(uid: "HeadsetUID", name: "Headset")],
        defaultInputName: "MacBook Pro Microphone", recordedDevice: nil,
    )
    private static let output = OutputMenuState.resolve(
        devices: [OutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")],
        current: OutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"),
    )

    /// The menu's own lines in document order (`findAll` searches depth-first,
    /// top to bottom as written). A section is matched before its content and
    /// stands for its header, which the search reaches only after the content.
    private func lines(of view: MenuBarView) throws -> [Line] {
        try view.inspect().findAll { node in
            guard (try? node.section()) != nil || (try? node.divider()) != nil || (try? node.button()) != nil
                || (try? node.menu()) != nil || (try? node.label()) != nil
            else { return false }
            return (try? node.find(ViewType.Menu.self, relation: .parent)) == nil
                && (try? node.find(ViewType.Button.self, relation: .parent)) == nil
        }
        .map { node -> Line in
            if let section = try? node.section() { return try .heading(section.header().text().string()) }
            if (try? node.divider()) != nil { return .divider }
            if let button = try? node.button() { return try .item(button.labelView().find(ViewType.Text.self).string()) }
            if let menu = try? node.menu() { return try .item(menu.labelView().find(ViewType.Text.self).string()) }
            return try .label(node.label().title().text().string())
        }
    }

    /// The lines of the "Needs you" group, its caption excluded.
    private func needsYouLines(of view: MenuBarView) throws -> [Line] {
        let menu = try lines(of: view)
        let caption = try XCTUnwrap(menu.firstIndex(of: .label("Needs you")))
        return Array(menu[(caption + 1)...].prefix { line in
            if case .heading = line { return false }
            return line != .divider
        })
    }

    // MARK: - The whole menu

    /// The accepted mockup, top to bottom, for an idle menu with a finished
    /// recording, a job waiting for names and both device entries; and the
    /// shortcut on each item that has one, no other item carrying one.
    func testTheMenuReadsInTheMockupsOrderWithItsShortcuts() throws {
        var finished = makeJob("Retro", state: .done)
        finished.protocolPath = URL(fileURLWithPath: "/tmp/Retro.md")
        let queue = PipelineQueue()
        queue.insertJobForTesting(makeJob("Unnamed", state: .speakerNamingPending))
        var actions = MenuActions.noop
        actions.nameSpeakers = {}
        let sut = makeView(
            pipelineQueue: queue, history: [TerminalJobRecord(job: finished)],
            microphoneMenu: Self.microphone, outputMenu: Self.output, actions: actions,
        )

        XCTAssertEqual(try lines(of: sut), [
            .label("Idle"),
            .item("Start Watching for Meetings"),
            .divider,
            .heading("Record & Import"),
            .item("Record Microphone Only"),
            .item("Record with Options…"),
            .item("Import Audio/Video Files…"),
            .heading("Audio Devices"),
            .item(Self.microphone.title),
            .item(Self.output.title),
            .divider,
            .label("Needs you"),
            .item("Name Speakers…"),
            .item("Unnamed — Speaker names needed"),
            .heading("Recordings"),
            .item("Open Last Protocol"),
            .item("All Recordings…"),
            .divider,
            .item("Settings..."),
            .divider,
            .item("Quit"),
        ])
        XCTAssertEqual(try shortcutKeys(of: sut), [
            "Start Watching for Meetings": ["s"],
            "Record Microphone Only": ["m"],
            "Record with Options…": ["r"],
            "Import Audio/Video Files…": ["p"],
            "Name Speakers…": ["n"],
            "Open Last Protocol": ["o"],
            "All Recordings…": ["t"],
            "Settings...": [","],
            "Quit": ["q"],
        ])
    }

    /// The heading goes with its entries: one entry is enough to show it.
    func testTheAudioDevicesHeadingIsLeftOutWithoutADeviceEntry() throws {
        let cases: [(name: String, microphone: MicrophoneMenuState?, output: OutputMenuState?, shown: Bool)] = [
            ("both", Self.microphone, Self.output, true),
            ("microphone only", Self.microphone, nil, true),
            ("output only", nil, Self.output, true),
            ("neither", nil, nil, false),
        ]
        for testCase in cases {
            let menu = try lines(of: makeView(microphoneMenu: testCase.microphone, outputMenu: testCase.output))

            XCTAssertEqual(menu.contains(.heading("Audio Devices")), testCase.shown, testCase.name)
            XCTAssertTrue(menu.contains(.heading("Record & Import")), testCase.name)
        }
    }

    // MARK: - Name Speakers inside "Needs you"

    /// "Name Speakers…" opens the group while a job waits for names, ahead of
    /// that job's own line, and counts as no row: the failed job after it keeps
    /// the index it has without the line, so its Remove still reaches it.
    func testNameSpeakersIsTheFirstLineOfNeedsYouAndShiftsNoRowIndex() throws {
        let queue = PipelineQueue()
        queue.insertJobForTesting(makeJob("Running", state: .waiting))
        queue.insertJobForTesting(makeJob("Unnamed", state: .speakerNamingPending))
        let broken = makeJob("Broken", state: .error)
        queue.insertJobForTesting(broken)
        var removed: [UUID] = []
        var actions = MenuActions.noop
        actions.nameSpeakers = {}
        actions.removeFailedJob = { removed.append($0) }
        let sut = makeView(pipelineQueue: queue, actions: actions)

        XCTAssertEqual(
            try needsYouLines(of: sut),
            [.item("Name Speakers…"), .item("Unnamed — Speaker names needed"), .item("Broken — Failed")],
        )
        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.jobRemoveButton(2)).button().tap()
        XCTAssertEqual(removed, [broken.id])
    }

    /// Nothing waiting for names, no line: the group opens with its first job.
    func testWithoutAJobWaitingForNamesNeedsYouOpensWithItsFirstJob() throws {
        let queue = PipelineQueue()
        queue.insertJobForTesting(makeJob("Broken", state: .error))

        XCTAssertEqual(try needsYouLines(of: makeView(pipelineQueue: queue)), [.item("Broken — Failed")])
    }

    // MARK: - Shortcuts

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
