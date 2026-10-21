@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the regenerate sheet's form. Which meeting it opens with is
/// `RegenerateSheetStateTests`; the decisions themselves are pinned in
/// `ProtocolRegeneratorTests` and `ProtocolRegenerationTargetTests`.
@MainActor
final class RegenerateProtocolViewTests: XCTestCase {
    private static let choices = ProtocolTemplateChoices(templates: [.builtIn, .file(name: "Board")], defaultTemplate: .builtIn)
    private static let use = ProtocolOptionsUse(destination: .remote(name: "Anthropic (Claude)"), recordOnly: false)

    private static func target(start: Date? = nil, hasProtocol: Bool = true) -> ProtocolRegenerationTarget {
        ProtocolRegenerationTarget(
            folder: URL(fileURLWithPath: "/out/protocols"),
            basename: "20261013_0900_standup",
            title: "Standup",
            meetingStartTime: start,
            jobID: nil,
            files: ProtocolRegenerationFiles(
                transcriptFile: Data("[Anna] Hello".utf8), protocolFile: hasProtocol ? Data("# Old".utf8) : nil,
            ),
        )
    }

    private func makeView(
        phase: ProtocolRegenerator.Phase = .idle,
        optionsUse: @escaping () -> ProtocolOptionsUse = { use },
        draft: RegenerateProtocolDraft = RegenerateProtocolDraft(target: target()),
        initialTarget: ProtocolRegenerationTarget? = nil,
        allowsChooseFile: Bool = true,
        chooseFile: @escaping () -> URL? = { nil },
        resolveFile: @escaping (URL) throws -> ProtocolRegenerationTarget = { _ in target() },
        onGenerate: @escaping (ProtocolRegenerationTarget, MeetingProtocolOptions) -> Void = { _, _ in },
        onClose: @escaping () -> Void = {},
    ) -> RegenerateProtocolView {
        RegenerateProtocolView(
            phase: phase,
            templateChoices: { Self.choices },
            optionsUse: optionsUse,
            initialTarget: initialTarget,
            allowsChooseFile: allowsChooseFile,
            chooseFile: chooseFile,
            resolveFile: resolveFile,
            draft: draft,
            onGenerate: onGenerate,
            onClose: onClose,
        )
    }

