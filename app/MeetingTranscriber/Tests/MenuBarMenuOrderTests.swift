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
        /// An inert line of plain text, outside any button, submenu, label
        /// and section header: the last recording's name and details lines.
        case text(String)
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

    /// A finished job added `minute` minutes into a fixed hour, so two jobs
    /// can be added in a set order: a fresh job reads the clock.
    private func makeJob(_ title: String, app: String, addedAt minute: Double) throws -> PipelineJob {
        let fresh = PipelineJob(
            meetingTitle: title, appName: app,
            mixPath: URL(fileURLWithPath: "/tmp/\(title)_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        encoded["enqueuedAt"] = Date(timeIntervalSinceReferenceDate: 800_000_000 + minute * 60).timeIntervalSinceReferenceDate
        encoded["state"] = JobState.done.rawValue
        return try JSONDecoder().decode(PipelineJob.self, from: JSONSerialization.data(withJSONObject: encoded))
    }

    /// A meeting start three days back, which the details line writes as a
    /// date rather than "Today" or "Yesterday" however close to midnight the
    /// test runs.
    private func olderDayStart() throws -> Date {
        try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: Date()))
    }

    /// The details line for a start on an older day, in the locale and time
    /// zone the menu renders with. The details-line tests pin the wording
    /// with a fixed locale; here it only has to match the menu's.
    private func olderDayDetails(app: String, start: Date) -> String {
        "\(app) · \(start.formatted(date: .abbreviated, time: .omitted)) at \(start.formatted(date: .omitted, time: .shortened))"
    }

    private func makeView(
        pipelineQueue: PipelineQueue? = nil,
        history: [TerminalJobRecord] = [],
        microphoneMenu: MicrophoneMenuState? = nil,
        outputMenu: OutputMenuState? = nil,
        actions: MenuActions = .noop,
    ) throws -> MenuBarView {
        try MenuBarView(
            status: nil,
            isWatching: false,
            pipelineQueue: pipelineQueue ?? makeIsolatedQueue(),
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
                || (try? node.menu()) != nil || (try? node.label()) != nil || isPlainText(node)
            else { return false }
            return (try? node.find(ViewType.Menu.self, relation: .parent)) == nil
                && (try? node.find(ViewType.Button.self, relation: .parent)) == nil
        }
        .map { node -> Line in
            if let section = try? node.section() { return try .heading(section.header().text().string()) }
            if (try? node.divider()) != nil { return .divider }
            if let button = try? node.button() { return try .item(button.labelView().find(ViewType.Text.self).string()) }
            if let menu = try? node.menu() { return try .item(menu.labelView().find(ViewType.Text.self).string()) }
            if let text = try? node.text() { return try .text(text.string()) }
            return try .label(node.label().title().text().string())
        }
    }

    /// A `Text` that is a line of its own: not a label's title, which the
    /// label stands for, and not a section's header, which the section
    /// stands for. The search reaches a header through the section's
    /// `header()` call.
    private func isPlainText(_ node: InspectableView<ViewType.ClassifiedView>) -> Bool {
        (try? node.text()) != nil
            && (try? node.find(ViewType.Label.self, relation: .parent)) == nil
            && !node.pathToRoot.contains("header()")
    }

    /// The lines after `line` up to the next heading or divider.
    private func lines(under line: Line, of view: MenuBarView) throws -> [Line] {
        let menu = try lines(of: view)
        let start = try XCTUnwrap(menu.firstIndex(of: line), "no \(line) in \(menu)")
        return Array(menu[(start + 1)...].prefix { line in
            if case .heading = line { return false }
            return line != .divider
        })
    }

    /// The lines of the "Needs you" group, its caption excluded.
    private func needsYouLines(of view: MenuBarView) throws -> [Line] {
        try lines(under: .label("Needs you"), of: view)
    }

    // MARK: - The whole menu

    /// The accepted mockup, top to bottom, for an idle menu with a finished
    /// recording, a job waiting for names and both device entries; and the
    /// shortcut on each item that has one, no other item carrying one.
    func testTheMenuReadsInTheMockupsOrderWithItsShortcuts() throws {
        var finished = makeJob("Retro", state: .done)
        finished.protocolPath = URL(fileURLWithPath: "/tmp/Retro.md")
        let start = try olderDayStart()
        finished.meetingStartTime = start
        let queue = try makeIsolatedQueue()
        queue.insertJobForTesting(makeJob("Unnamed", state: .speakerNamingPending))
        var actions = MenuActions.noop
        actions.nameSpeakers = {}
        let sut = try makeView(
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
            .heading("Last Recording"),
            .text("Retro"),
            .text(olderDayDetails(app: "Teams", start: start)),
            .item("Open Notes"),
            .heading("Recordings"),
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
            "Open Notes": ["o"],
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

    // MARK: - Last Recording

    /// Without a finished recording that has something to open, the section
    /// is left out with its heading, and "Recordings" holds "All Recordings…"
    /// alone, as it does at all times.
    func testTheLastRecordingSectionIsLeftOutWithoutAFinishedRecordingToOpen() throws {
        var failed = makeJob("Broken", state: .error)
        failed.transcriptPath = URL(fileURLWithPath: "/tmp/Broken.txt")
        let cases: [(name: String, history: [TerminalJobRecord])] = [
            ("no recording", []),
            ("only a failed job", [TerminalJobRecord(job: failed)]),
            ("a finished job with no file and no Notion page", [TerminalJobRecord(job: makeJob("Empty", state: .done))]),
        ]
        for testCase in cases {
            let sut = try makeView(history: testCase.history)
            let menu = try lines(of: sut)

            XCTAssertFalse(menu.contains(.heading("Last Recording")), testCase.name)
            XCTAssertFalse(menu.contains { if case .text = $0 { true } else { false } }, "\(testCase.name): \(menu)")
            XCTAssertEqual(try lines(under: .heading("Recordings"), of: sut), [.item("All Recordings…")], testCase.name)
        }
    }

    /// The name, the details line and the open item are one recording's: the
    /// one that finished last, also when another was added after it (a retry
    /// keeps when it was added), and the one the open item opens.
    func testTheLastRecordingSectionNamesTheRecordingItsOpenItemOpens() throws {
        let start = try olderDayStart()
        var retried = try makeJob("Retried", app: "Zoom", addedAt: 0)
        retried.meetingStartTime = start
        retried.transcriptPath = URL(fileURLWithPath: "/tmp/Retried.txt")
        var addedLater = try makeJob("Added later", app: "Teams", addedAt: 1)
        addedLater.protocolPath = URL(fileURLWithPath: "/tmp/Added later.md")
        var opened: [JobOpenTarget] = []
        var actions = MenuActions.noop
        actions.openLastNotes = { opened.append($0) }
        let sut = try makeView(history: [addedLater, retried].map(TerminalJobRecord.init(job:)), actions: actions)

        XCTAssertEqual(try lines(under: .heading("Last Recording"), of: sut), [
            .text("Retried"),
            .text(olderDayDetails(app: "Zoom", start: start)),
            .item("Open Notes"),
        ])
        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.openLastNotesMenuItem).button().tap()
        XCTAssertEqual(opened, [.file(URL(fileURLWithPath: "/tmp/Retried.txt"))])
    }

    // MARK: - Name Speakers inside "Needs you"

    /// "Name Speakers…" opens the group while a job waits for names, ahead of
    /// that job's own line, and counts as no row: the failed job after it keeps
    /// the index it has without the line, so its Remove still reaches it.
    func testNameSpeakersIsTheFirstLineOfNeedsYouAndShiftsNoRowIndex() throws {
        let queue = try makeIsolatedQueue()
        queue.insertJobForTesting(makeJob("Running", state: .waiting))
        queue.insertJobForTesting(makeJob("Unnamed", state: .speakerNamingPending))
        let broken = makeJob("Broken", state: .error)
        queue.insertJobForTesting(broken)
        var removed: [UUID] = []
        var actions = MenuActions.noop
        actions.nameSpeakers = {}
        actions.removeFailedJob = { removed.append($0) }
        let sut = try makeView(pipelineQueue: queue, actions: actions)

        XCTAssertEqual(
            try needsYouLines(of: sut),
            [.item("Name Speakers…"), .item("Unnamed — Speaker names needed"), .item("Broken — Failed")],
        )
        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.jobRemoveButton(2)).button().tap()
        XCTAssertEqual(removed, [broken.id])
    }

    /// Nothing waiting for names, no line: the group opens with its first job.
    func testWithoutAJobWaitingForNamesNeedsYouOpensWithItsFirstJob() throws {
        let queue = try makeIsolatedQueue()
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
