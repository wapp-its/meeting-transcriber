@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The All Recordings window's wiring: what each control hands to the action
/// or binding it was given, which rows a query leaves, and what a row says. The
/// list itself (merge, order, search rule) is covered by `TranscriptionListTests`,
/// and which buttons and items a row gets by `RecordingRowActionsTests`.
@MainActor
final class TranscriptionsViewTests: XCTestCase {
    private typealias FilesOnDisk = RecordingRowActions.FilesOnDisk

    /// What the search field's binding writes to, so a test reads the typed
    /// text without reaching into SwiftUI's state.
    private final class QueryBox {
        var text = ""
    }

    private func makeView(
        _ entries: [TranscriptionEntry],
        query: String = "",
        queryBox: QueryBox? = nil,
        actions: AllRecordingsActions = .noop,
    ) -> TranscriptionsView {
        let box = queryBox ?? QueryBox()
        box.text = query
        return TranscriptionsView(
            entries: entries,
            query: Binding(get: { box.text }, set: { box.text = $0 }),
            actions: actions,
        )
    }

    /// Every action and its argument, in the order they were called.
    private func recording(into calls: @escaping (String) -> Void, base: AllRecordingsActions = .noop) -> AllRecordingsActions {
        var actions = base
        actions.openProtocol = { calls("openProtocol \($0.path)"); return true }
        actions.openTranscript = { calls("openTranscript \($0.path)"); return true }
        actions.reveal = { calls("reveal \($0.path)"); return true }
        actions.regenerate = { calls("regenerate \($0?.id.uuidString ?? "none")") }
        actions.retry = { calls("retry \($0)") }
        actions.remove = { calls("remove \($0)") }
        actions.dismiss = { calls("dismiss \($0)") }
        actions.cancel = { calls("cancel \($0)") }
        actions.nameSpeakers = { calls("nameSpeakers \($0)") }
        actions.openProtocolsFolder = { calls("openProtocolsFolder") }
        return actions
    }

    /// The files the entry recorded are all on disk, the transcript readable.
    private static func recordedFilesOnDisk(_ entry: TranscriptionEntry) -> FilesOnDisk {
        FilesOnDisk(
            protocolExists: entry.protocolURL != nil,
            transcriptExists: entry.transcriptURL != nil,
            transcriptSource: entry.transcriptURL != nil ? .transcriptFile : .none,
        )
    }

