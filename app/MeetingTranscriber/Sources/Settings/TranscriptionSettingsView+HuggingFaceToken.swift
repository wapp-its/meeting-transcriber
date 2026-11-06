import SwiftUI

/// The Hugging Face token row under the model picker. Its own file because the
/// view's main file is close to SwiftLint's length limits.
extension TranscriptionSettingsView {
    /// Write-only, for stock and custom models alike: the field holds only what is
    /// being typed, and nothing here reads the saved token. The caption asks the
    /// store whether one exists, which never reads it either, so rendering this
    /// view (as the view tests do, with the app's own Keychain item) cannot raise
    /// a Keychain prompt.
    @ViewBuilder var huggingFaceTokenRow: some View {
        HStack {
            SecureField("Hugging Face token", text: $settings.huggingFaceTokenDraft, prompt: Text("hf_\u{2026}"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { settings.saveHuggingFaceTokenDraft() }
                .accessibilityIdentifier(A11yID.huggingFaceTokenField)
            Button("Save") { settings.saveHuggingFaceTokenDraft() }
                .disabled(settings.huggingFaceTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier(A11yID.huggingFaceTokenSaveButton)
            if settings.huggingFaceTokenSaved {
                Button("Remove") { settings.removeHuggingFaceToken() }
                    .accessibilityIdentifier(A11yID.huggingFaceTokenRemoveButton)
            }
        }
        Text(huggingFaceTokenCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear { settings.refreshHuggingFaceTokenSaved() }
        if let problem = settings.huggingFaceTokenProblem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier(A11yID.huggingFaceTokenProblem)
        }
    }

    private var huggingFaceTokenCaption: String {
        if settings.huggingFaceTokenSaved {
            return "A token is saved. WhisperKit models download with it."
        }
        return "Optional, for private or gated models. Without a token, models download anonymously; "
            + "tokens elsewhere on this Mac are not used."
    }
}
