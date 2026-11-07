import SwiftUI

/// The template picker, the background info editor and where that info goes,
/// shared by every window that makes a protocol from a person's choices.
///
/// The background text is typed into a window that none of the `/screenshot`,
/// `/ui/tree` or `/ui/press` allowlists may name, and only constant
/// identifiers are set here, never a template name or the text.
struct ProtocolOptionsForm: View {
    static let backgroundHint = "Participants, agenda, goal (optional)"
    static let recordOnlyNote = "Record-only mode is on: no meeting notes are made on this Mac, so these options are not used."

    let context: ProtocolOptionsContext
    @Bindable var draft: ProtocolOptionsDraft
    /// Told the height the line under the template picker adds, spacing
    /// included, and 0 without it, so a window of fixed height can grow by it.
    var onLineHeightChange: ((CGFloat) -> Void)?

    /// The space a `VStack` of this form puts above the line.
    private static let spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                templatePicker
                templateLine
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

    /// Writes through `chooseByHand`, so a pick is told apart from the rules
    /// moving the selection.
    private var templatePicker: some View {
        Picker("Template", selection: Binding(get: { draft.template }, set: { draft.chooseByHand($0) })) {
            ForEach(context.templates, id: \.self) { id in
                Text(Self.label(for: id)).tag(id)
            }
        }
        .accessibilityIdentifier(A11yID.protocolOptionsTemplatePicker)
    }

    /// Which rule picked the template, or why none did. Wraps rather than
    /// clips: it carries the meeting title and the rule's pattern.
    @ViewBuilder private var templateLine: some View {
        if let line = draft.line {
            Text(line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.protocolOptionsTemplateLine)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    onLineHeightChange?(height + Self.spacing)
                }
                .onDisappear { onLineHeightChange?(0) }
        }
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
