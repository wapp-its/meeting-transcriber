import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker?
    /// Why "Install Update" is not possible right now (`UpdateInstallGate`);
    /// set, it disables the menu's install item.
    var updateInstallBlockedReason: String?
    /// The finished-job history, read with the queue's jobs so a failed line
    /// and "Open Last Protocol" outlive the queue's one-minute reap and a
    /// restart.
    var history: [TerminalJobRecord] = []
    /// Whether the user set "No Microphone (app audio only)". Only reaches the
    /// microphone item, which it disables with a reason.
    let noMic: Bool
    /// The *wide* predicate: a manual recording that is running, or a start that
    /// has registered and not yet built its loop. `state == .recording` misses
    /// that second window, and the microphone item would sit enabled through it
    /// handing back a dead click, which is what `AppPickerStartState` was built
    /// to avoid on the picker.
    let manualRecordingPendingOrActive: Bool
    /// Whether the running recording is paused, which picks the label of the
    /// item `MenuActions.togglePause` drives.
    var isRecordingPaused = false
    /// The open "Record <App> meeting?" prompt, nil when none is open.
    var consentQuestion: ConsentQuestion?
    /// The Microphone entry; nil leaves it out.
    var microphoneMenu: MicrophoneMenuState?
    /// The Output entry; nil leaves it out.
    var outputMenu: OutputMenuState?
    /// What the menu's items do; a nil optional action hides or disables its
    /// item (see `MenuActions`).
    let actions: MenuActions

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
        outputSection
        jobSections

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
                actions.answerConsent?(question, true)
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .accessibilityIdentifier(A11yID.consentPromptRecord)

            Button {
                actions.recordConsentWithOptions?(question)
            } label: {
                Label("Record with Options…", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier(A11yID.consentPromptRecordWithOptions)

            Button {
                actions.answerConsent?(question, false)
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
        if let stopManualRecording = actions.stopManualRecording {
            Button {
                stopManualRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".")
        } else {
            watchToggle
        }
        pauseResumeItem
    }

    /// The line under "Stop Recording", for every kind of recording.
    @ViewBuilder private var pauseResumeItem: some View {
        if let togglePause = actions.togglePause {
            Button {
                togglePause()
            } label: {
                if isRecordingPaused {
                    Label("Resume Recording", systemImage: "record.circle")
                } else {
                    Label("Pause Recording", systemImage: "pause.circle")
                }
            }
            .accessibilityIdentifier(A11yID.pauseResumeRecording)
        }
    }

    @ViewBuilder private var watchControls: some View {
        if actions.stopManualRecording == nil, state != .recording {
            Button {
                actions.recordMicrophone()
            } label: {
                Label("Record Microphone Only", systemImage: "mic.circle")
            }
            .keyboardShortcut("m")
            .disabled(!microphoneAvailability.allowsStart)
            .help(microphoneAvailability.disabledReason ?? "Record the system microphone, with no app audio")

            Button {
                actions.recordApp()
            } label: {
                Label("Start Recording with Options…", systemImage: "record.circle")
            }
            .keyboardShortcut("r")
        }

        if let nameSpeakers = actions.nameSpeakers {
            Button {
                nameSpeakers()
            } label: {
                Label("Name Speakers...", systemImage: "person.2.fill")
            }
            .keyboardShortcut("n")
        }

        Button {
            actions.processFiles()
        } label: {
            Label("Process Audio/Video Files...", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("p")
    }

    /// The jobs under way and the jobs waiting on the user, each group under
    /// its own header and only when it has a job. Row indexes run on across
    /// both groups, so every row's identifiers stay unique.
    @ViewBuilder private var jobSections: some View {
        let sections = TranscriptionList.menuSections(transcriptionEntries)
        jobSection("In progress", systemImage: "gearshape.2.fill", entries: sections.inProgress, firstIndex: 0)
        jobSection(
            "Needs you", systemImage: "exclamationmark.circle",
            entries: sections.needsYou, firstIndex: sections.inProgress.count,
        )
    }

    @ViewBuilder
    private func jobSection(
        _ title: String, systemImage: String, entries: [TranscriptionEntry], firstIndex: Int,
    ) -> some View {
        if !entries.isEmpty {
            Divider()
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                jobRow(entry, index: firstIndex + offset)
            }
        }
    }

    /// The same list as the Transcriptions window, so the two cannot disagree
    /// about which jobs exist or what state they are in.
    private var transcriptionEntries: [TranscriptionEntry] {
        TranscriptionList.entries(liveJobs: pipelineQueue.jobs, records: history)
    }

    /// Shown at all times, next to the protocols folder: finished jobs are
    /// listed in the window, not in the menu.
    private var allTranscriptionsItem: some View {
        Button {
            actions.showAllTranscriptions()
        } label: {
            Label("All Transcriptions...", systemImage: "list.bullet.rectangle")
        }
        .keyboardShortcut("t")
        .accessibilityIdentifier(A11yID.allTranscriptionsMenuItem)
    }

    /// The way to the results: the newest one, every job, and the folder they
    /// are written to. "Open Last Protocol" is the menu's one click to the
    /// newest result now that finished jobs are not listed, shown while the
    /// history holds a finished job with a file.
    @ViewBuilder private var protocolActions: some View {
        if let url = TranscriptionList.lastFinished(transcriptionEntries)?.fileToOpen {
            Button {
                actions.openLastProtocol(url)
            } label: {
                Label("Open Last Protocol", systemImage: "doc.text")
            }
            .keyboardShortcut("o")
        }

        allTranscriptionsItem

        Button {
            actions.openProtocolsFolder()
        } label: {
            Label("Open Protocols Folder", systemImage: "folder")
        }

        Button {
            actions.regenerateProtocol()
        } label: {
            Label("Regenerate Protocol…", systemImage: "arrow.triangle.2.circlepath")
        }
        .accessibilityIdentifier(A11yID.regenerateProtocolMenuItem)
    }

    @ViewBuilder private var updateSection: some View {
        if let updateChecker, updateChecker.isMtUpdateMode {
            mtUpdateItem(updateChecker)
        } else if let update = updateChecker?.availableUpdate {
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

    /// mt-update mode: a running install as a line of its own, else the item
    /// that starts one for the build on offer. A check holds mt-update's
    /// checkout too, so it disables the item like a blocking reason does.
    @ViewBuilder
    private func mtUpdateItem(_ updateChecker: UpdateChecker) -> some View {
        if updateChecker.isInstalling {
            Divider()
            Label("Installing Update…", systemImage: "arrow.triangle.2.circlepath")
        } else if let summary = updateChecker.availableBuildSummary {
            Divider()
            Button {
                actions.installUpdate?()
            } label: {
                Label("Install Update: \(summary)", systemImage: "arrow.down.circle.fill")
            }
            .disabled(updateInstallBlockedReason != nil || updateChecker.isChecking || actions.installUpdate == nil)
            .accessibilityIdentifier(A11yID.menuInstallUpdateButton)
        }
    }

    /// Rendered by `sessionControls` only while no recording runs: a recording
    /// pauses watching, so the menu offers no watch control during one.
    private var watchToggle: some View {
        Button {
            actions.startStop()
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
            actions.openSettings()
        } label: {
            Label("Settings...", systemImage: "gear")
        }
        .keyboardShortcut(",")
    }

    private var quitButton: some View {
        Button {
            actions.quit()
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
            state: entry.state, hasWarnings: !entry.warnings.isEmpty, progress: stageProgress(entry),
        )
        return "\(entry.title) — \(status)"
    }

    private func jobSymbol(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.symbol(state: entry.state, hasWarnings: !entry.warnings.isEmpty)
    }

    /// A failed line is taken off for good by Remove; Dismiss is left to a
    /// job waiting for speaker names.
    @ViewBuilder
    private func jobActions(_ entry: TranscriptionEntry, index: Int) -> some View {
        if entry.state.isTerminal, let url = entry.fileToOpen {
            Button("Open") { actions.openProtocol(url) }
        }
        if entry.state == .speakerNamingPending {
            Button("Name Speakers") { actions.nameSpeakers?() }
        }
        if entry.state == .waiting || entry.state == .transcribing
            || entry.state == .diarizing || entry.state == .generatingProtocol {
            Button("Cancel") { pipelineQueue.cancelJob(id: entry.id) }
        }
        retryButton(entry, index: index)
        if entry.state == .error {
            Button("Remove") { actions.removeFailedJob(entry.id) }
                .accessibilityIdentifier(A11yID.jobRemoveButton(index))
        }
        if entry.state == .speakerNamingPending {
            Button("Dismiss") { actions.dismissJob(entry.id) }
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
                Text(stageProgress(entry))
                    .foregroundStyle(.secondary)
            } else if entry.state == .error, let msg = entry.error {
                Text(msg)
                    .foregroundStyle(.red)
            } else {
                Text(entry.state.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    /// The running stage's start and expected finish, read from the queue's
    /// clock for the job. Nothing here reads the time, so the line changes
    /// only when the clock does, at a job event.
    private func stageProgress(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.stageProgress(state: entry.state, clock: pipelineQueue.stageClock(forJobID: entry.id))
    }
}
