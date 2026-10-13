import AppKit
import Observation
import SwiftUI

/// A running GUI application that can be selected for recording.
struct RunningApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
}

/// Provides the list of running apps. Protocol for testability.
protocol RunningAppsProvider {
    @MainActor
    func runningApps() -> [RunningApp]
}

/// Production provider that reads from NSWorkspace.
struct SystemRunningAppsProvider: RunningAppsProvider {
    @MainActor
    func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let name = app.localizedName, !name.isEmpty else { return nil }
                return RunningApp(
                    id: app.processIdentifier,
                    name: name,
                    bundleIdentifier: app.bundleIdentifier,
                    icon: app.icon,
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// What the start dialog's list has selected.
enum StartRecordingSource: Hashable {
    case microphone
    case app(RunningApp)
}

/// What the start dialog holds while it is open. A reference type so a view
/// test can preset a selection, which `List(selection:)` does not let it make,
/// and read back what Start hands over.
@Observable
@MainActor
final class StartRecordingDraft {
    var source: StartRecordingSource?
    var title: String
    let protocolOptions: ProtocolOptionsDraft

    init(
        source: StartRecordingSource? = nil,
        title: String = "",
        protocolOptions: ProtocolOptionsDraft = ProtocolOptionsDraft(),
    ) {
        self.source = source
        self.title = title
        self.protocolOptions = protocolOptions
    }

    /// What Start records, nil without a source. An app recording without a
    /// typed title is named after the app; a microphone recording keeps its
    /// fixed title, so the field is not read for it.
    var request: ManualRecordingRequest? {
        switch source {
        case .none: nil
        case .microphone: .microphone
        case let .app(app): .app(pid: app.id, appName: app.name, title: title.isEmpty ? app.name : title)
        }
    }

    /// How every opening of the dialog starts: nothing selected, no title, the
    /// default template and no background.
    func reset(defaultTemplate: ProtocolTemplateID) {
        source = nil
        title = ""
        protocolOptions.reset(to: defaultTemplate)
    }
}

/// The start dialog ("Start Recording with Options…"): the microphone alone or
/// a running app, an optional title, and the protocol options.
@MainActor
struct AppPickerView: View {
    static let microphoneRowLabel = "Microphone only"

    let appsProvider: any RunningAppsProvider
    /// Whether a manual start would be refused right now. Pass the controller's
    /// wide predicate, not `AppState.isManualRecording`; see
    /// `AppPickerStartState.resolve`. Deliberately has no default: a default
    /// would let the wiring at the call site be deleted with every test green.
    let startWouldBeRefused: Bool
    /// "No Microphone (app audio only)": app recordings leave the microphone
    /// out, and "Microphone only" cannot start.
    let noMic: Bool
    /// Read when the window opens, so templates added in Finder since are listed.
    let optionsContext: () -> ProtocolOptionsContext
    let onStartRecording: (ManualRecordingRequest, MeetingProtocolOptions) -> Void
    let onCancel: () -> Void

    @State private var apps: [RunningApp] = []
    /// The context as read when the window opened, nil before that.
    @State private var openedContext: ProtocolOptionsContext?
    /// SwiftUI keeps the first object it is handed for the view's lifetime, so
    /// a test holds the object every control of the dialog writes to.
    @State private var draft: StartRecordingDraft

    init(
        appsProvider: any RunningAppsProvider,
        startWouldBeRefused: Bool,
        noMic: Bool,
        optionsContext: @escaping () -> ProtocolOptionsContext,
        draft: StartRecordingDraft = StartRecordingDraft(),
        onStartRecording: @escaping (ManualRecordingRequest, MeetingProtocolOptions) -> Void,
        onCancel: @escaping () -> Void,
    ) {
        self.appsProvider = appsProvider
        self.startWouldBeRefused = startWouldBeRefused
        self.noMic = noMic
        self.optionsContext = optionsContext
        _draft = State(initialValue: draft)
        self.onStartRecording = onStartRecording
        self.onCancel = onCancel
    }

    /// Bound in one place rather than inline in `body`, which keeps the button's
    /// two modifiers cheap to type-check.
    private var startState: AppPickerStartState {
        .resolve(source: draft.source, noMic: noMic, startWouldBeRefused: startWouldBeRefused)
    }

    private var context: ProtocolOptionsContext {
        openedContext ?? optionsContext()
    }

    /// Whether an app recording also takes the microphone.
    private var appRecordingCaption: String {
        noMic ? "App audio only, because No Microphone is set in Settings → Audio" : "App audio and microphone"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sourceList
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Meeting title (optional)", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(draft.source == .microphone)
                Text(appRecordingCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProtocolOptionsForm(context: context, draft: draft.protocolOptions)
                actions
            }
            .padding()
        }
        .frame(width: 440, height: 620)
        .onAppear {
            apps = appsProvider.runningApps()
            let opened = optionsContext()
            openedContext = opened
            draft.reset(defaultTemplate: opened.defaultTemplate)
        }
    }

    private var header: some View {
        HStack {
            Text("Start Recording")
                .font(.headline)
            Spacer()
            Button {
                apps = appsProvider.runningApps()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }

    private var sourceList: some View {
        List(selection: $draft.source) {
            Label(Self.microphoneRowLabel, systemImage: "mic")
                .tag(StartRecordingSource.microphone)
            ForEach(apps) { app in
                appRow(app)
                    .tag(StartRecordingSource.app(app))
            }
        }
        .frame(minHeight: 160)
    }

    private func appRow(_ app: RunningApp) -> some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 20, height: 20)
            }
            Text(app.name)
            Spacer()
            Text("PID \(app.id)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        if let explanation = startState.explanation {
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        HStack {
            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Start Recording") {
                guard let request = draft.request else { return }
                onStartRecording(request, draft.protocolOptions.options)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!startState.allowsStart)
        }
    }
}
