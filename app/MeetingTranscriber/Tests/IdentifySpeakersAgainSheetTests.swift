@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// Wiring of the Identify Speakers Again sheet: that it shows the texts of
/// `RerunSheetText.IdentifySpeakersAgain` for the method picked, where it starts, and
/// what its controls and two buttons do. The texts themselves are `RerunSheetTextTests`,
/// the row item that opens it `TranscriptionsViewTests+IdentifySpeakersAgain.swift`.
@MainActor
final class IdentifySpeakersAgainSheetTests: XCTestCase {
    private typealias Words = RerunSheetText.IdentifySpeakersAgain

    private static let meeting = RerunSheetText.Meeting(
        id: UUID(), title: "Weekly team sync", date: nil, duration: 2880, twoTracks: true, hasReports: false, hasNotionPage: false,
        hasWordTimings: false,
    )

    private static func settings(_ mode: DiarizerMode = .offline, numSpeakers: Int = 0) -> RerunSheetText.Settings {
        RerunSheetText.Settings(
            engine: .parakeet, whisperKitModel: .init(variant: "openai_whisper-small", origin: .stock), whisperLanguage: "",
            parakeetLanguage: "de", vocabulary: false, diarize: true, diarizerMode: mode, makesNotes: true, notionExport: false,
            numSpeakers: numSpeakers,
        )
    }

    /// A sheet opened for `meeting` at `settings`, whose action records what it was
    /// handed and answers from `answers` in turn.
    private func makeSheet(
        _ state: IdentifySpeakersAgainSheetState, settings: RerunSheetText.Settings = settings(), answers: [RerunAdmission] = [.queued],
        calls: @escaping (UUID, RerunSpeakers) -> Void = { _, _ in },
    ) -> IdentifySpeakersAgainSheet {
        state.open(Self.meeting, settings: settings)
        var left = answers
        return IdentifySpeakersAgainSheet(meeting: Self.meeting, state: state, settings: { settings }, identifySpeakersAgain: { id, speakers in
            calls(id, speakers)
            return left.isEmpty ? .queued : left.removeFirst()
        })
    }

    private func control(_ identifier: String, in sheet: IdentifySpeakersAgainSheet) throws -> InspectableView<ViewType.ClassifiedView> {
        try sheet.inspect().find(viewWithAccessibilityIdentifier: identifier)
    }

    private func methodPicker(in sheet: IdentifySpeakersAgainSheet) throws -> InspectableView<ViewType.Picker> {
        try control(A11yID.identifySpeakersAgainMethodPicker, in: sheet).find(ViewType.Picker.self)
    }

    private func pick(_ method: DiarizerMode, in sheet: IdentifySpeakersAgainSheet) throws {
        try methodPicker(in: sheet).select(value: method)
    }

    /// The picker's and the stepper's hidden labels are read out after their content.
    func testTheSheetShowsItsTexts() throws {
        let texts = try makeSheet(IdentifySpeakersAgainSheetState()).inspect().findAll(ViewType.Text.self).map { try $0.string() }

        let methods = DiarizerMode.displayOrder.flatMap { [$0.displayName, $0.methodDescription] }
        let lines = Words.whatHappens(Self.settings(), meeting: Self.meeting).map(\.text)
        XCTAssertEqual(
            texts,
            [Words.title, RerunSheetText.meetingLine(Self.meeting), Words.methodHeading] + methods + [Words.methodHeading]
                + [Words.countLabel, "2", "", SpeakerNamingView.micSideNote, RerunSheetText.whatHappensHeading] + lines
                + ["Cancel", Words.actionButton],
        )
    }

    /// Settings' method and count, 2 for Auto (D7).
    func testTheSheetStartsAtSettingsMethodAndCount() throws {
        let state = IdentifySpeakersAgainSheetState()
        let auto = makeSheet(state, settings: Self.settings(.nemotron))
        XCTAssertEqual(try methodPicker(in: auto).selectedValue(DiarizerMode.self), .nemotron)
        XCTAssertEqual(state.count, 2)

        let four = makeSheet(state, settings: Self.settings(.offline, numSpeakers: 4))
        XCTAssertEqual(try methodPicker(in: four).selectedValue(DiarizerMode.self), .offline)
        XCTAssertNoThrow(try four.inspect().find(text: "4"))
    }

    /// Sortformer and Nemotron 3 count the speakers themselves: the naming dialog's
    /// hint takes the count's place; Standard brings the count back (A17).
    func testPickingAMethodShowsTheCountOrTheMethodsHint() throws {
        let sut = makeSheet(IdentifySpeakersAgainSheetState())
        XCTAssertNoThrow(try control(A11yID.identifySpeakersAgainCountStepper, in: sut))

        for method in [DiarizerMode.sortformer, .nemotron] {
            try pick(method, in: sut)
            XCTAssertThrowsError(try control(A11yID.identifySpeakersAgainCountStepper, in: sut), "\(method)")
            let hint = try XCTUnwrap(SpeakerNamingView.rerunMethodHint(mode: method, isDualSource: true))
            XCTAssertNoThrow(try sut.inspect().find(text: hint), "\(method)")
        }

        try pick(.offline, in: sut)
        XCTAssertNoThrow(try control(A11yID.identifySpeakersAgainCountStepper, in: sut))
        XCTAssertNoThrow(try sut.inspect().find(text: SpeakerNamingView.micSideNote))
    }

    func testTheDefaultButtonPassesTheChosenMethodAndCount() throws {
        let state = IdentifySpeakersAgainSheetState()
        var ids: [UUID] = []
        var speakers: [RerunSpeakers] = []
        let sut = makeSheet(state, settings: Self.settings(.sortformer, numSpeakers: 3)) { id, chosen in
            ids.append(id)
            speakers.append(chosen)
        }

        try pick(.offline, in: sut)
        try control(A11yID.identifySpeakersAgainCountStepper, in: sut).find(ViewType.Stepper.self).increment()
        try control(A11yID.identifySpeakersAgainConfirmButton, in: sut).button().tap()

        XCTAssertEqual(ids, [Self.meeting.id])
        XCTAssertEqual(speakers, [RerunSpeakers(method: .offline, count: 4)])
        XCTAssertNil(state.meeting)
    }

    func testCancelClosesTheSheetAndQueuesNothing() throws {
        let state = IdentifySpeakersAgainSheetState()
        var calls = 0
        let sut = makeSheet(state) { _, _ in calls += 1 }

        try control(A11yID.identifySpeakersAgainCancelButton, in: sut).button().tap()

        XCTAssertNil(state.meeting)
        XCTAssertEqual(calls, 0)
    }

    /// Audio out of reach keeps the sheet open with its line, and the next click asks
    /// again (A18).
    func testARefusalKeepsTheSheetOpenWithItsLine() throws {
        let state = IdentifySpeakersAgainSheetState()
        var calls = 0
        let sut = makeSheet(state, answers: [.refused(.audioUnreachable), .queued]) { _, _ in calls += 1 }
        let line = { try sut.inspect().find(text: RerunSheetText.refusal(.audioUnreachable)) }
        XCTAssertThrowsError(try line(), "no line before a click")

        try control(A11yID.identifySpeakersAgainConfirmButton, in: sut).button().tap()
        XCTAssertEqual(state.meeting, Self.meeting)
        XCTAssertNoThrow(try line())

        try control(A11yID.identifySpeakersAgainConfirmButton, in: sut).button().tap()
        XCTAssertEqual(calls, 2)
        XCTAssertNil(state.meeting)
    }
}
