import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The rows under the custom-vocabulary switch that say where the vocabulary
/// comes from, the local file or a URL. Their own file because the view's
/// main file is close to SwiftLint's length limits.
extension TranscriptionSettingsView {
    /// Where the vocabulary comes from: the local file or a URL. Hidden while the
    /// switch is off, which turns off both sources.
    @ViewBuilder var vocabularySourceRows: some View {
        if settings.customVocabularyEnabled {
            VocabularySourceSettingsView(settings: settings, remoteVocabulary: remoteVocabulary)
        }
    }

    /// Hidden while the switch is off, since no engine reads the file then, and
    /// for the URL source; the selection is kept for switching back.
    @ViewBuilder var customVocabularyFileRows: some View {
        if settings.customVocabularyEnabled, settings.vocabularySource == .file {
            customVocabularyRow
            customVocabularyValidation
        }
    }

    var customVocabularyRow: some View {
        HStack {
            TextField("Custom vocabulary file", text: Binding(
                get: { settings.customVocabularyPath },
                set: { settings.setCustomVocabularyPath($0) },
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.customVocabularyPathField)
            Button("Choose\u{2026}") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    settings.setCustomVocabularyFile(url)
                }
            }
        }
        .help(Self.vocabularyHelpText(for: settings.transcriptionEngine))
        .accessibilityIdentifier(A11yID.customVocabularyFileRow)
    }

    var customVocabularyValidation: some View {
        Text(settings.customVocabularyValidation.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear { settings.refreshCustomVocabularyValidation() }
            .onChange(of: settings.customVocabularyPath) { _, _ in
                settings.refreshCustomVocabularyValidation()
            }
    }
}
