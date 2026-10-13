import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker?
    /// The finished-job history, read with the queue's jobs so a finished
    /// line outlives the queue's one-minute reap and a restart.
    var history: [TerminalJobRecord] = []
    let onStartStop: () -> Void
    /// Opens the start dialog, "Start Recording with Options…".
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
    /// Opens the Transcriptions window.
    var onShowAllTranscriptions: () -> Void = {}
    /// Remove on a failed job: off the menu and out of the history for good.
    var onRemoveFailedJob: (UUID) -> Void = { _ in }
    /// Dismiss on a job waiting for speaker names.
    let onDismissJob: (UUID) -> Void
    /// The open "Record <App> meeting?" prompt, nil when none is open.
    var consentQuestion: ConsentQuestion?
    /// Answers the question the menu displayed, true for Record. Handed the
    /// question rather than reading the open one, so a click on a menu that
    /// went stale answers nothing (`WatchLoop.answerParkedConsent`).
    var onAnswerConsent: ((ConsentQuestion, Bool) -> Void)?
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
        consentPrompt
        statusHeader
        sessionControls
        meetingInfo
        errorInfo

        Divider()

        watchControls
        microphoneSection
        processingQueue
        allTranscriptionsItem

        Divider()

        protocolActions
        updateSection

        Divider()

        settingsButton

        Divider()

        quitButton
    }

    // MARK: - Body sections

    /// The open recording prompt, worded exactly as its notification, for
    /// whoever missed the banner or never got one. Its own section above the
    /// status line, so the divider closing it leaves the status line and its
    /// control together.
    @ViewBuilder private var consentPrompt: some View {
        if let question = consentQuestion {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.title)
                    .font(.headline)
                Text(question.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Button {
                onAnswerConsent?(question, true)
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .accessibilityIdentifier(A11yID.consentPromptRecord)

            Button {
                onAnswerConsent?(question, false)
            } label: {
                Label("Ignore", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier(A11yID.consentPromptIgnore)

            Divider()
        }
    }

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
                Label("Start Recording with Options…", systemImage: "record.circle")
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
        let entries = jobEntries
        if !entries.isEmpty {
            Divider()
            Label("Processing", systemImage: "gearshape.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                jobRow(entry, index: index)
            }
        }
    }

    /// Every unfinished job and the three that finished last, from the same
    /// list as the Transcriptions window, so the menu's length follows the
    /// work in flight rather than the number of finished jobs.
    private var jobEntries: [TranscriptionEntry] {
        TranscriptionList.menuEntries(TranscriptionList.entries(liveJobs: pipelineQueue.jobs, records: history))
    }

    /// Shown at all times, after the job lines: the menu keeps only a few
    /// finished jobs, and every other one is in the window.
    private var allTranscriptionsItem: some View {
        Button {
            onShowAllTranscriptions()
        } label: {
            Label("All Transcriptions...", systemImage: "list.bullet.rectangle")
        }
        .keyboardShortcut("t")
        .accessibilityIdentifier(A11yID.allTranscriptionsMenuItem)
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

    /// One menu item per job, its actions in a submenu. A menu-style
    /// `MenuBarExtra` cannot lay anything out side by side: an `HStack` row
    /// came out as one menu item per part, so the status dot and the spacer
    /// became empty lines and the buttons stood one below the other.
    private func jobRow(_ entry: TranscriptionEntry, index: Int) -> some View {
        Menu {
            Text(entry.title)
            jobStateLabel(entry)
            Divider()
            jobActions(entry, index: index)
        } label: {
            Label(jobMenuTitle(entry), systemImage: jobSymbol(entry))
        }
    }

    /// Hoisted out of the `ViewBuilder` for the type-check budget (see the
    /// note on `body`).
    private func jobMenuTitle(_ entry: TranscriptionEntry) -> String {
        let status = JobMenuSummary.status(
            state: entry.state, hasWarnings: !entry.warnings.isEmpty, progress: stageProgressText(entry),
        )
        return "\(entry.title) — \(status)"
    }

    private func jobSymbol(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.symbol(state: entry.state, hasWarnings: !entry.warnings.isEmpty)
    }

    /// A finished line has no Dismiss: it leaves the menu once three later
    /// jobs have finished, and a failed one is taken off for good by Remove.
    @ViewBuilder
    private func jobActions(_ entry: TranscriptionEntry, index: Int) -> some View {
        if entry.state.isTerminal, let url = entry.fileToOpen {
            Button("Open") { onOpenProtocol(url) }
        }
        if entry.state == .speakerNamingPending {
            Button("Name Speakers") { onNameSpeakers?() }
        }
        if entry.state == .waiting || entry.state == .transcribing
            || entry.state == .diarizing || entry.state == .generatingProtocol {
            Button("Cancel") { pipelineQueue.cancelJob(id: entry.id) }
        }
        retryButton(entry, index: index)
        if entry.state == .error {
            Button("Remove") { onRemoveFailedJob(entry.id) }
                .accessibilityIdentifier(A11yID.jobRemoveButton(index))
        }
        if entry.state == .speakerNamingPending {
            Button("Dismiss") { onDismissJob(entry.id) }
        }
    }

    /// Runs a failed job again from its audio, instead of the user having to
    /// find the staged recording and import it by hand. A failed job known
    /// only from the history is not in the queue, so the queue refuses it
    /// until the pipeline has loaded it.
    @ViewBuilder
    private func retryButton(_ entry: TranscriptionEntry, index: Int) -> some View {
        if pipelineQueue.canRetryJob(id: entry.id) {
            Button("Retry") { pipelineQueue.retryJob(id: entry.id) }
                .accessibilityIdentifier(A11yID.jobRetryButton(index))
        }
    }

    private func jobStateLabel(_ entry: TranscriptionEntry) -> some View {
        Group {
            if [.transcribing, .diarizing, .generatingProtocol].contains(entry.state) {
                Text(stageProgressText(entry))
                    .foregroundStyle(.secondary)
            } else if entry.state == .error, let msg = entry.error {
                Text(msg)
                    .foregroundStyle(.red)
            } else if entry.state == .done, !entry.warnings.isEmpty {
                Text(entry.warnings.joined(separator: "; "))
                    .foregroundStyle(.orange)
            } else {
                Text(entry.state.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    /// Live elapsed for the active stage, plus the historical average ("· Ø
    /// m:ss") when one exists, and a "longer than usual" hint once the live run
    /// runs meaningfully past that average — so the user can tell at a glance
    /// whether the current run is normal. Purely informational.
    private func stageProgressText(_ entry: TranscriptionEntry) -> String {
        let elapsed = pipelineQueue.activeJobElapsed
        let base = "\(entry.state.label) \(formattedElapsed(elapsed))"
        guard let stage = StageKind(jobState: entry.state),
              let avg = pipelineQueue.averageSeconds(forJobID: entry.id, stage: stage), avg > 0 else { return base }
        let suffix = StageTimingStats.isSlowerThanUsual(elapsed: elapsed, average: avg)
            ? " · longer than usual (Ø \(formattedElapsed(avg)))"
            : " · Ø \(formattedElapsed(avg))"
        return base + suffix
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        formattedTime(seconds)
    }
}
