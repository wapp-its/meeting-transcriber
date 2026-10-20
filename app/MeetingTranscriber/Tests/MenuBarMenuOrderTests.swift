@testable import MeetingTranscriber
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

    private func makeView(pipelineQueue: PipelineQueue, actions: MenuActions = .noop) -> MenuBarView {
        MenuBarView(
            status: nil,
            isWatching: false,
            pipelineQueue: pipelineQueue,
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            actions: actions,
        )
    }

    /// The menu's own lines in document order (`findAll` searches depth-first,
    /// top to bottom as written).
    private func lines(of view: MenuBarView) throws -> [Line] {
        try view.inspect().findAll { node in
            guard (try? node.divider()) != nil || (try? node.button()) != nil
                || (try? node.menu()) != nil || (try? node.label()) != nil
            else { return false }
            return (try? node.find(ViewType.Menu.self, relation: .parent)) == nil
                && (try? node.find(ViewType.Button.self, relation: .parent)) == nil
        }
        .map { node -> Line in
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
        return Array(menu[(caption + 1)...].prefix { $0 != .divider })
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
}
