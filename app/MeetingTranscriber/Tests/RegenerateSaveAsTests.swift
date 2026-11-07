@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The regenerate sheet's "Save as:" group (spec R1, A1, D3): which choice it
/// opens with, the small lines in their accepted wording, the report count in
/// the meeting lines, and Generate on a report name another meeting holds.
@MainActor
final class RegenerateSaveAsTests: XCTestCase {
    private static let basename = "20261013_0900_standup"
    private static let choices = ProtocolTemplateChoices(
        templates: [.builtIn, .file(name: "Short"), .file(name: "Q3")], defaultTemplate: .file(name: "Short"),
    )
    private static let use = ProtocolOptionsUse(destination: .remote(name: "Anthropic (Claude)"), recordOnly: false)

    /// A meeting with notes unless `hasProtocol` is false, whose folder holds `names`.
    private static func target(hasProtocol: Bool = true, names: Set<String> = [], otherMeetings: Set<String> = []) -> ProtocolRegenerationTarget {
        ProtocolRegenerationTarget(
            folder: URL(fileURLWithPath: "/out/protocols"),
            basename: basename,
            title: "Standup",
            meetingStartTime: .now,
            jobID: nil,
            files: ProtocolRegenerationFiles(
                transcriptFile: Data("[Anna] Hello".utf8), protocolFile: hasProtocol ? Data("# Old".utf8) : nil,
            ),
            reportFolder: MeetingReportFolder(
                basename: basename, names: names.union(["\(basename).txt", "\(basename).md"]), transcriptStems: otherMeetings,
            ),
        )
    }

    private func makeView(
        _ target: ProtocolRegenerationTarget,
        onGenerate: @escaping (ProtocolRegenerationTarget, MeetingProtocolOptions, ProtocolRegenerationOutput) -> Void = { _, _, _ in },
    ) throws -> (RegenerateProtocolView, RegenerateProtocolDraft) {
        let draft = RegenerateProtocolDraft()
        let close: () -> Void = {}
        let sut = RegenerateProtocolView(
            phase: .idle,
            templateChoices: { Self.choices },
            optionsUse: { Self.use },
            initialTarget: target,
            allowsChooseFile: false,
            chooseFile: { nil },
            resolveFile: { _ in target },
            draft: draft,
            onGenerate: onGenerate,
            onClose: close,
        )
        try sut.inspect().vStack().callOnAppear()
        return (sut, draft)
    }

    private func option(_ id: String, in sut: RegenerateProtocolView) throws -> InspectableView<ViewType.Button> {
        try sut.inspect().find(viewWithAccessibilityIdentifier: id).button()
    }

    private func generateDisabled(_ sut: RegenerateProtocolView) throws -> Bool {
        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.regenerateGenerateButton).button().isDisabled()
    }

    // MARK: - Opening

    func testAMeetingWithNotesOpensOnAnAdditionalReport() throws {
        let (sut, draft) = try makeView(Self.target())
        draft.saveAs = .mainProtocol
        try sut.inspect().vStack().callOnAppear()

        XCTAssertEqual(draft.saveAs, .additionalReport, "every opening starts on the additional report")
        XCTAssertNoThrow(try sut.inspect().find(text: RegenerateProtocolView.saveAsLabel))
        XCTAssertNoThrow(try option(A11yID.regenerateSaveAsReportOption, in: sut))
        XCTAssertNoThrow(try option(A11yID.regenerateSaveAsReplaceOption, in: sut))
    }

    func testAMeetingWithoutNotesShowsNoChoiceAndGetsItsMainProtocol() throws {
        var outputs: [ProtocolRegenerationOutput] = []
        let (sut, _) = try makeView(Self.target(hasProtocol: false)) { outputs.append($2) }

        XCTAssertThrowsError(try sut.inspect().find(text: RegenerateProtocolView.saveAsLabel))
        XCTAssertThrowsError(try option(A11yID.regenerateSaveAsReportOption, in: sut))
        XCTAssertThrowsError(try sut.inspect().find(text: RegenerateProtocolView.trashNote))
        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.regenerateGenerateButton).button().tap()
        XCTAssertEqual(outputs, [.mainProtocol])
    }

    // MARK: - The small lines

    func testTheSmallLinesInTheirAcceptedWording() throws {
        let (sut, _) = try makeView(Self.target())
        let body = try sut.inspect()

        XCTAssertNoThrow(try body.find(text: RegenerateProtocolView.reportOption))
        XCTAssertNoThrow(try body.find(text: "Saved as “\(Self.basename) (Short).md”. The current notes stay as they are."))
        XCTAssertNoThrow(try body.find(text: RegenerateProtocolView.replaceOption))
        XCTAssertNoThrow(try body.find(text: "The current notes are moved to the Trash and replaced."))
    }

    func testTheOrangeLineWhenTheTemplateAlreadyHasAReport() throws {
        let (sut, _) = try makeView(Self.target(names: ["\(Self.basename) (Short).md"]))

        let line = try sut.inspect().find(
            text: "Replaces the existing “\(Self.basename) (Short).md”, which is moved to the Trash. The current notes stay as they are.",
        )
        XCTAssertEqual(try line.attributes().foregroundColor(), .orange)
        XCTAssertFalse(try generateDisabled(sut))
    }

    func testTheLineFollowsTheChosenTemplate() throws {
        let (sut, draft) = try makeView(Self.target(names: ["\(Self.basename) (Short).md"]))

        draft.protocolOptions.template = .builtIn

        XCTAssertNoThrow(try sut.inspect().find(text: "Saved as “\(Self.basename) (Standard).md”. The current notes stay as they are."))
    }

    // MARK: - A name another meeting holds

    func testANameAnotherMeetingHoldsDisablesGenerateOnlyWhileTheReportIsChosen() throws {
        let (sut, draft) = try makeView(Self.target(names: ["\(Self.basename) (Q3).txt"], otherMeetings: ["\(Self.basename) (Q3)"]))
        draft.protocolOptions.template = .file(name: "Q3")

        let line = try sut.inspect().find(
            text: "“\(Self.basename) (Q3).md” belongs to another meeting, so this template cannot be saved as an additional report here.",
        )
        XCTAssertEqual(try line.attributes().foregroundColor(), .orange)
        XCTAssertTrue(try generateDisabled(sut))

        try option(A11yID.regenerateSaveAsReplaceOption, in: sut).tap()
        XCTAssertEqual(draft.saveAs, .mainProtocol)
        XCTAssertFalse(try generateDisabled(sut), "replacing the notes writes no report")
    }

    // MARK: - The meeting lines

    func testTheMeetingLinesCountTheReports() {
        let none = Self.target()
        let one = Self.target(names: ["\(Self.basename) (Short).md"])
        let two = Self.target(names: ["\(Self.basename) (Short).md", "\(Self.basename) (Minutes).md"])

        XCTAssertEqual(RegenerateProtocolView.fileLine(none), "\(Self.basename).md")
        XCTAssertEqual(RegenerateProtocolView.fileLine(one), "\(Self.basename).md · 1 additional report")
        XCTAssertEqual(RegenerateProtocolView.fileLine(two), "\(Self.basename).md · 2 additional reports")
    }

    func testTheSheetShowsTheCount() throws {
        let (sut, _) = try makeView(Self.target(names: ["\(Self.basename) (Short).md"]))

        XCTAssertNoThrow(try sut.inspect().find(text: "\(Self.basename).md · 1 additional report"))
    }
}
