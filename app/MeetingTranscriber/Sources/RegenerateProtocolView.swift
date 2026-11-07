import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the regenerate sheet holds while it is open. A reference type so a
/// view test presets the meeting and reads back what Generate hands over
/// (CLAUDE.md, GUI Testing, rung 2).
@Observable
@MainActor
final class RegenerateProtocolDraft {
    var target: ProtocolRegenerationTarget?
    /// Why the last chosen file could not be used.
    var fileProblem: String?
    let protocolOptions: ProtocolOptionsDraft
    /// "Save as:". Offered, and read, only for a meeting that has notes.
    var saveAs: ProtocolRegenerationOutput = .additionalReport

    init(target: ProtocolRegenerationTarget? = nil, protocolOptions: ProtocolOptionsDraft = ProtocolOptionsDraft()) {
        self.target = target
        self.protocolOptions = protocolOptions
    }

    /// How every opening starts: the meeting it was opened for, if any, the
    /// default template, no background, and an additional report (spec A1).
    func reset(target opened: ProtocolRegenerationTarget?, defaultTemplate: ProtocolTemplateID) {
        target = opened
        fileProblem = nil
        saveAs = .additionalReport
        protocolOptions.reset(to: defaultTemplate)
    }

    /// What Generate writes: a meeting without notes gets them as its main
    /// protocol, with no choice shown.
    var output: ProtocolRegenerationOutput {
        target?.hasProtocol == true ? saveAs : .mainProtocol
    }

    /// Where the chosen template's report would go, for a meeting with notes.
    var reportSlot: MeetingReportFolder.Slot? {
        guard let target, target.hasProtocol else { return nil }
        return target.reportSlot(for: protocolOptions.template)
    }

    /// The report's file name belongs to another meeting, and the report is chosen.
    var reportNameTaken: Bool {
        guard output == .additionalReport, case .otherMeeting = reportSlot else { return false }
        return true
    }
}

/// The All Recordings window's regenerate sheet: a new protocol for a finished
/// meeting, from another template or with background info. A row opens it for
/// its meeting, "Regenerate from File…" without one and with "Choose File…".
/// Shows background text, so it stays off the `/screenshot`, `/ui/tree` and
/// `/ui/press` allowlists, as the window it is shown over does.
@MainActor
struct RegenerateProtocolView: View {
    static let trashNote = "The current notes are moved to the Trash and replaced."
    static let saveAsLabel = "Save as:"
    static let reportOption = "An additional report"
    static let replaceOption = "Replace the current notes"
    static let unknownDateNote = "This meeting's date is not known, so the meeting notes show it as Unknown."
    static let noMeeting = "No recent meeting found"

    let phase: ProtocolRegenerator.Phase
    /// Read when the sheet opens, so templates added in Finder since are listed.
    let templateChoices: () -> ProtocolTemplateChoices
    /// Read on every redraw, so the notice and Generate follow a change in Settings.
    let optionsUse: () -> ProtocolOptionsUse
    /// The meeting the sheet opens with; nil opens it without one.
    let initialTarget: ProtocolRegenerationTarget?
    /// Whether "Choose File…" is offered: not when a row opened the sheet for
    /// its meeting.
    let allowsChooseFile: Bool
    /// Runs the open panel; a test hands in a URL instead.
    let chooseFile: () -> URL?
    let resolveFile: (URL) throws -> ProtocolRegenerationTarget
    let onGenerate: (ProtocolRegenerationTarget, MeetingProtocolOptions, ProtocolRegenerationOutput) -> Void
    let onClose: () -> Void

    @State private var openedChoices: ProtocolTemplateChoices?
    @State private var draft: RegenerateProtocolDraft

    init(
        phase: ProtocolRegenerator.Phase,
        templateChoices: @escaping () -> ProtocolTemplateChoices,
        optionsUse: @escaping () -> ProtocolOptionsUse,
        initialTarget: ProtocolRegenerationTarget?,
        allowsChooseFile: Bool,
        chooseFile: @escaping () -> URL?,
        resolveFile: @escaping (URL) throws -> ProtocolRegenerationTarget,
        draft: RegenerateProtocolDraft = RegenerateProtocolDraft(),
        onGenerate: @escaping (ProtocolRegenerationTarget, MeetingProtocolOptions, ProtocolRegenerationOutput) -> Void,
        onClose: @escaping () -> Void,
    ) {
        self.phase = phase
        self.templateChoices = templateChoices
        self.optionsUse = optionsUse
        self.initialTarget = initialTarget
        self.allowsChooseFile = allowsChooseFile
        self.chooseFile = chooseFile
        self.resolveFile = resolveFile
        _draft = State(initialValue: draft)
        self.onGenerate = onGenerate
        self.onClose = onClose
    }