    private func generateButton(_ view: RegenerateProtocolView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.regenerateGenerateButton).button()
    }

    // MARK: - Opening

    /// Opened from a row: its meeting fills the meeting block (title, date and
    /// the protocol's file name), and there is no "Choose File…" step.
    func testOpenedForAMeetingShowsItAndOffersNoChooseFile() throws {
        let start = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let sut = makeView(draft: RegenerateProtocolDraft(), initialTarget: Self.target(start: start), allowsChooseFile: false)
        try sut.inspect().vStack().callOnAppear()
        let body = try sut.inspect()

        XCTAssertNoThrow(try body.find(text: "Standup"))
        XCTAssertNoThrow(try body.find(text: RegenerateProtocolView.dateLine(start)))
        XCTAssertNoThrow(try body.find(text: "20261013_0900_standup.md"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.regenerateChooseFileButton))
        XCTAssertFalse(try generateButton(sut).isDisabled())
    }

    /// Opened from "Regenerate from File…": no meeting, not even one the form
    /// held before, "Choose File…", and Generate disabled until a file is chosen.
    func testOpenedWithoutAMeetingOffersChooseFileAndCannotGenerate() throws {
        let sut = makeView(draft: RegenerateProtocolDraft(target: Self.target()))
        try sut.inspect().vStack().callOnAppear()
        let body = try sut.inspect()

        XCTAssertNoThrow(try body.find(text: RegenerateProtocolView.noMeeting))
        XCTAssertThrowsError(try body.find(text: "Standup"))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.regenerateChooseFileButton))
        XCTAssertTrue(try generateButton(sut).isDisabled())
    }

    func testCancelClosesTheSheet() throws {
        var closed = false
        // swiftlint:disable:next trailing_closure
        let cancel = try makeView(onClose: { closed = true }).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.regenerateCancelButton)
            .button()

        XCTAssertEqual(try cancel.labelView().text().string(), "Cancel")
        try cancel.tap()
        XCTAssertTrue(closed)
    }

    // MARK: - Generate

    func testGenerateIsDisabledWithoutATargetWhileRunningWithProviderOffAndInRecordOnlyMode() throws {
        // Locals, not closure literals: as the only argument one would be
        // rewritten into a trailing closure.
        let off: () -> ProtocolOptionsUse = { ProtocolOptionsUse(destination: .off, recordOnly: false) }
        let recordOnly: () -> ProtocolOptionsUse = { ProtocolOptionsUse(destination: .remote(name: "x"), recordOnly: true) }
        let cases: [(String, RegenerateProtocolView)] = [
            ("no target", makeView(draft: RegenerateProtocolDraft())),
            ("running", makeView(phase: .running)),
            ("provider None", makeView(optionsUse: off)),
            ("record-only", makeView(optionsUse: recordOnly)),
        ]

        XCTAssertFalse(try generateButton(makeView()).isDisabled(), "a target with a provider must be generatable")
        for (name, view) in cases {
            XCTAssertTrue(try generateButton(view).isDisabled(), name)
        }
    }

    /// Settings changed while the sheet is open: Generate and the notice
    /// explaining it follow the current provider and record-only mode, as the
    /// regeneration itself does, instead of what was true when the sheet opened.
    func testGenerateAndItsExplanationFollowTheSettingsWhileTheSheetIsOpen() throws {
        var use = Self.use
        let currentUse: () -> ProtocolOptionsUse = { use }
        let draft = RegenerateProtocolDraft()
        let sut = makeView(optionsUse: currentUse, draft: draft)
        try sut.inspect().vStack().callOnAppear()
        // Opened without a meeting; one is chosen, as with Choose File.
        draft.target = Self.target()
        let notice = {
            try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsDestinationNotice).text().string()
        }
        XCTAssertFalse(try generateButton(sut).isDisabled())

        use = ProtocolOptionsUse(destination: .off, recordOnly: false)
        XCTAssertTrue(try generateButton(sut).isDisabled(), "provider switched off")
        XCTAssertEqual(try notice(), ProtocolDestination.off.notice)

        use = ProtocolOptionsUse(destination: .local(host: "localhost"), recordOnly: true)
        XCTAssertTrue(try generateButton(sut).isDisabled(), "record-only switched on")
        XCTAssertNoThrow(try sut.inspect().find(text: ProtocolOptionsForm.recordOnlyNote))

        use = ProtocolOptionsUse(destination: .local(host: "localhost"), recordOnly: false)
        XCTAssertFalse(try generateButton(sut).isDisabled(), "a local provider again")
        XCTAssertEqual(try notice(), ProtocolDestination.local(host: "localhost").notice)
    }

    func testGenerateHandsTheTargetAndTheDraftsOptionsToTheRegenerator() throws {
        let options = ProtocolOptionsDraft(template: .file(name: "Board"), background: " Agenda ")
        let draft = RegenerateProtocolDraft(target: Self.target(), protocolOptions: options)
        var generated: [(ProtocolRegenerationTarget, MeetingProtocolOptions)] = []
        // swiftlint:disable:next trailing_closure
        let sut = makeView(draft: draft, onGenerate: { generated.append(($0, $1)) })

        try generateButton(sut).tap()

        XCTAssertEqual(generated.count, 1)
        XCTAssertEqual(generated.first?.0, Self.target())
        XCTAssertEqual(generated.first?.1, MeetingProtocolOptions(template: .file(name: "Board"), rawBackground: "Agenda"))
    }

    /// A failed run says why in the sheet, in the regenerator's own words.
    func testAFailedRunShowsItsReason() throws {
        let reason = ProtocolRegenerationError.generationFailed.localizedDescription

        XCTAssertNoThrow(try makeView(phase: .failed(reason)).inspect().find(text: reason))
    }

    func testTheTrashAndUnknownDateLinesFollowTheTarget() throws {
        let unknown = try makeView(draft: RegenerateProtocolDraft(target: Self.target(start: nil, hasProtocol: true))).inspect()
        let known = try makeView(draft: RegenerateProtocolDraft(target: Self.target(start: .now, hasProtocol: false))).inspect()

        XCTAssertNoThrow(try unknown.find(text: RegenerateProtocolView.trashNote))
        XCTAssertNoThrow(try unknown.find(text: RegenerateProtocolView.unknownDateNote))
        XCTAssertNoThrow(try unknown.find(text: "date unknown"))
        XCTAssertThrowsError(try known.find(text: RegenerateProtocolView.trashNote))
        XCTAssertThrowsError(try known.find(text: RegenerateProtocolView.unknownDateNote))
    }

    func testChooseFileShowsTheResolvedMeetingOrWhyNot() throws {
        let draft = RegenerateProtocolDraft()
        let chosen = URL(fileURLWithPath: "/out/protocols/20261013_0900_standup.md")
        var resolved: [URL] = []
        let sut = makeView(draft: draft, chooseFile: { chosen }, resolveFile: { url in
            resolved.append(url)
            if resolved.count == 1 { return Self.target() }
            throw ProtocolRegenerationError.noTranscript
        })
        let button = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.regenerateChooseFileButton).button()

        try button.tap()
        XCTAssertEqual(draft.target, Self.target())
        try button.tap()

        XCTAssertEqual(resolved, [chosen, chosen])
        XCTAssertNil(draft.target)
        XCTAssertEqual(draft.fileProblem, ProtocolRegenerationError.noTranscript.localizedDescription)
    }
}
