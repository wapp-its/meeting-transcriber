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
    let onQuit: () -> Void

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
        meetingInfo
        errorInfo

        Divider()

        watchControls
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

    @ViewBuilder private var watchControls: some View {
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

        if let onStopManualRecording {
            Button {
                onStopManualRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".")
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
