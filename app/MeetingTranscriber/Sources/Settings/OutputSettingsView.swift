import AppKit
import SwiftUI

/// Pure derivations used by `OutputSettingsView`. Extracted so the wrapping
/// logic can be unit-tested without instantiating a SwiftUI host.
enum OutputSettingsLogic {
    /// Abbreviate `url` for display by replacing the home-directory prefix
    /// with `~` so paths inside the user's home stay compact. Falls back to
    /// the full path when `url` is outside `home`. Matches at the path-
    /// component boundary so `home="/Users/alice"` doesn't abbreviate
    /// `/Users/alicebob/...` to `~bob/...`.
    static func displayPath(for url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        let prefixed = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefixed) else { return path }
        return "~/" + path.dropFirst(prefixed.count)
    }

    /// Merge the currently-selected value into a picker list so the user's
    /// choice survives even when the list doesn't contain it: a model that
    /// `/models` doesn't echo back (custom Ollama tags, in-flight rename,
    /// offline cache), or a protocol language stored by an older build or set
    /// outside the app. Returns `available` unchanged when `selected` is empty
    /// or already present.
    static func mergePickerOptions(available: [String], selected: String) -> [String] {
        guard !selected.isEmpty, !available.contains(selected) else { return available }
        return [selected] + available
    }
}

enum ConnectionTestResult {
    case success(String)
    case failure(String)
}

struct OutputSettingsView: View {
    @Bindable var settings: AppSettings
    var templateStore: ProtocolTemplateStore = .production
    /// The Recordings section's state. Nil leaves the section out, as without the
    /// check nothing can tell what a value would delete.
    @State private var retentionChoice: RetentionChoice?
    /// The templates section's state, which the rules section lists templates
    /// and reads the default through.
    @State private var templatesModel: ProtocolTemplatesModel
    @State private var templateRulesModel: TemplateRulesModel

    #if !APPSTORE
        @State private var claudeBinaries: [String] = ["claude"]
    #endif
    @State private var testingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var availableModels: [String] = []
    @State private var didAttemptConnectionTest = false

