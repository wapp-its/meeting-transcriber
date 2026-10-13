import SwiftUI

/// The template picker, the background info editor and where that info goes,
/// shared by every window that makes a protocol from a person's choices.
///
/// The background text is typed into a window that none of the `/screenshot`,
/// `/ui/tree` or `/ui/press` allowlists may name, and only constant
/// identifiers are set here, never a template name or the text.
struct ProtocolOptionsForm: View {
    static let backgroundHint = "Participants, agenda, goal (optional)"
    static let recordOnlyNote = "Record-only mode is on: no protocol is made on this Mac, so these options are not used."

    let context: ProtocolOptionsContext
    @Bindable var draft: ProtocolOptionsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                templatePicker
                backgroundEditor
                Text(context.destination.notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(A11yID.protocolOptionsDestinationNotice)
            }
            .recordOnlyDisabled(context.recordOnly)

            if context.recordOnly {
                Text(Self.recordOnlyNote)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the picker shows for a template.
    static func label(for id: ProtocolTemplateID) -> String {
        switch id {
        case .builtIn: ProtocolTemplatesModel.builtInLabel
        case let .file(name): name
        }
    }

    private var templatePicker: some View {
        Picker("Template", selection: $draft.template) {
            ForEach(context.templates, id: \.self) { id in
                Text(Self.label(for: id)).tag(id)
            }
        }
        .accessibilityIdentifier(A11yID.protocolOptionsTemplatePicker)
    }

    /// A `TextEditor` has no placeholder on macOS, so the hint is an overlay
    /// shown while the text is empty.
    private var backgroundEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Background info")
            TextEditor(text: $draft.background)
                .frame(minHeight: 80)
                .overlay(alignment: .topLeading) {
                    if draft.background.isEmpty {
                        Text(Self.backgroundHint)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier(A11yID.protocolOptionsBackgroundEditor)
        }
    }
}
