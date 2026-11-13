// Settings → Output → Meeting Notes Templates: the default template, one row per
// template file with Edit and Delete, and Open Templates Folder.

import AppKit
import Observation
import SwiftUI

/// What the Meeting Notes Templates section shows and every write it makes,
/// held as a reference type so a test reads back the object the view writes to
/// (as with `SpeakerNamingRowState`, docs/architecture/gui-testing.md).
///
/// Reads the folder through the store on `reload()`, never caches template
/// text, and never writes the migration marker, so a migration that failed
/// earlier still runs at the next launch.
@Observable
@MainActor
final class ProtocolTemplatesModel {
    static let builtInLabel = "Standard (built-in)"

    static let helpText = """
    Templates are Markdown files in the templates folder: put a file there to add one. Edit opens a template \
    in your default app for Markdown files. {LANGUAGE}, {MEETING_DATE} and {MEETING_TIME} are filled in for \
    every template.
    """

    /// Template names in Finder's order, as of the last `reload()`.
    private(set) var names: [String] = []
    /// The error of the last delete or folder open; the next one that works
    /// clears it.
    private(set) var message: String?
    /// The template whose Delete was pressed and awaits confirmation.
    var pendingDeletion: String?

    private let store: ProtocolTemplateStore
    private let settings: AppSettings
    private let openFile: (URL) -> Void
    private let trashItem: (URL) throws -> Void

    init(
        store: ProtocolTemplateStore,
        settings: AppSettings,
        openFile: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        trashItem: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
    ) {
        self.store = store
        self.settings = settings
        self.openFile = openFile
        self.trashItem = trashItem
    }

    /// The effective default as the folder lists it, so a setting naming a
    /// missing file shows the built-in instead of a blank picker. Setting it
    /// writes the setting.
    var defaultSelection: ProtocolTemplateID {
        get { listed(store.effectiveDefault(settings.defaultProtocolTemplate)) }
        set { settings.defaultProtocolTemplate = newValue }
    }

    func reload() {
        names = store.names()
    }

    /// `id` spelt as the folder lists it. A Finder rename that changes only
    /// the case leaves the stored name resolving on a case-insensitive volume
    /// while matching no listed name, which would blank the picker.
    private func listed(_ id: ProtocolTemplateID) -> ProtocolTemplateID {
        guard case let .file(name) = id, !names.contains(name),
              let listedName = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return id }
        return .file(name: listedName)
    }

    func edit(_ name: String) {
        openFile(store.fileURL(named: name))
    }

    func requestDelete(_ name: String) {
        pendingDeletion = name
    }

    /// Moves the template to the Trash. Deleting the default makes the
    /// built-in the default.
    func confirmDelete(_ name: String) {
        pendingDeletion = nil
        // Read before the file goes: afterwards the default no longer resolves.
        let deletesTheDefault = defaultSelection == .file(name: name)
        do {
            try store.trash(name: name, trashItem: trashItem)
            if deletesTheDefault {
                settings.defaultProtocolTemplate = .builtIn
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    /// Creates the folder when it is missing, then opens it.
    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            message = nil
            openFile(store.directory)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The Meeting Notes Templates section. Rows and their buttons are addressed by
/// row index, never by template name, because a name is user input and
/// `/ui/tree` publishes identifiers unredacted.
struct ProtocolTemplatesSettingsView: View {
    /// SwiftUI keeps the first object it is handed for the view's lifetime, so
    /// a test holds the object every control of this section writes to.
    @State private var model: ProtocolTemplatesModel

    init(model: ProtocolTemplatesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Section("Meeting Notes Templates") {
            defaultPicker
            templateRows
            VStack(alignment: .leading, spacing: 4) {
                Button("Open Templates Folder") { model.openFolder() }
                    .accessibilityIdentifier(A11yID.protocolTemplatesOpenFolderButton)
                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(ProtocolTemplatesModel.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Parts

    /// Also carries the section's reloads: the picker is always shown, so
    /// they run exactly once however many rows the section has.
    private var defaultPicker: some View {
        Picker("Default template", selection: $model.defaultSelection) {
            Text(ProtocolTemplatesModel.builtInLabel).tag(ProtocolTemplateID.builtIn)
            ForEach(model.names, id: \.self) { name in
                Text(name).tag(ProtocolTemplateID.file(name: name))
            }
        }
        .accessibilityIdentifier(A11yID.protocolTemplateDefaultPicker)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }

    private var templateRows: some View {
        ForEach(Array(model.names.enumerated()), id: \.element) { index, name in
            HStack {
                Text(name)
                Spacer()
                Button("Edit") { model.edit(name) }
                    .accessibilityIdentifier(A11yID.protocolTemplateEdit(index))
                Button("Delete") { model.requestDelete(name) }
                    .accessibilityIdentifier(A11yID.protocolTemplateDelete(index))
                    .confirmationDialog(
                        "Move “\(name)” to the Trash?",
                        isPresented: deletionPrompt(for: name),
                        titleVisibility: .visible,
                    ) {
                        Button("Move to Trash", role: .destructive) { model.confirmDelete(name) }
                    }
            }
        }
    }

    /// Presented while `name` awaits confirmation. The button passes its own
    /// row's name, so the action does not depend on whether SwiftUI clears the
    /// binding before or after running it.
    private func deletionPrompt(for name: String) -> Binding<Bool> {
        Binding(
            get: { model.pendingDeletion == name },
            set: { presented in
                if !presented, model.pendingDeletion == name { model.pendingDeletion = nil }
            },
        )
    }
}
