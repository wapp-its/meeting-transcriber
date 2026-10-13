import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the Regenerate Protocol window holds while it is open. A reference
/// type so a view test presets the meeting and reads back what Generate hands
/// over (CLAUDE.md, GUI Testing, rung 2).
@Observable
@MainActor
final class RegenerateProtocolDraft {
    var target: ProtocolRegenerationTarget?
    /// Why the last chosen file could not be used.
    var fileProblem: String?
    let protocolOptions: ProtocolOptionsDraft

    init(target: ProtocolRegenerationTarget? = nil, protocolOptions: ProtocolOptionsDraft = ProtocolOptionsDraft()) {
        self.target = target
        self.protocolOptions = protocolOptions
    }

    /// How every opening starts: the latest finished meeting, the default
    /// template and no background.
    func reset(latest: ProtocolRegenerationTarget?, defaultTemplate: ProtocolTemplateID) {
        target = latest
        fileProblem = nil
        protocolOptions.reset(to: defaultTemplate)
    }
}

/// "Regenerate Protocol…": a new protocol for a finished meeting, from another
/// template or with background info. Shows background text, so it stays off
/// the `/screenshot`, `/ui/tree` and `/ui/press` allowlists.
@MainActor
struct RegenerateProtocolView: View {
    static let windowID = "regenerate-protocol"
    static let trashNote = "The current protocol is moved to the Trash and replaced."
    static let unknownDateNote = "This meeting's date is not known, so the protocol shows it as Unknown."
    static let noMeeting = "No recent meeting found"

    let phase: ProtocolRegenerator.Phase
    /// Read when the window opens, so templates added in Finder since are listed.
    let optionsContext: () -> ProtocolOptionsContext
    let latestTarget: () -> ProtocolRegenerationTarget?
    /// Runs the open panel; a test hands in a URL instead.
    let chooseFile: () -> URL?
    let resolveFile: (URL) throws -> ProtocolRegenerationTarget
    let onGenerate: (ProtocolRegenerationTarget, MeetingProtocolOptions) -> Void
    let onClose: () -> Void

    @State private var openedContext: ProtocolOptionsContext?
    @State private var draft: RegenerateProtocolDraft

    init(
        phase: ProtocolRegenerator.Phase,
        optionsContext: @escaping () -> ProtocolOptionsContext,
        latestTarget: @escaping () -> ProtocolRegenerationTarget?,
        chooseFile: @escaping () -> URL?,
        resolveFile: @escaping (URL) throws -> ProtocolRegenerationTarget,
        draft: RegenerateProtocolDraft = RegenerateProtocolDraft(),
        onGenerate: @escaping (ProtocolRegenerationTarget, MeetingProtocolOptions) -> Void,
        onClose: @escaping () -> Void,
    ) {
        self.phase = phase
        self.optionsContext = optionsContext
        self.latestTarget = latestTarget
        self.chooseFile = chooseFile
        self.resolveFile = resolveFile
        _draft = State(initialValue: draft)
        self.onGenerate = onGenerate
        self.onClose = onClose
    }

    private var context: ProtocolOptionsContext {
        openedContext ?? optionsContext()
    }

    /// The form's notice and record-only note say why when the context is the reason.
    private var generateDisabled: Bool {
        draft.target == nil || phase == .running || context.destination == .off || context.recordOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Regenerate Protocol")
                .font(.headline)
            meetingSection
            Divider()
            ProtocolOptionsForm(context: context, draft: draft.protocolOptions)
            targetNotes
            status
            actions
        }
        .padding()
        .frame(width: 440)
        .onAppear {
            let opened = optionsContext()
            openedContext = opened
            draft.reset(latest: latestTarget(), defaultTemplate: opened.defaultTemplate)
        }
    }

    @ViewBuilder private var meetingSection: some View {
        if let target = draft.target {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title)
                    .bold()
                Text(Self.dateLine(target.meetingStartTime))
                    .foregroundStyle(.secondary)
                Text(target.protocolURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(Self.noMeeting)
                .foregroundStyle(.secondary)
        }
        if let problem = draft.fileProblem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button("Choose File…") {
            guard let url = chooseFile() else { return }
            do {
                draft.target = try resolveFile(url)
                draft.fileProblem = nil
            } catch {
                draft.target = nil
                draft.fileProblem = error.localizedDescription
            }
        }
        .accessibilityIdentifier(A11yID.regenerateChooseFileButton)
    }

    @ViewBuilder private var targetNotes: some View {
        if let target = draft.target {
            if target.hasProtocol {
                Text(Self.trashNote)
                    .font(.caption)
            }
            if target.meetingStartTime == nil {
                Text(Self.unknownDateNote)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .running:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating the protocol…")
            }

        case let .succeeded(url, warnings):
            Text("Protocol regenerated: \(url.lastPathComponent)")
            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .failed(reason):
            Text(reason)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack {
            Button("Close") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Generate") {
                guard let target = draft.target else { return }
                onGenerate(target, draft.protocolOptions.options)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(generateDisabled)
            .accessibilityIdentifier(A11yID.regenerateGenerateButton)
        }
    }

    static func dateLine(_ start: Date?) -> String {
        start.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "date unknown"
    }

    /// The open panel, limited to protocols and transcripts and starting in
    /// the protocols folder. Manual-QA-only, like every `NSOpenPanel`.
    static func chooseFile(startingIn outputDir: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Protocol or Transcript"
        panel.allowedContentTypes = ["md", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = outputDir.appendingPathComponent("protocols", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
