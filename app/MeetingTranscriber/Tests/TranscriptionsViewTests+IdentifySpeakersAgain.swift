@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// A row's "Identify Speakers Again…" opens its own sheet for its own row, at Settings'
/// method and count and with what the row's record says of the word timings, and the
/// sheet's default button queues that meeting with the speakers picked. Which rows list
/// it is `RecordingRowActionsTests`, that both menus list it
/// `TranscriptionsViewTests+TranscribeAgain.swift`, what the sheet does
/// `IdentifySpeakersAgainSheetTests`.
extension TranscriptionsViewTests {
    func testIdentifySpeakersAgainOpensItsSheetForItsRowAndQueuesTheSpeakersPicked() throws {
        let rows = [rerunRow("Retro"), rerunRow("Standup")]
        let state = IdentifySpeakersAgainSheetState()
        var queued: [UUID] = []
        var speakers: [RerunSpeakers] = []
        var transcribed = 0
        var actions = rerunActions(rows)
        let other = meeting(rows[0]).record
        let words = meeting(rows[1]) { $0.files.append(RetentionFixture.file(.segments, "Standup_segments.json")) }.record
        actions.meetingFiles = { $0 == rows[1].id ? words : other }
        actions.rerunSettings = {
            RerunSheetText.Settings(
                engine: .whisperKit, whisperKitModel: .init(variant: "openai_whisper-small", origin: .stock), whisperLanguage: "",
                parakeetLanguage: "", vocabulary: false, diarize: true, diarizerMode: .nemotron, makesNotes: true, notionExport: false,
            )
        }
        actions.transcribeAgain = { _ in
            transcribed += 1
            return .queued
        }
        actions.identifySpeakersAgain = { id, chosen in
            queued.append(id)
            speakers.append(chosen)
            return .queued
        }
        let sut = makeView(rows, actions: actions, identifySpeakersAgain: state)
        XCTAssertThrowsError(try sut.inspect().find(IdentifySpeakersAgainSheet.self), "no sheet before a click")

        try button(A11yID.recordingMenuIdentifySpeakersAgain(1), in: sut).tap()
        XCTAssertEqual(state.meeting?.id, rows[1].id)
        XCTAssertEqual(state.meeting?.hasWordTimings, true)
        XCTAssertEqual(state.method, .nemotron)
        XCTAssertEqual(state.count, 2, "Settings' Auto")
        try sut.inspect().find(IdentifySpeakersAgainSheet.self)
            .find(viewWithAccessibilityIdentifier: A11yID.identifySpeakersAgainConfirmButton).button().tap()

        XCTAssertEqual(queued, [rows[1].id])
        XCTAssertEqual(speakers, [RerunSpeakers(method: .nemotron, count: 2)])
        XCTAssertEqual(transcribed, 0)
        XCTAssertNil(state.meeting)
        XCTAssertThrowsError(try sut.inspect().find(IdentifySpeakersAgainSheet.self), "closed once queued")
    }
}
