// Settings → Output → Template Rules: the rules that pick a new meeting's
// template from its title, and the try-a-title field.

import Observation
import SwiftUI

/// What the Template Rules section shows and every write it makes, held as a
/// reference type so a test reads back the object the view writes to (as with
/// `ProtocolTemplatesModel`).
///
/// Lists templates and reads the default through the templates section's
/// model, so a template created or deleted there shows here at once.
@Observable
@MainActor
final class TemplateRulesModel {
    /// One row as Settings shows it. A pattern that is refused while typed is
    /// never saved: `pattern` keeps the one in force.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        /// What the pattern field holds.
        var text: String
        var template: ProtocolTemplateID
        /// The pattern in force: the stored one, or the last valid text. Nil
        /// for a new row until its text is valid; such a row has no effect.
        var pattern: String?
    }

    private(set) var rows: [Row]
    /// What the try-a-title field holds.
    var tryTitle = ""

    private let templates: ProtocolTemplatesModel
    private let settings: AppSettings

    init(templates: ProtocolTemplatesModel, settings: AppSettings) {
        self.templates = templates
        self.settings = settings
        rows = settings.protocolTemplateRules.map { Row(text: $0.pattern, template: $0.template, pattern: $0.pattern) }
    }

    /// Template names in Finder's order, as the templates section last listed them.
    var names: [String] {
        templates.names
    }

    /// The choices of a row's template picker: those of "Default template".
    var templateChoices: [ProtocolTemplateID] {
        [.builtIn] + names.map { .file(name: $0) }
    }

    // MARK: - Edits

    /// A new row at the bottom, on the default template, with an empty pattern
    /// that is not saved until it is valid.
    func addRule() {
        rows.append(Row(text: "", template: templates.defaultSelection, pattern: nil))
    }

    /// Saves `text` as the row's pattern only when it is valid; otherwise the
    /// pattern in force stays.
    func setText(_ text: String, of id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].text = text
        if ProtocolTemplateRulePattern.refusal(for: text) == nil {
            rows[index].pattern = text
        }
        save()
    }

    func setTemplate(_ template: ProtocolTemplateID, of id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].template = template
        save()
    }

    func moveUp(_ id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), index > 0 else { return }
        rows.swapAt(index, index - 1)
        save()
    }

    func moveDown(_ id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), index < rows.count - 1 else { return }
        rows.swapAt(index, index + 1)
        save()
    }

    func delete(_ id: Row.ID) {
        rows.removeAll { $0.id == id }
        save()
    }

    // MARK: - What a row shows

    /// Why the row's field text cannot be saved, nil when it can.
    func refusal(of row: Row) -> ProtocolTemplateRulePattern.Refusal? {
        ProtocolTemplateRulePattern.refusal(for: row.text)
    }

    /// The template's name when its file is no longer in the folder.
    func missingTemplate(of row: Row) -> String? {
        guard case let .file(name) = row.template, ProtocolTemplateRules.present(row.template, in: names) == nil
        else { return nil }
        return name
    }

    /// The picker's selection: the template spelt as the folder lists it, so a
    /// Finder rename that changed only the case does not blank the picker.
    func selection(of row: Row) -> ProtocolTemplateID {
        ProtocolTemplateRules.present(row.template, in: names) ?? row.template
    }

    // MARK: - Try a title

    /// What the rules as they stand pick for the typed title; nil for an
    /// empty field. Rules are numbered by row, as Settings shows them.
    var tryChoice: ProtocolTemplateRules.Choice? {
        guard !tryTitle.isEmpty else { return nil }
        return ProtocolTemplateRules.resolve(
            title: tryTitle,
            rules: rows.map { ProtocolTemplateRule(pattern: $0.pattern ?? "", template: $0.template) },
            templateNames: names,
            defaultTemplate: templates.defaultSelection,
        )
    }

    /// The result line in the accepted wording, the template name in bold. Each
    /// rule that ran out of time gets a sentence first.
    static func tryText(for choice: ProtocolTemplateRules.Choice) -> AttributedString {
        var text = AttributedString(choice.timedOutRules.map { index in
            "Rule \(index + 1) took too long on this title and is skipped. "
        }.joined())
        var name = AttributedString(ProtocolOptionsForm.label(for: choice.template))
        name.inlinePresentationIntent = .stronglyEmphasized
        switch choice.source {
        case let .rule(index, pattern):
            text += AttributedString("Gets ") + name + AttributedString(", from rule \(index + 1) (\(pattern)).")

        case .defaultTemplate:
            text += AttributedString("Gets the default template, ") + name + AttributedString(": no rule matches.")
        }
        return text
    }

    // MARK: - Saving

    /// Writes the rows that have a pattern in force, in their order. A row
    /// without one is shown but never stored.
    private func save() {
        let rules = rows.compactMap { row in
            row.pattern.map { ProtocolTemplateRule(pattern: $0, template: row.template) }
        }
        if rules != settings.protocolTemplateRules {
            settings.protocolTemplateRules = rules
        }
    }
}

