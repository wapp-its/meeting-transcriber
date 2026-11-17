@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// A row's summary (spec R3, R4, R6): the line under the title with the whole text as
/// its tooltip, "Edit Summary…" opening the sheet for its own row, and the search
/// field's hint. The sheet itself is `EditSummarySheetTests`, the search rule
/// `TranscriptionListTests`. Every summary here is made up.
extension TranscriptionsViewTests {
    func summarized(_ title: String, _ summary: String?, state: JobState = .done) -> TranscriptionEntry {
        var row = entry(title, state: state, protocolPath: "/out/\(title).md")
        row.summary = summary
        return row
    }

    func testARowShowsItsSummaryUnderTheTitleWithTheWholeTextAsTooltip() throws {
        let summary = "The team agreed to ship the beta on Friday."
        let sut = makeView([summarized("Retro", summary, state: .transcribing), summarized("Standup", nil)])

        let line = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingSummaryLine(0)).text()
        XCTAssertEqual(try line.string(), summary)
        XCTAssertEqual(try line.help().string(), summary)
        XCTAssertEqual(try line.lineLimit(), 2)
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingSummaryLine(1)), "a row without one")
    }

    func testEditSummaryOpensTheSheetForItsRowWithItsSummaries() throws {
        let rows = [summarized("Retro", "Shown"), summarized("Standup", "Typed")]
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let typed = MeetingSummaries(notes: .init(text: "From the notes", writtenAt: date), typed: .init(text: "Typed", writtenAt: date))
        var actions = AllRecordingsActions.noop
        actions.filesOnDisk = { Self.recordedFilesOnDisk($0) }
        actions.meetingSummaries = { $0 == rows[1].id ? typed : nil }
        var saved: [String] = []
        actions.saveSummary = { saved.append("\($0) \($1)") }
        let state = EditSummarySheetState()
        let sut = makeView(rows, actions: actions, editSummary: state)
        XCTAssertThrowsError(try sut.inspect().find(EditSummarySheet.self), "no sheet before a click")

        try button(A11yID.recordingMenuEditSummary(1), in: sut).tap()

        XCTAssertEqual(state.meeting?.id, rows[1].id)
        XCTAssertEqual(state.text, "Typed")
        let sheet = try sut.inspect().find(ViewType.Sheet.self).find(EditSummarySheet.self)
        try sheet.find(viewWithAccessibilityIdentifier: A11yID.editSummarySaveButton).button().tap()
        XCTAssertEqual(saved, ["\(rows[1].id) Typed"])
    }

    func testTheSearchFieldsHintNamesSummaries() throws {
        let field = try makeView([]).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.transcriptionsSearchField)
            .find(ViewType.TextField.self)

        XCTAssertEqual(try field.labelView().text().string(), "Search titles and summaries")
    }
}
