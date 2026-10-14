import SwiftUI

/// Settings → Transcription: where the custom vocabulary comes from, and for
/// the URL source its address, access token, "Update now" and status line.
///
/// - **Its own view**, not more properties of `TranscriptionSettingsView`:
///   that section's body sits close to the type-check limit CI enforces.
/// - **The URL controls render only for the URL source.** The token field is
///   bound to `AppSettings.remoteVocabularyToken`, which reads the Keychain on
///   every render, so with the default local-file source no render (a view
///   test's included) touches the Keychain.
/// - **Without a controller** (previews, tests that pass none) the status line
///   is hidden and "Update now" is disabled, since there is nothing to ask.
struct VocabularySourceSettingsView: View {
    @Bindable var settings: AppSettings
    var remoteVocabulary: RemoteVocabularyController?

    var body: some View {
        Picker("Vocabulary source", selection: $settings.vocabularySource) {
            ForEach(VocabularySource.allCases, id: \.self) { source in
                Text(source.label).tag(source)
            }
        }
        .accessibilityIdentifier(A11yID.vocabularySourcePicker)

        if settings.vocabularySource == .url {
            addressControls
            updateControls
        }
    }

    @ViewBuilder private var addressControls: some View {
        TextField("Vocabulary URL", text: $settings.remoteVocabularyURL, prompt: Text("https://\u{2026}"))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.remoteVocabularyURLField)
        SecureField("Access token (optional)", text: $settings.remoteVocabularyToken)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.remoteVocabularyTokenField)
    }

    @ViewBuilder private var updateControls: some View {
        Button("Update now") { remoteVocabulary?.refreshNow() }
            .disabled(updateDisabled)
            .accessibilityIdentifier(A11yID.remoteVocabularyUpdateButton)
        if let remoteVocabulary {
            Text(remoteVocabulary.status.message(formatDate: Self.formatDate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.remoteVocabularyStatus)
        }
        Text(Self.addressFormsCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Disabled while a check runs and while the address would not be fetched
    /// anyway, so a press always starts a check.
    private var updateDisabled: Bool {
        guard let remoteVocabulary, !remoteVocabulary.isChecking else { return true }
        if case .failure = RemoteVocabulary.validateAddress(settings.remoteVocabularyURL) { return true }
        return false
    }

    private static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The address forms that work with the Bearer token the fetcher sends.
    static let addressFormsCaption = "A text file with one term per line. "
        + "GitHub: https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>, "
        + "with a GitHub token for a private repository. "
        + "GitLab: https://<host>/api/v4/projects/<id or URL-encoded path>/repository/files/"
        + "<URL-encoded file path>/raw?ref=<branch>, with a GitLab token with the read_api scope. "
        + "The token is kept in the Keychain."
}