/// The Template Rules section, directly under Meeting Notes Templates. Rows and
/// their controls are addressed by row position, never by pattern or template
/// name, because both are user input and `/ui/tree` publishes identifiers
/// unredacted. The controls are bound by the row's id, so a row that moves
/// keeps what is typed into it.
struct TemplateRulesSettingsView: View {
    static let caption = """
    A new meeting whose title matches a pattern gets that rule's template. Rules are tried from the top, \
    and the first match wins. When no rule matches, the meeting gets the default template. A pattern is a \
    regular expression and ignores upper and lower case: “daily” matches “Team Daily”.
    """

    static let titleNote = """
    A detected meeting has its real window title only when Meeting Transcriber has the Screen Recording \
    permission. Without it, the title is the app's name followed by “Call”, for example “Microsoft Teams \
    Call”. An imported file's title is its file name.
    """

    /// SwiftUI keeps the first object it is handed for the view's lifetime, so
    /// a test holds the object every control of this section writes to.
    @State private var model: TemplateRulesModel

    init(model: TemplateRulesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Section("Template Rules") {
            secondary(Self.caption)
            HStack {
                Text("Meeting title contains")
                Spacer()
                Text("Template")
                    .frame(width: Self.pickerWidth + Self.buttonsWidth, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                ruleRow(row, at: index)
            }
            Button("Add Rule") { model.addRule() }
                .accessibilityIdentifier(A11yID.templateRulesAddButton)
            tryTitle
        }
    }

    /// Wide enough for "<name> (missing)" with a name of about 14 characters.
    private static let pickerWidth: CGFloat = 200
    private static let buttonsWidth: CGFloat = 80

    // MARK: - Parts

    private func ruleRow(_ row: TemplateRulesModel.Row, at index: Int) -> some View {
        let refusal = model.refusal(of: row)
        let missing = model.missingTemplate(of: row)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(index + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                TextField("Pattern", text: Binding(get: { row.text }, set: { model.setText($0, of: row.id) }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .overlay(border(refusal == nil ? nil : .red))
                    .accessibilityIdentifier(A11yID.templateRulePatternField(index))
                templatePicker(row, missing: missing)
                    .overlay(border(missing == nil ? nil : .orange))
                    .accessibilityIdentifier(A11yID.templateRuleTemplatePicker(index))
                rowButtons(row, at: index)
            }
            if let missing {
                Text(
                    "The template “\(missing)” is no longer in the templates folder, so this rule is skipped. "
                        + "It works again when the file is back.",
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let refusal {
                Text(refusal.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func templatePicker(_ row: TemplateRulesModel.Row, missing: String?) -> some View {
        Picker("Template", selection: Binding(get: { model.selection(of: row) }, set: { model.setTemplate($0, of: row.id) })) {
            ForEach(model.templateChoices, id: \.self) { id in
                Text(ProtocolOptionsForm.label(for: id)).tag(id)
            }
            if let missing {
                Text("\(missing) (missing)").tag(row.template)
            }
        }
        .labelsHidden()
        .frame(width: Self.pickerWidth)
    }

    private func rowButtons(_ row: TemplateRulesModel.Row, at index: Int) -> some View {
        HStack(spacing: 4) {
            Button { model.moveUp(row.id) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0)
                .help("Move Up")
                .accessibilityLabel("Move Up")
                .accessibilityIdentifier(A11yID.templateRuleMoveUp(index))
            Button { model.moveDown(row.id) } label: { Image(systemName: "arrow.down") }
                .disabled(index == model.rows.count - 1)
                .help("Move Down")
                .accessibilityLabel("Move Down")
                .accessibilityIdentifier(A11yID.templateRuleMoveDown(index))
            Button { model.delete(row.id) } label: { Image(systemName: "trash") }
                .help("Delete")
                .accessibilityLabel("Delete")
                .accessibilityIdentifier(A11yID.templateRuleDelete(index))
        }
        .buttonStyle(.borderless)
        .frame(width: Self.buttonsWidth, alignment: .trailing)
    }

    private var tryTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Try a title", text: $model.tryTitle)
                .accessibilityIdentifier(A11yID.templateRulesTryTitleField)
            if let choice = model.tryChoice {
                Text(TemplateRulesModel.tryText(for: choice))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(A11yID.templateRulesTryResult)
            }
            secondary(Self.titleNote)
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func border(_ color: Color?) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .stroke(color ?? .clear, lineWidth: 1)
            .allowsHitTesting(false)
    }
}
