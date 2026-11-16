@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// Wiring of the Transcribe Again sheet: that it shows `RerunSheetText`'s texts,
/// and what its two buttons do. The texts themselves are `RerunSheetTextTests`, the
/// row item that opens it `TranscriptionsViewTests+TranscribeAgain.swift`.
@MainActor
final class TranscribeAgainSheetTests: XCTestCase {
    private static let meeting = RerunSheetText.Meeting(
        id: UUID(), title: "Weekly team sync", date: nil, duration: 2880, twoTracks: true, hasReports: false, hasNotionPage: false,
    )
    private static let settings = RerunSheetText.Settings(
        engine: .parakeet, whisperKitModel: .init(variant: "openai_whisper-small", origin: .stock), whisperLanguage: "",
        parakeetLanguage: "de", vocabulary: false, diarize: true, diarizerMode: .sortformer, makesNotes: true, notionExport: false,
    )

    /// A sheet open for `meeting`, whose action records each meeting it was handed
    /// and answers from `answers` in turn.
    private func makeSheet(
        _ state: TranscribeAgainSheetState, answers: [RerunAdmission] = [.queued], calls: @escaping (UUID) -> Void = { _ in },
    ) -> TranscribeAgainSheet {
        state.open(Self.meeting)
        var left = answers
        return TranscribeAgainSheet(meeting: Self.meeting, state: state, settings: { Self.settings }, transcribeAgain: { id in
            calls(id)
            return left.isEmpty ? .queued : left.removeFirst()
        })
    }

    private func tap(_ identifier: String, in sheet: TranscribeAgainSheet) throws {
        try sheet.inspect().find(viewWithAccessibilityIdentifier: identifier).button().tap()
    }

    func testTheSheetShowsItsTexts() throws {
        let texts = try makeSheet(TranscribeAgainSheetState()).inspect().findAll(ViewType.Text.self).map { try $0.string() }

        let rows = RerunSheetText.rows(Self.settings, meeting: Self.meeting).flatMap { [$0.label, $0.value] }
        XCTAssertEqual(
            texts,
            [RerunSheetText.title, RerunSheetText.meetingLine(Self.meeting)] + rows + [RerunSheetText.fromSettings, RerunSheetText.whatHappensHeading]
                + RerunSheetText.whatHappens(Self.settings, meeting: Self.meeting) + ["Cancel", RerunSheetText.actionButton],
        )
    }

    func testCancelClosesTheSheetAndQueuesNothing() throws {
        let state = TranscribeAgainSheetState()
        var calls: [UUID] = []
        let sut = makeSheet(state) { calls.append($0) }

        try tap(A11yID.transcribeAgainCancelButton, in: sut)

        XCTAssertNil(state.meeting)
        XCTAssertEqual(calls, [])
    }

    func testTheDefaultButtonQueuesTheMeetingAndClosesTheSheet() throws {
        let state = TranscribeAgainSheetState()
        var calls: [UUID] = []
        let sut = makeSheet(state) { calls.append($0) }

        try tap(A11yID.transcribeAgainConfirmButton, in: sut)

        XCTAssertEqual(calls, [Self.meeting.id])
        XCTAssertNil(state.meeting)
    }

    /// Audio gone or out of reach keeps the sheet open with its line, and each click
    /// asks again (A18).
    func testARefusalKeepsTheSheetOpenWithItsLine() throws {
        let state = TranscribeAgainSheetState()
        var calls = 0
        let sut = makeSheet(state, answers: [.refused(.audioGone), .refused(.audioUnreachable), .queued]) { _ in calls += 1 }
        let line = { (reason: RerunRefusal) in try sut.inspect().find(text: RerunSheetText.refusal(reason)) }
        XCTAssertThrowsError(try line(.audioGone), "no line before a click")

        try tap(A11yID.transcribeAgainConfirmButton, in: sut)
        XCTAssertEqual(state.meeting, Self.meeting)
        XCTAssertNoThrow(try line(.audioGone))

        try tap(A11yID.transcribeAgainConfirmButton, in: sut)
        XCTAssertNoThrow(try line(.audioUnreachable))
        XCTAssertThrowsError(try line(.audioGone))

        try tap(A11yID.transcribeAgainConfirmButton, in: sut)
        XCTAssertEqual(calls, 3)
        XCTAssertNil(state.meeting)
    }
}