    init(settings: AppSettings, templateStore: ProtocolTemplateStore = .production, retentionChoice: RetentionChoice? = nil) {
        self.settings = settings
        self.templateStore = templateStore
        _retentionChoice = State(initialValue: retentionChoice)
        let templatesModel = ProtocolTemplatesModel(store: templateStore, settings: settings)
        _templatesModel = State(initialValue: templatesModel)
        _templateRulesModel = State(initialValue: TemplateRulesModel(templates: templatesModel, settings: settings))
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            // Output folder applies to record-only AND protocol mode, so this
            // section deliberately sits outside the .recordOnlyDisabled block.
            Section("Output Folder") {
                HStack {
                    Text("Output Folder")
                    Spacer()
                    Text(outputDirDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("Choose\u{2026}") {
                        chooseOutputFolder()
                    }

                    Button("Reset") {
                        settings.clearCustomOutputDir()
                    }
                    .disabled(settings.customOutputDirBookmark == nil)

                    Spacer()
                }
            }
            .accessibilityIdentifier(A11yID.outputFolderSection)

            if let retentionChoice {
                RecordingsSettingsSection(choice: retentionChoice)
            }

            NotionExportSettingsView(settings: settings)

            Section("Meeting Notes") {
                Toggle("Include full transcript in meeting notes", isOn: $settings.includeFullTranscriptInProtocol)
                    .accessibilityIdentifier(A11yID.includeFullTranscriptToggle)
                Toggle("Save raw transcript separately", isOn: $settings.saveRawTranscriptSeparately)
                    .accessibilityIdentifier(A11yID.saveRawTranscriptToggle)
                HelpfulToggle(
                    title: "Use AI meeting title for filenames",
                    help: SettingsHelp.aiTitleForFilenames,
                    isOn: $settings.useAITitleForFilenames,
                )
                .accessibilityIdentifier(A11yID.useAITitleForFilenamesToggle)

                Picker("LLM Provider", selection: $settings.protocolProvider) {
                    ForEach(ProtocolProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .accessibilityIdentifier(A11yID.protocolProviderPicker)

                providerConfigView

                Picker("Notes Language", selection: $settings.protocolLanguage) {
                    ForEach(languagePickerOptions, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
            }
            .accessibilityIdentifier(A11yID.protocolSection)
            .recordOnlyDisabled(settings.recordOnly)

            ProtocolTemplatesSettingsView(model: templatesModel)
                .recordOnlyDisabled(settings.recordOnly)
            TemplateRulesSettingsView(model: templateRulesModel)
                .recordOnlyDisabled(settings.recordOnly)
        }
        .formStyle(.grouped)
        .onAppear {
            #if !APPSTORE
                claudeBinaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            #endif
        }
    }

    @ViewBuilder
    private var providerConfigView: some View { // swiftlint:disable:this attributes
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI:
                Picker("Claude CLI", selection: $settings.claudeBin) {
                    ForEach(claudeBinaries, id: \.self) { bin in
                        Text(bin).tag(bin)
                    }
                }
                Text("Binary used to generate meeting notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("API Key")
                    Spacer()
                    SecureField("", text: $settings.claudeAPIKey)
                        .frame(width: 200)
                }
                Text("Optional. Leave empty to use your \"claude login\" session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only set this if that session can't stay signed in. An explicit key here is billed separately from your subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .codexCLI:
                CodexProviderSettingsView()

            case .customCommand:
                CustomCommandSettingsView(settings: settings)

            case .localModel:
                LocalModelSettingsView(model: LocalModelSettingsModel(settings: settings))
        #endif

        case .openAICompatible:
            openAIConfigView

        case .none:
            Text("No LLM summarization will be generated. Raw transcripts are retained if no meeting notes are saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openAIConfigView: some View { // swiftlint:disable:this attributes
        VStack(alignment: .leading, spacing: 4) {
            Text("Endpoint")
            TextField("http://localhost:1234/v1", text: $settings.openAIEndpoint)
                .textFieldStyle(.roundedBorder)
            Text("Base URL (e.g. http://localhost:1234/v1) or full chat-completions URL — both work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !availableModels.isEmpty {
            Picker("Model", selection: $settings.openAIModel) {
                ForEach(modelPickerOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        } else {
            HStack {
                Text("Model")
                Spacer()
                TextField("", text: $settings.openAIModel)
                    .frame(width: 200)
                    .multilineTextAlignment(.trailing)
            }
        }

        SamplingOverrideRow(
            parameter: .temperature,
            value: $settings.openAITemperature,
            toggleID: A11yID.openAITemperatureToggle,
            valueID: A11yID.openAITemperatureValue,
        )
        SamplingOverrideRow(
            parameter: .topP,
            value: $settings.openAITopP,
            toggleID: A11yID.openAITopPToggle,
            valueID: A11yID.openAITopPValue,
        )
        Text("Passed to the server only when switched on. Off leaves the server's own default in place.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Some servers reject both together, and reasoning models often reject any value.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Text("API Key")
            Spacer()
            SecureField("", text: $settings.openAIAPIKey)
                .frame(width: 200)
        }
        Text("Leave empty if your local server doesn't require authentication")
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("API Key Authentication", selection: $settings.openAIAPIKeyPlacement) {
            ForEach(OpenAIAPIKeyPlacement.allCases, id: \.self) { placement in
                Text(placement.label).tag(placement)
            }
        }
        .accessibilityIdentifier(A11yID.openAIAPIKeyPlacementPicker)

        if settings.openAIAPIKeyPlacement == .customHeader {
            HStack {
                Text("Header Name")
                Spacer()
                TextField("", text: $settings.openAIAPIKeyHeaderName)
                    .frame(width: 200)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameField)
            }
            Text("Sends the API key unchanged in this HTTP header, e.g. api-key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !OpenAIProtocolGenerator.isValidAPIKeyHeaderName(
                settings.openAIAPIKeyHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            ) {
                Text("Enter a valid HTTP header name. Content-Type, Content-Length, Host and other connection-level headers are reserved.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameWarning)
            }
        }

        HStack {
            Button {
                testConnection()
            } label: {
                HStack(spacing: 4) {
                    if testingConnection {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(availableModels.isEmpty ? "Fetch Models" : "Refresh Models")
                }
            }
            .disabled(testingConnection)

            if let result = connectionTestResult {
                switch result {
                case let .success(msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)

                case let .failure(msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .onAppear {
            if availableModels.isEmpty && !didAttemptConnectionTest {
                testConnection()
            }
        }
    }

    // MARK: - Helpers

    func testConnection() {
        testingConnection = true
        didAttemptConnectionTest = true
        connectionTestResult = nil
        Task {
            let apiKey = settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey
            let result = await OpenAIProtocolGenerator.testConnection(
                endpoint: settings.openAIEndpoint,
                model: settings.openAIModel,
                apiKey: apiKey,
                apiKeyPlacement: settings.openAIAPIKeyPlacement,
                apiKeyHeaderName: settings.openAIAPIKeyHeaderName,
            )
            testingConnection = false
            switch result {
            case let .success(models):
                availableModels = models
                if !models.isEmpty {
                    if !models.contains(settings.openAIModel) {
                        settings.openAIModel = models[0]
                    }
                    connectionTestResult = .success("Connected (\(models.count) models)")
                } else {
                    connectionTestResult = .success("Connected")
                }

            case let .failure(error):
                availableModels = []
                connectionTestResult = .failure(error.localizedDescription)
            }
        }
    }

    private var languagePickerOptions: [String] {
        OutputSettingsLogic.mergePickerOptions(available: AppSettings.protocolLanguages, selected: settings.protocolLanguage)
    }

    private var modelPickerOptions: [String] {
        OutputSettingsLogic.mergePickerOptions(available: availableModels, selected: settings.openAIModel)
    }

    private var outputDirDisplay: String {
        OutputSettingsLogic.displayPath(
            for: settings.effectiveOutputDir,
            home: FileManager.default.homeDirectoryForCurrentUser,
        )
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for recordings, transcripts and meeting notes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setCustomOutputDir(url)
    }
}

/// "Delete recordings automatically" and what it means. Stays enabled in record-only
/// mode, as it still applies to meetings recorded earlier. `RetentionChoice` decides
/// when a value is saved.
struct RecordingsSettingsSection: View {
    let choice: RetentionChoice

    var body: some View {
        Section("Recordings") {
            Picker("Delete recordings automatically", selection: Binding(get: { choice.shown }, set: { choice.choose($0) })) {
                ForEach(RecordingRetention.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            .accessibilityIdentifier(A11yID.recordingRetentionPicker)
            // `presenting`, so the buttons hold their preview whether SwiftUI clears
            // the binding before or after running them.
            .alert(choice.preview?.title ?? "", isPresented: previewShown, presenting: choice.preview) { preview in
                previewButtons(preview)
            } message: { preview in
                Text(preview.message)
            }

            if choice.isChecking {
                helpLine("Checking which meetings this would delete…")
            }
            if let value = choice.notChecked {
                helpLine("Could not read which meetings “\(value.title)” would delete, so the setting did not change. Try again later.")
            }
            helpLine("Counts from the recording date. Only audio this app recorded is deleted; imported files never are.")
            helpLine(
                "Audio stays until the meeting notes are saved and the speakers are named. "
                    + "Failed meetings, meetings marked Keep and record-only recordings keep their audio.",
            )
            helpLine("Deleted for good, not moved to the Trash. Copies in Time Machine backups or synced folders are not deleted.")
        }
    }

    /// Return answers Cancel, as this deletes for good. A SwiftUI alert has no default
    /// button of its own: measured on macOS 26, Return does nothing without this. A
    /// button takes one key, so Cancel gives up Escape for it.
    @ViewBuilder
    func previewButtons(_ preview: RetentionPreview) -> some View {
        Button("Cancel", role: .cancel) { choice.cancel() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(A11yID.retentionPreviewCancelButton)
        Button(preview.confirmButton, role: .destructive) { choice.confirm(preview) }
            .accessibilityIdentifier(A11yID.retentionPreviewConfirmButton)
    }

    private var previewShown: Binding<Bool> {
        Binding(
            get: { choice.preview != nil },
            set: { shown in
                if !shown { choice.cancel() }
            },
        )
    }

    private func helpLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One optional sampling override: a toggle that switches it on and, while it
/// is on, a field and stepper for the value. Switching it off clears the value,
/// so the parameter is left out of the request and the server default applies.
private struct SamplingOverrideRow: View {
    let parameter: OpenAISamplingParameter
    @Binding var value: Double?
    let toggleID: String
    let valueID: String

    var body: some View {
        Toggle("Override \(parameter.label)", isOn: isOverridden)
            .accessibilityIdentifier(toggleID)

        if value != nil {
            HStack {
                Text(parameter.label)
                Spacer()
                TextField(parameter.label, value: currentValue, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper(parameter.label, value: currentValue, in: parameter.range, step: 0.05)
                    .labelsHidden()
            }
            // A container element, so the identifier names the row instead
            // of being copied onto the label, field and stepper inside it.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(valueID)
        }
    }

    private var isOverridden: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? OpenAISamplingParameter.initialOverride : nil },
        )
    }

    private var currentValue: Binding<Double> {
        Binding(
            // The row only renders while overridden; the fallback just makes it total.
            get: { value ?? OpenAISamplingParameter.initialOverride },
            set: { value = $0 },
        )
    }
}
