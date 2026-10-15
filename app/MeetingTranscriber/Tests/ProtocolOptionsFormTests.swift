@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// One wiring test per control of the shared options form, located by `A11yID`
/// constants: the controls write the draft the test holds, and what the form
/// says comes from its context.
@MainActor
final class ProtocolOptionsFormTests: XCTestCase {
    private func makeContext(
        destination: ProtocolDestination = .remote(name: "Anthropic (Claude)"),
        recordOnly: Bool = false,
    ) -> ProtocolOptionsContext {
        ProtocolOptionsContext(
            templates: [.builtIn, .file(name: "Board"), .file(name: "Retro")],
            destination: destination,
            recordOnly: recordOnly,
        )
    }

    func testTemplatePickerWritesTheDraft() throws {
        let draft = ProtocolOptionsDraft()
        let form = ProtocolOptionsForm(context: makeContext(), draft: draft)

        try form.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsTemplatePicker)
            .find(ViewType.Picker.self)
            .select(value: ProtocolTemplateID.file(name: "Retro"))

        XCTAssertEqual(draft.template, .file(name: "Retro"))
    }

    func testBackgroundEditorWritesTheDraft() throws {
        let draft = ProtocolOptionsDraft()
        let form = ProtocolOptionsForm(context: makeContext(), draft: draft)

        try form.inspect()
            .find(ViewType.TextEditor.self) { try $0.accessibilityIdentifier() == A11yID.protocolOptionsBackgroundEditor }
            .setInput("Agenda: budget")

        XCTAssertEqual(draft.background, "Agenda: budget")
    }

    func testNoticeComesFromTheContextsDestination() throws {
        let destination = ProtocolDestination.local(host: "localhost")
        let form = ProtocolOptionsForm(context: makeContext(destination: destination), draft: ProtocolOptionsDraft())

        let notice = try form.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsDestinationNotice)
            .text()
            .string()

        XCTAssertEqual(notice, destination.notice)
    }

    func testRecordOnlyNoteShowsOnlyInRecordOnlyMode() throws {
        let recordOnly = ProtocolOptionsForm(context: makeContext(recordOnly: true), draft: ProtocolOptionsDraft())
        let normal = ProtocolOptionsForm(context: makeContext(recordOnly: false), draft: ProtocolOptionsDraft())

        XCTAssertNoThrow(try recordOnly.inspect().find(text: ProtocolOptionsForm.recordOnlyNote))
        XCTAssertThrowsError(try normal.inspect().find(text: ProtocolOptionsForm.recordOnlyNote))
    }
}