    /// A job as the queue holds it.
    private func entry(
        _ title: String,
        state: JobState = .done,
        participants: [String] = [],
        error: String? = nil,
        protocolPath: String? = nil,
        transcriptPath: String? = nil,
    ) -> TranscriptionEntry {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/\(title)_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
            participants: participants,
        )
        job.state = state
        job.error = error
        job.protocolPath = protocolPath.map { URL(fileURLWithPath: $0) }
        job.transcriptPath = transcriptPath.map { URL(fileURLWithPath: $0) }
        return TranscriptionEntry(job: job, finishOrder: nil)
    }

    private func button(_ identifier: String, in view: TranscriptionsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: identifier).button()
    }

    // MARK: - Search

    func testTypingInTheSearchFieldWritesTheQuery() throws {
        let box = QueryBox()
        let sut = makeView([entry("Retro")], queryBox: box)

        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.transcriptionsSearchField)
            .find(ViewType.TextField.self)
            .setInput("retro")

        XCTAssertEqual(box.text, "retro")
    }

    /// A query leaves only the rows it matches, by title or by participant;
    /// a query matching nothing and an empty history each say so.
    func testAQueryShowsOnlyMatchingRowsAndAnEmptyListSaysWhy() throws {
        let entries = [entry("Retro"), entry("Standup", participants: ["Zoë"]), entry("Planning")]

        let byParticipant = try makeView(entries, query: "zoe").inspect()
        XCTAssertNoThrow(try byParticipant.find(text: "Standup"))
        XCTAssertThrowsError(try byParticipant.find(text: "Retro"))
        XCTAssertThrowsError(try byParticipant.find(text: "Planning"))

        let noMatch = try makeView(entries, query: "budget").inspect()
        XCTAssertNoThrow(try noMatch.find(text: "No transcriptions match"))
        XCTAssertThrowsError(try noMatch.find(text: "Retro"))

        let empty = try makeView([]).inspect()
        XCTAssertNoThrow(try empty.find(text: "No transcriptions yet"))
        XCTAssertThrowsError(try empty.find(text: "No transcriptions match"))
    }

    // MARK: - Toolbar

    /// "Open Protocols Folder", moved here from the menu, is there with or
    /// without a recording, and opens the folder.
    func testOpenProtocolsFolderCallsItsAction() throws {
        var calls: [String] = []
        let sut = makeView([], actions: recording { calls.append($0) })

        let folder = try button(A11yID.recordingsOpenFolderButton, in: sut)
        XCTAssertNoThrow(try folder.find(text: "Open Protocols Folder"))
        try folder.tap()

        XCTAssertEqual(calls, ["openProtocolsFolder"])
    }

    /// "Regenerate from File…" asks for a regeneration with no meeting.
    func testRegenerateFromFileCallsRegenerateWithNoMeeting() throws {
        var calls: [String] = []
        let sut = makeView([entry("Retro", protocolPath: "/out/retro.md")], actions: recording { calls.append($0) })

        let regenerate = try button(A11yID.recordingsRegenerateFromFileButton, in: sut)
        XCTAssertNoThrow(try regenerate.find(text: "Regenerate from File…"))
        try regenerate.tap()

        XCTAssertEqual(calls, ["regenerate none"])
    }

    // MARK: - Main button

    /// Each row shows the one button its state calls for, labelled by it, and
    /// hands that action the row's own job or file; a failed row also shows
    /// its error, and a finished job with neither file has no button.
    func testEachRowsMainButtonCallsItsActionWithTheRowsJobOrFile() throws {
        let running = entry("Running", state: .transcribing)
        let naming = entry("Naming", state: .speakerNamingPending)
        let withProtocol = entry("Protocol", protocolPath: "/out/p.md", transcriptPath: "/out/p.txt")
        let transcriptOnly = entry("Transcript", transcriptPath: "/out/t.txt")
        let retryable = entry("Retryable", state: .error, error: "Diarization failed")
        let refused = entry("Refused", state: .error, error: "Audio file missing")
        let neither = entry("Neither")
        var calls: [String] = []
        var base = AllRecordingsActions.noop
        base.canRetry = { $0 == retryable.id }
        let sut = makeView(
            [running, naming, withProtocol, transcriptOnly, retryable, refused, neither],
            actions: recording(into: { calls.append($0) }, base: base),
        )
        let expected: [(label: String, call: String)] = [
            ("Cancel", "cancel \(running.id)"),
            ("Name Speakers", "nameSpeakers \(naming.id)"),
            ("Open Protocol", "openProtocol /out/p.md"),
            ("Open Transcript", "openTranscript /out/t.txt"),
            ("Retry", "retry \(retryable.id)"),
            ("Remove", "remove \(refused.id)"),
        ]

        for (index, want) in expected.enumerated() {
            let main = try button(A11yID.recordingMainButton(index), in: sut)
            XCTAssertEqual(try main.labelView().text().string(), want.label)
            try main.tap()
        }

        XCTAssertEqual(calls, expected.map(\.call))
        XCTAssertNoThrow(try sut.inspect().find(text: "Audio file missing"))
        XCTAssertThrowsError(try button(A11yID.recordingMainButton(6), in: sut), "a finished job with neither file")
    }

    // MARK: - The "…" menu

    /// Each item of a row's "…" menu, labelled, hands its action the row's own
    /// job or file. Show in Finder reveals the protocol, else the transcript,
    /// whichever was on disk.
    func testEachMenuItemCallsItsActionWithTheRowsJobOrFile() throws {
        let finished = entry("Finished", protocolPath: "/out/f.md", transcriptPath: "/out/f.txt")
        let protocolGone = entry("Protocol gone", protocolPath: "/out/g.md", transcriptPath: "/out/g.txt")
        let failed = entry("Failed", state: .error, error: "Diarization failed", transcriptPath: "/out/e.txt")
        let naming = entry("Naming", state: .speakerNamingPending)
        var calls: [String] = []
        var base = AllRecordingsActions.noop
        base.canRetry = { $0 == failed.id }
        base.filesOnDisk = { entry in
            entry.id == protocolGone.id
                ? FilesOnDisk(protocolExists: false, transcriptExists: true, transcriptSource: .transcriptFile)
                : Self.recordedFilesOnDisk(entry)
        }
        let sut = makeView(
            [finished, protocolGone, failed, naming],
            actions: recording(into: { calls.append($0) }, base: base),
        )
        let taps: [(id: String, label: String, call: String)] = [
            (A11yID.recordingMenuOpenProtocol(0), "Open Protocol", "openProtocol /out/f.md"),
            (A11yID.recordingMenuOpenTranscript(0), "Open Transcript", "openTranscript /out/f.txt"),
            (A11yID.recordingMenuShowInFinder(0), "Show in Finder", "reveal /out/f.md"),
            (A11yID.recordingMenuRegenerate(0), "Regenerate Protocol…", "regenerate \(finished.id)"),
            (A11yID.recordingMenuShowInFinder(1), "Show in Finder", "reveal /out/g.txt"),
            (A11yID.recordingMenuRetry(2), "Retry", "retry \(failed.id)"),
            (A11yID.recordingMenuRemove(2), "Remove", "remove \(failed.id)"),
            (A11yID.recordingMenuDismiss(3), "Dismiss", "dismiss \(naming.id)"),
        ]

        for tap in taps {
            let item = try button(tap.id, in: sut)
            XCTAssertEqual(try item.labelView().text().string(), tap.label)
            try item.tap()
        }

        XCTAssertEqual(calls, taps.map(\.call))
    }

    /// The "…" menu holds exactly `RecordingRowActions.menuItems` for its row,
    /// in that order, Regenerate disabled without a transcript source; a
    /// running job's menu is empty and its "…" disabled.
    func testTheMoreMenuListsExactlyTheRowsMenuItems() throws {
        let rows: [(entry: TranscriptionEntry, onDisk: FilesOnDisk, canRetry: Bool)] = [
            (
                entry("Both", protocolPath: "/out/b.md", transcriptPath: "/out/b.txt"),
                FilesOnDisk(protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile), false,
            ),
            (
                entry("No source", protocolPath: "/out/n.md", transcriptPath: "/out/n.txt"),
                FilesOnDisk(protocolExists: true, transcriptExists: false, transcriptSource: .none), false,
            ),
            (
                entry("Failed", state: .error, error: "Failed", protocolPath: "/out/e.md"),
                FilesOnDisk(protocolExists: true, transcriptExists: false, transcriptSource: .protocolOnly), true,
            ),
            (
                entry("Naming", state: .speakerNamingPending, transcriptPath: "/out/d.txt"),
                FilesOnDisk(protocolExists: false, transcriptExists: true, transcriptSource: .transcriptFile), false,
            ),
            (
                entry("Running", state: .diarizing, transcriptPath: "/out/r.txt"),
                FilesOnDisk(protocolExists: false, transcriptExists: true, transcriptSource: .transcriptFile), false,
            ),
        ]
        var actions = AllRecordingsActions.noop
        actions.canRetry = { id in rows.contains { $0.entry.id == id && $0.canRetry } }
        actions.filesOnDisk = { entry in rows.first { $0.entry.id == entry.id }?.onDisk ?? Self.recordedFilesOnDisk(entry) }
        let sut = makeView(rows.map(\.entry), actions: actions)

        for (index, row) in rows.enumerated() {
            let expected = RecordingRowActions.menuItems(state: row.entry.state, onDisk: row.onDisk, canRetry: row.canRetry)
            let menu = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingMoreButton(index))
            let items = menu.findAll(ViewType.Button.self)

            XCTAssertEqual(
                try items.map { try $0.accessibilityIdentifier() },
                expected.map { TranscriptionsView.identifier(of: $0, index: index) },
                row.entry.title,
            )
            XCTAssertEqual(items.map { $0.isDisabled() }, expected.map { $0 == .regenerate(enabled: false) }, row.entry.title)
            XCTAssertEqual(menu.isDisabled(), expected.isEmpty, row.entry.title)
        }
    }

    /// A file that is gone says so in the window instead of nothing happening,
    /// whether the main button or a menu item tried it, and the next action
    /// that finds its file takes the message away.
    func testAMissingFileShowsTheMovedOrDeletedMessage() throws {
        let message = "The file was moved or deleted."
        var actions = AllRecordingsActions.noop
        actions.openProtocol = { _ in false }
        actions.filesOnDisk = { _ in FilesOnDisk(protocolExists: true, transcriptExists: false, transcriptSource: .none) }
        let sut = makeView([entry("Retro", protocolPath: "/out/retro.md")], actions: actions)
        XCTAssertThrowsError(try sut.inspect().find(text: message))

        try button(A11yID.recordingMainButton(0), in: sut).tap()
        XCTAssertNoThrow(try sut.inspect().find(text: message))

        try button(A11yID.recordingMenuShowInFinder(0), in: sut).tap()
        XCTAssertThrowsError(try sut.inspect().find(text: message))

        try button(A11yID.recordingMenuOpenProtocol(0), in: sut).tap()
        XCTAssertNoThrow(try sut.inspect().find(text: message))
    }

    /// A row action reads the rows' files again at the next draw; drawing
    /// again without one reads nothing.
    func testARowActionReadsTheRowsFilesAgain() throws {
        var reads = 0
        var actions = AllRecordingsActions.noop
        actions.filesOnDisk = { entry in
            reads += 1
            return Self.recordedFilesOnDisk(entry)
        }
        let sut = makeView([entry("Retro", protocolPath: "/out/retro.md")], actions: actions)
        let draw = { _ = try sut.inspect().find(text: "Retro") }

        try draw()
        try draw()
        XCTAssertEqual(reads, 1)

        try button(A11yID.recordingMainButton(0), in: sut).tap()
        try draw()
        XCTAssertEqual(reads, 2)
    }

    // MARK: - Detail line

    /// App, date and time, and duration; each one an entry does not have reads
    /// "—", as for a record written before the history kept them.
    func testTheDetailLineShowsADashForEachMissingValue() throws {
        let legacy = try XCTUnwrap(TranscriptionEntry(
            record: TerminalJobRecord(status: JobStatusDTO(
                jobID: UUID().uuidString, state: .done, meetingTitle: "Old",
                transcriptPath: nil, protocolPath: nil, error: nil, warnings: [],
            )),
            finishOrder: 0,
        ))
        let start = Date(timeIntervalSinceReferenceDate: 780_000_000)
        var job = PipelineJob(
            meetingTitle: "New", appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/rec/new_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
            meetingStartTime: start,
        )
        job.audioDuration = 65
        let measured = TranscriptionEntry(job: job, finishOrder: nil)

        XCTAssertEqual(TranscriptionsView.detailLine(for: legacy), "— · — · —")
        XCTAssertEqual(
            TranscriptionsView.detailLine(for: measured),
            "Zoom · \(start.formatted(date: .abbreviated, time: .shortened)) · 1:05",
        )
    }

    // MARK: - Privacy

    /// The rows show titles, participants and file paths; none of them may
    /// reach an identifier, which `GET /ui/tree` would publish unredacted.
    func testNoIdentifierCarriesATitleParticipantOrPath() throws {
        let failed = entry(
            "Board Meeting", state: .error, participants: ["Dana Scully"], error: "Failed",
            protocolPath: "/out/board-meeting.md",
        )
        var actions = AllRecordingsActions.noop
        actions.canRetry = { _ in true }
        actions.filesOnDisk = { Self.recordedFilesOnDisk($0) }
        let identifiers = try makeView([failed], actions: actions).inspect()
            .findAll { (try? $0.accessibilityIdentifier()) != nil }
            .map { try $0.accessibilityIdentifier() }

        XCTAssertEqual(Set(identifiers), [
            A11yID.transcriptionsSearchField,
            A11yID.recordingsOpenFolderButton,
            A11yID.recordingsRegenerateFromFileButton,
            A11yID.recordingMainButton(0),
            A11yID.recordingMoreButton(0),
            A11yID.recordingMenuOpenProtocol(0),
            A11yID.recordingMenuShowInFinder(0),
            A11yID.recordingMenuRetry(0),
            A11yID.recordingMenuRemove(0),
        ])
    }
}
