import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker?
    let onStartStop: () -> Void
    let onRecordApp: () -> Void
    let onRecordMicrophone: () -> Void
    /// Whether the user set "No Microphone (app audio only)". Only reaches the
    /// microphone item, which it disables with a reason.
    let noMic: Bool
    /// The *wide* predicate: a manual recording that is running, or a start that
    /// has registered and not yet built its loop. `state == .recording` misses
    /// that second window, and the microphone item would sit enabled through it
    /// handing back a dead click, which is what `AppPickerStartState` was built
    /// to avoid on the picker.
    let manualRecordingPendingOrActive: Bool
    /// Stops whatever is recording, a detected meeting included; set only while a recording runs.
    let onStopManualRecording: (() -> Void)?
    let onOpenLastProtocol: () -> Void
    let onOpenProtocol: (URL) -> Void
    let onOpenProtocolsFolder: () -> Void
    let onOpenSettings: () -> Void
    let onNameSpeakers: (() -> Void)?
    let onProcessFiles: () -> Void
    let onDismissJob: (UUID) -> Void
    let onQuit: () -> Void
    /// Stores a chosen microphone's UID, empty for System Default.
    var onSelectMicrophone: (String) -> Void = { _ in }
    /// The Microphone entry; nil leaves it out.
    var microphoneMenu: MicrophoneMenuState?

    private var state: TranscriberState {
        status?.state ?? .idle
    }

    private var microphoneAvailability: MicrophoneRecordingAvailability {
        .resolve(
            isRecording: manualRecordingPendingOrActive || state == .recording,
            noMic: noMic,
        )
    }

    /// Hoisted out of the `ViewBuilder`: an `Optional.map` returning an
    /// interpolated string, coalesced with `??`, inside an overloaded `Text`
    /// initializer is the exact shape that blew the 300 ms type-check budget in
    /// this file before (see the note on `body`).
    private func meetingLabel(_ meeting: MeetingInfo) -> String {
        guard let pid = meeting.pid else { return meeting.app }
        return "\(meeting.app) (PID \(pid))"
    }

    // The sections below are hoisted out of `body` into separate computed
    // properties so each is type-checked independently. Inlined as one
    // expression, the `body` getter crossed the 300 ms type-check budget that
    // the analyze build enforces (-warn-long-expression-type-checking=300 with
    // -warnings-as-errors), failing the build on slower CI hardware. The view
    // order, dividers, and conditionals are unchanged.
    var body: some View {
        statusHeader
        sessionControls
        meetingInfo
        errorInfo

        Divider()

        watchControls
        microphoneSection
        processingQueue

        Divider()

        protocolActions
        updateSection

        Divider()

        settingsButton

        Divider()

        quitButton
    }

    // MARK: - Body sections

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(state.label, systemImage: state.icon)
                .font(.headline)

            if let detail = status?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var meetingInfo: some View {
        if let meeting = status?.meeting {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                // A microphone-only recording owns no process, so there is no
                // PID to show and a placeholder would only read as a real one.
                Text(meetingLabel(meeting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var errorInfo: some View {
        if let error = status?.error, state == .error {
            Divider()
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
        }
    }

    /// The control for the current state, directly under the status line with
    /// no divider in between. One item per line, like every menu item (see
    /// `jobRow`): a control added here goes on its own line under these.
    @ViewBuilder private var sessionControls: some View {
        if let onStopManualRecording {
            Button {
                onStopManualRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".")
        } else {
            watchToggle
        }
    }

    @ViewBuilder private var watchControls: some View {
        // While a recording holds the line under the status, watching stays
        // reachable here; otherwise the toggle is already up there.
        if onStopManualRecording != nil {
            watchToggle
        } else if state != .recording {
            Button {
                onRecordMicrophone()
            } label: {
                Label("Record Microphone Only", systemImage: "mic.circle")
            }
            .keyboardShortcut("m")
            .disabled(!microphoneAvailability.allowsStart)
            .help(microphoneAvailability.disabledReason ?? "Record the system microphone, with no app audio")

            Button {
                onRecordApp()
            } label: {
                Label(Self.recordAppLabel(noMic: noMic), systemImage: "record.circle")
            }
            .keyboardShortcut("r")
        }

        if let onNameSpeakers {
            Button {
                onNameSpeakers()
            } label: {
                Label("Name Speakers...", systemImage: "person.2.fill")
            }
            .keyboardShortcut("n")
        }

        Button {
            onProcessFiles()
        } label: {
            Label("Process Audio/Video Files...", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("p")
    }

    /// Which microphone recordings use, switchable in a submenu; with "No
    /// Microphone" on, one disabled line. Every string comes from
    /// `MicrophoneMenuState`, so nothing is assembled here (see the note on
    /// `body`).
    @ViewBuilder private var microphoneSection: some View {
        if let microphoneMenu {
            if microphoneMenu.isEnabled {
                Menu {
                    microphonePicker(microphoneMenu)
                    if let hint = microphoneMenu.hint {
                        Text(hint)
                    }
                } label: {
                    Label(microphoneMenu.title, systemImage: "mic")
                }
            } else {
                Label(microphoneMenu.title, systemImage: "mic.slash")
            }
        }
    }

    /// An inline picker, so the menu shows each device as an item with the
    /// checkmark on the current choice. Choosing one only stores it; nothing
    /// here touches the macOS default input.
    private func microphonePicker(_ menu: MicrophoneMenuState) -> some View {
        Picker("Microphone", selection: Binding(get: { menu.checkedUID }, set: { onSelectMicrophone($0) })) {
            ForEach(menu.items, id: \.uid) { item in
                Text(item.label)
                    .disabled(!item.isEnabled)
                    .tag(item.uid)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityIdentifier(A11yID.menuMicrophonePicker)
    }

    @ViewBuilder private var processingQueue: some View {
        if !pipelineQueue.jobs.isEmpty {
            Divider()
            Label("Processing", systemImage: "gearshape.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(pipelineQueue.jobs.enumerated()), id: \.element.id) { index, job in
                jobRow(job, index: index)
            }
        }
    }

    @ViewBuilder private var protocolActions: some View {
        if let protocolPath = status?.protocolPath {
            Button {
                onOpenLastProtocol()
            } label: {
                Label("Open Last Protocol", systemImage: "doc.text")
            }
            .keyboardShortcut("o")
            .disabled(protocolPath.isEmpty)
        }

        Button {
            onOpenProtocolsFolder()
        } label: {
            Label("Open Protocols Folder", systemImage: "folder")
        }
    }

    @ViewBuilder private var updateSection: some View {
        if let update = updateChecker?.availableUpdate {
            Divider()
            Button {
                NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL)
            } label: {
                Label(
                    "Update Available: \(update.tagName)",
                    systemImage: "arrow.down.circle.fill",
                )
            }
        }
    }

    /// Rendered by `sessionControls` or `watchControls`, never both, so its
    /// label, icon and shortcut have one definition.
    private var watchToggle: some View {
        Button {
            onStartStop()
        } label: {
            if isWatching {
                Label("Stop Watching for Meetings", systemImage: "stop.fill")
            } else {
                Label("Start Watching for Meetings", systemImage: "play.fill")
            }
        }
        .keyboardShortcut("s")
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Label("Settings...", systemImage: "gear")
        }
        .keyboardShortcut(",")
    }

    private var quitButton: some View {
        Button {
            onQuit()
        } label: {
            Text("Quit")
        }
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    /// "Record App..." alone reads as app audio only, while the recording
    /// also takes the microphone unless "No Microphone" is set.
    static func recordAppLabel(noMic: Bool) -> String {
        noMic ? "Record App Audio..." : "Record App + Microphone..."
    }

    /// One menu item per job, its actions in a submenu. A menu-style
    /// `MenuBarExtra` cannot lay anything out side by side: an `HStack` row
    /// came out as one menu item per part, so the status dot and the spacer
    /// became empty lines and the buttons stood one below the other.
    private func jobRow(_ job: PipelineJob, index: Int) -> some View {
        Menu {
            Text(job.meetingTitle)
            jobStateLabel(job)
            Divider()
            jobActions(job, index: index)
        } label: {
            Label(jobMenuTitle(job), systemImage: JobMenuSummary.symbol(of: job))
        }
    }

    /// Hoisted out of the `ViewBuilder` for the type-check budget (see the
    /// note on `body`).
    private func jobMenuTitle(_ job: PipelineJob) -> String {
        let status = JobMenuSummary.status(of: job, progress: stageProgressText(job))
        return "\(job.meetingTitle) — \(status)"
    }

    @ViewBuilder
    private func jobActions(_ job: PipelineJob, index: Int) -> some View {
        if job.state == .done, let path = job.protocolPath ?? job.transcriptPath {
            Button("Open") { onOpenProtocol(path) }
        }
        if job.state == .speakerNamingPending {
            Button("Name Speakers") { onNameSpeakers?() }
        }
        if job.state == .waiting || job.state == .transcribing
            || job.state == .diarizing || job.state == .generatingProtocol {
            Button("Cancel") { pipelineQueue.cancelJob(id: job.id) }
        }
        retryButton(job, index: index)
        if job.state == .done || job.state == .error || job.state == .speakerNamingPending {
            Button("Dismiss") { onDismissJob(job.id) }
        }
    }

    /// Runs a failed job again from its audio, instead of the user having to
    /// find the staged recording and import it by hand.
    @ViewBuilder
    private func retryButton(_ job: PipelineJob, index: Int) -> some View {
        if pipelineQueue.canRetryJob(id: job.id) {
            Button("Retry") { pipelineQueue.retryJob(id: job.id) }
                .accessibilityIdentifier(A11yID.jobRetryButton(index))
        }
    }

    private func jobStateLabel(_ job: PipelineJob) -> some View {
        Group {
            if [.transcribing, .diarizing, .generatingProtocol].contains(job.state) {
                Text(stageProgressText(job))
                    .foregroundStyle(.secondary)
            } else if job.state == .error, let msg = job.error {
                Text(msg)
                    .foregroundStyle(.red)
            } else if job.state == .done, !job.warnings.isEmpty {
                Text(job.warnings.joined(separator: "; "))
                    .foregroundStyle(.orange)
            } else {
                Text(job.state.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    /// Live elapsed for the active stage, plus the historical average ("· Ø
    /// m:ss") when one exists, and a "longer than usual" hint once the live run
    /// runs meaningfully past that average — so the user can tell at a glance
    /// whether the current run is normal. Purely informational.
    private func stageProgressText(_ job: PipelineJob) -> String {
        let elapsed = pipelineQueue.activeJobElapsed
        let base = "\(job.state.label) \(formattedElapsed(elapsed))"
        guard let stage = StageKind(jobState: job.state),
              let avg = pipelineQueue.averageSeconds(forJobID: job.id, stage: stage), avg > 0 else { return base }
        let suffix = StageTimingStats.isSlowerThanUsual(elapsed: elapsed, average: avg)
            ? " · longer than usual (Ø \(formattedElapsed(avg)))"
            : " · Ø \(formattedElapsed(avg))"
        return base + suffix
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        formattedTime(seconds)
    }
}
