@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The Edit Summary sheet (spec R4, D11, A17): what it opens with, the line under
/// the field, and what each control does. Every summary here is made up.
@MainActor
final class EditSummarySheetTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func row() -> TranscriptionEntry {
        var job = PipelineJob(meetingTitle: "Weekly team sync", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.audioDuration = 2892
        return TranscriptionEntry(job: job, finishOrder: nil)
    }

    private func opened(_ summaries: MeetingSummaries?, saved: @escaping (UUID, String) -> Void = { _, _ in }) throws
        -> (EditSummarySheetState, EditSummarySheet) {
        let state = EditSummarySheetState()
        state.open(row()) { _ in summaries }
        return try (state, EditSummarySheet(meeting: XCTUnwrap(state.meeting), state: state, save: saved))
    }

    private func button(_ identifier: String, in sheet: EditSummarySheet) throws -> InspectableView<ViewType.Button> {
        try sheet.inspect().find(viewWithAccessibilityIdentifier: identifier).button()
    }

    private func noteLine(of sheet: EditSummarySheet) -> String? {
        try? sheet.inspect().find(viewWithAccessibilityIdentifier: A11yID.editSummaryNoteLine).text().string()
    }

    /// The heading and the meeting's line; the field holds the shown summary, and the
    /// line under it says where it came from, nothing for a meeting without one.
    func testTheSheetShowsTheMeetingTheShownSummaryAndWhereItCameFrom() throws {
        let notes = MeetingSummaries(notes: .init(text: "From the notes", writtenAt: date))
        let typed = MeetingSummaries(notes: notes.notes, typed: .init(text: "Mine", writtenAt: date))
        let cases: [(MeetingSummaries?, String, String?)] = [
            (notes, "From the notes", EditSummarySheetState.fromNotesLine),
            (typed, "Mine", EditSummarySheetState.typedLine),
            (nil, "", nil),
        ]
        for (summaries, field, line) in cases {
            let (state, sheet) = try opened(summaries)

            XCTAssertNoThrow(try sheet.inspect().find(text: "Edit Summary"))
            XCTAssertNoThrow(try sheet.inspect().find(text: XCTUnwrap(state.meeting?.line)))
            XCTAssertTrue(state.meeting?.line.hasPrefix("Weekly team sync · ") ?? false)
            XCTAssertTrue(state.meeting?.line.hasSuffix(" · 48:12") ?? false)
            XCTAssertEqual(state.text, field)
            XCTAssertEqual(noteLine(of: sheet), line, field)
        }
    }

    func testTypingWritesTheFieldAndSaveHandsItOnAndCloses() throws {
        var saved: [String] = []
        let (state, sheet) = try opened(nil) { saved.append("\($0) \($1)") }
        let id = try XCTUnwrap(state.meeting?.id)

        try sheet.inspect().find(ViewType.TextField.self) { try $0.accessibilityIdentifier() == A11yID.editSummaryTextField }
            .setInput("Plan agreed")
        try button(A11yID.editSummarySaveButton, in: sheet).tap()

        XCTAssertEqual(saved, ["\(id) Plan agreed"])
        XCTAssertNil(state.meeting)
    }

    /// Over 600 characters Save is disabled and the line says so; Cancel changes nothing.
    func testALongTextDisablesSaveAndCancelSavesNothing() throws {
        var saved = 0
        let (state, sheet) = try opened(nil) { _, _ in saved += 1 }
        state.text = String(repeating: "a", count: MeetingSummary.maxLength + 1)

        XCTAssertTrue(try button(A11yID.editSummarySaveButton, in: sheet).isDisabled())
        XCTAssertEqual(noteLine(of: sheet), EditSummarySheetState.tooLongLine)
        state.text = String(repeating: "a", count: MeetingSummary.maxLength)
        XCTAssertFalse(try button(A11yID.editSummarySaveButton, in: sheet).isDisabled())

        try button(A11yID.editSummaryCancelButton, in: sheet).tap()

        XCTAssertEqual(saved, 0)
        XCTAssertNil(state.meeting)
    }

    /// "Use Summary from Notes" puts the notes summary into the field, and is disabled
    /// for a meeting without one.
    func testUseSummaryFromNotesPutsTheNotesSummaryIntoTheField() throws {
        let typed = MeetingSummaries(notes: .init(text: "From the notes", writtenAt: date), typed: .init(text: "Mine", writtenAt: date))
        let (state, sheet) = try opened(typed)

        try button(A11yID.editSummaryUseNotesButton, in: sheet).tap()

        XCTAssertEqual(state.text, "From the notes")
        let (_, without) = try opened(MeetingSummaries(typed: .init(text: "Mine", writtenAt: date)))
        XCTAssertTrue(try button(A11yID.editSummaryUseNotesButton, in: without).isDisabled())
    }

    /// A notes summary that arrives while the sheet is open is the one the button
    /// offers, never the one the meeting had when the sheet opened.
    func testUseSummaryFromNotesOffersTheNotesSummaryTheMeetingHasNow() throws {
        var current: MeetingSummaries?
        let state = EditSummarySheetState()
        state.open(row()) { _ in current }
        let sheet = try EditSummarySheet(meeting: XCTUnwrap(state.meeting), state: state) { _, _ in }
        XCTAssertTrue(try button(A11yID.editSummaryUseNotesButton, in: sheet).isDisabled(), "test premise: none yet")

        current = MeetingSummaries(notes: .init(text: "Current notes.", writtenAt: date))
        try button(A11yID.editSummaryUseNotesButton, in: sheet).tap()

        XCTAssertEqual(state.text, "Current notes.")
        XCTAssertEqual(noteLine(of: sheet), EditSummarySheetState.fromNotesLine)
    }
}
