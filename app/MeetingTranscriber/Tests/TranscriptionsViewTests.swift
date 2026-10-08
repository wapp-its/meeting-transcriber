@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The Transcriptions window's wiring: what each control hands to the closure
/// or binding it was given, which rows a query leaves, and what a row says. The
/// list itself (merge, order, search rule) is covered by `TranscriptionListTests`.
@MainActor
final class TranscriptionsViewTests: XCTestCase {
    /// What the search field's binding writes to, so a test reads the typed
    /// text without reaching into SwiftUI's state.
    private final class QueryBox {
        var text = ""
    }

    private func makeView(
        _ entries: [TranscriptionEntry],
        query: String = "",
        queryBox: QueryBox? = nil,
        canRetry: @escaping (UUID) -> Bool = { _ in false },
        onOpen: @escaping (URL) -> Bool = { _ in true },
        onReveal: @escaping (URL) -> Bool = { _ in true },
        onRetry: @escaping (UUID) -> Void = { _ in },
        onRemove: @escaping (UUID) -> Void = { _ in },
    ) -> TranscriptionsView {
        let box = queryBox ?? QueryBox()
        box.text = query
        return TranscriptionsView(
            entries: entries,
            query: Binding(get: { box.text }, set: { box.text = $0 }),
            canRetry: canRetry,
            onOpen: onOpen,
            onReveal: onReveal,
            onRetry: onRetry,
            onRemove: onRemove,
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

    // MARK: - Open and Show in Finder

    /// Open and Show in Finder take the protocol, else the transcript; an
    /// entry with neither file offers neither.
    func testOpenAndShowInFinderHandTheEntrysFileToTheirClosures() throws {
        var opened: [URL] = []
        var revealed: [URL] = []
        let sut = makeView(
            [
                entry("Both", protocolPath: "/out/both.md", transcriptPath: "/out/both.txt"),
                entry("Transcript only", transcriptPath: "/out/only.txt"),
                entry("Neither", state: .error, error: "Transcription failed"),
            ],
            onOpen: { opened.append($0); return true },
            onReveal: { revealed.append($0); return true },
        )

        try button(A11yID.transcriptionOpenButton(0), in: sut).tap()
        try button(A11yID.transcriptionRevealButton(1), in: sut).tap()

        XCTAssertEqual(opened, [URL(fileURLWithPath: "/out/both.md")])
        XCTAssertEqual(revealed, [URL(fileURLWithPath: "/out/only.txt")])
        XCTAssertThrowsError(try button(A11yID.transcriptionOpenButton(2), in: sut))
        XCTAssertThrowsError(try button(A11yID.transcriptionRevealButton(2), in: sut))
    }

    /// A file that is gone says so in the window instead of nothing happening,
    /// and the next action that finds its file takes the message away.
    func testAMissingFileShowsTheMovedOrDeletedMessage() throws {
        let message = "The file was moved or deleted."
        let sut = makeView(
            [entry("Retro", protocolPath: "/out/retro.md")],
            onOpen: { _ in false },
            onReveal: { _ in true },
        )
        XCTAssertThrowsError(try sut.inspect().find(text: message))

        try button(A11yID.transcriptionOpenButton(0), in: sut).tap()
        XCTAssertNoThrow(try sut.inspect().find(text: message))

        try button(A11yID.transcriptionRevealButton(0), in: sut).tap()
        XCTAssertThrowsError(try sut.inspect().find(text: message))
    }

    // MARK: - Failed entries

    /// A failed row shows its error, Retry only where the pipeline would
    /// accept it, and Remove; a done row has neither action.
    func testAFailedRowShowsItsErrorRetryWhenAcceptedAndRemove() throws {
        let refused = entry("Refused", state: .error, error: "Audio file missing")
        let accepted = entry("Accepted", state: .error, error: "Diarization failed")
        let done = entry("Done", protocolPath: "/out/done.md")
        var retried: [UUID] = []
        var removed: [UUID] = []
        let sut = makeView(
            [refused, accepted, done],
            canRetry: { $0 == accepted.id || $0 == done.id },
            onRetry: { retried.append($0) },
            onRemove: { removed.append($0) },
        )

        XCTAssertNoThrow(try sut.inspect().find(text: "Audio file missing"))
        XCTAssertThrowsError(try button(A11yID.transcriptionRetryButton(0), in: sut))
        try button(A11yID.transcriptionRetryButton(1), in: sut).tap()
        try button(A11yID.transcriptionRemoveButton(0), in: sut).tap()
        XCTAssertEqual(retried, [accepted.id])
        XCTAssertEqual(removed, [refused.id])

        XCTAssertThrowsError(try button(A11yID.transcriptionRetryButton(2), in: sut), "Retry offered on a done row")
        XCTAssertThrowsError(try button(A11yID.transcriptionRemoveButton(2), in: sut), "Remove offered on a done row")
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
        // swiftlint:disable:next trailing_closure
        let identifiers = try makeView([failed], canRetry: { _ in true }).inspect()
            .findAll { (try? $0.accessibilityIdentifier()) != nil }
            .map { try $0.accessibilityIdentifier() }

        XCTAssertEqual(Set(identifiers), [
            A11yID.transcriptionsSearchField,
            A11yID.transcriptionOpenButton(0),
            A11yID.transcriptionRevealButton(0),
            A11yID.transcriptionRetryButton(0),
            A11yID.transcriptionRemoveButton(0),
        ])
    }
}