    private var context: ProtocolOptionsContext {
        ProtocolOptionsContext(choices: openedChoices ?? templateChoices(), use: optionsUse())
    }

    /// The form's notice and record-only note say why when the settings are the reason.
    private var generateDisabled: Bool {
        let use = optionsUse()
        return draft.target == nil || phase == .running || use.destination == .off || use.recordOnly || draft.reportNameTaken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Regenerate Meeting Notes")
                .font(.headline)
            meetingSection
            Divider()
            ProtocolOptionsForm(context: context, draft: draft.protocolOptions)
            saveAsGroup
            targetNotes
            status
            actions
        }
        .padding()
        .frame(width: 440)
        .onAppear {
            let opened = templateChoices()
            openedChoices = opened
            draft.reset(target: initialTarget, defaultTemplate: opened.defaultTemplate)
        }
    }

    @ViewBuilder private var meetingSection: some View {
        if let target = draft.target {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title)
                    .bold()
                Text(Self.dateLine(target.meetingStartTime))
                    .foregroundStyle(.secondary)
                Text(Self.fileLine(target))
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
        if allowsChooseFile {
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
    }

    /// The accepted mockup's radio group, for a meeting that has notes.
    @ViewBuilder private var saveAsGroup: some View {
        if let target = draft.target, target.hasProtocol {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.saveAsLabel)
                saveAsOption(
                    .additionalReport, title: Self.reportOption, note: Self.reportNote(draft.reportSlot),
                    id: A11yID.regenerateSaveAsReportOption,
                )
                saveAsOption(.mainProtocol, title: Self.replaceOption, note: (Self.trashNote, false), id: A11yID.regenerateSaveAsReplaceOption)
            }
        }
    }

    private func saveAsOption(
        _ output: ProtocolRegenerationOutput, title: String, note: (text: String, warns: Bool), id: String,
    ) -> some View {
        let selected = draft.saveAs == output
        return Button {
            draft.saveAs = output
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(note.warns ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private var targetNotes: some View {
        if let target = draft.target {
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
                Text("Generating the meeting notes…")
            }

        case let .succeeded(url, warnings):
            Text("Meeting notes regenerated: \(url.lastPathComponent)")
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
            Button("Cancel") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(A11yID.regenerateCancelButton)

            Spacer()

            Button("Generate") {
                guard let target = draft.target else { return }
                onGenerate(target, draft.protocolOptions.options, draft.output)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(generateDisabled)
            .accessibilityIdentifier(A11yID.regenerateGenerateButton)
        }
    }

    /// The notes' file name, and how many additional reports the meeting has.
    static func fileLine(_ target: ProtocolRegenerationTarget) -> String {
        let name = target.protocolURL.lastPathComponent
        switch target.reports.count {
        case 0: return name
        case 1: return "\(name) · 1 additional report"
        case let count: return "\(name) · \(count) additional reports"
        }
    }

    /// The small line under "An additional report", and whether it is the orange one.
    static func reportNote(_ slot: MeetingReportFolder.Slot?) -> (text: String, warns: Bool) {
        switch slot {
        case let .free(fileName)?:
            ("Saved as “\(fileName)”. The current notes stay as they are.", false)

        case let .existing(fileName)?:
            ("Replaces the existing “\(fileName)”, which is moved to the Trash. The current notes stay as they are.", true)

        case let .otherMeeting(fileName)?:
            ("“\(fileName)” belongs to another meeting, so this template cannot be saved as an additional report here.", true)

        case nil:
            ("", false)
        }
    }

    static func dateLine(_ start: Date?) -> String {
        start.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "date unknown"
    }

    /// The open panel, limited to protocols and transcripts and starting in
    /// the protocols folder. Manual-QA-only, like every `NSOpenPanel`.
    static func chooseFile(startingIn outputDir: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Meeting Notes or a Transcript"
        panel.allowedContentTypes = ["md", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = outputDir.appendingPathComponent("protocols", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
