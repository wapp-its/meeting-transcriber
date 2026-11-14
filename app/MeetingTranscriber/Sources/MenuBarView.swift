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
    /// and the Last Recording section outlive the queue's one-minute reap and
    /// a restart.
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
    /// The held calls a click can record again (`WatchLoop.recordAgainOffers`).
    var recordAgainOffers: [RecordAgainOffer] = []
    /// The Microphone entry; nil leaves it out.
    var microphoneMenu: MicrophoneMenuState?
    /// The Output entry; nil leaves it out.
    var outputMenu: OutputMenuState?
    /// Whether Notion export is on, which makes the last recording's open
    /// item prefer the job's Notion page. A page exported before the setting
    /// was turned off is still the fallback when no local file exists;
    /// `JobOpenTarget` owns that rule.
    var notionExportEnabled = false
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

        recordAndImportSection
        audioDevicesSection
        jobSections
        lastRecordingSection
        recordingsSection
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
            recordAgainItems
            watchToggle
        }
        pauseResumeItem
    }

    /// One "Record Again (<App>)" line per held call, directly under the
    /// status line and above the watch toggle; no keyboard shortcut.
    private var recordAgainItems: some View {
        ForEach(recordAgainOffers, id: \.identityKey) { offer in
            Button {
                actions.recordAgain?(offer)
            } label: {
                Label(recordAgainLabel(offer), systemImage: "record.circle")
            }
            .accessibilityIdentifier(A11yID.recordAgainMenuItem)
        }
    }

    /// Hoisted out of the `ViewBuilder`, as `meetingLabel` is.
    private func recordAgainLabel(_ offer: RecordAgainOffer) -> String {
        "Record Again (\(offer.appName))"
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

    /// A section header is a heading line in the menu, not an item. The two
    /// record items are hidden while a recording runs, when the status block
    /// offers Stop Recording instead; the import is always there.
    private var recordAndImportSection: some View {
        Section("Record & Import") {
            if actions.stopManualRecording == nil, state != .recording {
                Button {
                    actions.recordMicrophone()
                } label: {
                    Label("Record Microphone Only", systemImage: "mic.circle")
                }
                .keyboardShortcut("m")
                .disabled(!microphoneAvailability.allowsStart)
                .help(microphoneAvailability.disabledReason ?? "Record the system microphone, with no app audio")
                .accessibilityIdentifier(A11yID.recordMicrophoneMenuItem)

                Button {
                    actions.recordApp()
                } label: {
                    Label("Record with Options…", systemImage: "record.circle")
                }
                .keyboardShortcut("r")
                .accessibilityIdentifier(A11yID.recordWithOptionsMenuItem)
            }

            Button {
                actions.processFiles()
            } label: {
                Label("Import Audio/Video Files…", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("p")
            .accessibilityIdentifier(A11yID.importFilesMenuItem)
        }
    }

    /// Left out with its heading when neither device entry is shown.
    @ViewBuilder private var audioDevicesSection: some View {
        if microphoneMenu != nil || outputMenu != nil {
            Section("Audio Devices") {
                microphoneSection
                outputSection
            }
        }
    }

    /// The way to every job, shown at all times: finished jobs are listed in
    /// the window, not in the menu. The newest result has its own section
    /// above this one (`lastRecordingSection`).
    private var recordingsSection: some View {
        Section("Recordings") {
            Button {
                actions.showAllTranscriptions()
            } label: {
                Label("All Recordings…", systemImage: "list.bullet.rectangle")
            }
            .keyboardShortcut("t")
            .accessibilityIdentifier(A11yID.allRecordingsMenuItem)
        }
    }

    /// mt-update mode first; otherwise a GitHub release, installed the way
    /// this copy was: a Homebrew install copies its `brew upgrade` command,
    /// anything else opens the download.
    @ViewBuilder private var updateSection: some View {
        if let updateChecker, updateChecker.isMtUpdateMode {
            mtUpdateItem(updateChecker)
        } else if let updateChecker, let update = updateChecker.availableUpdate {
            let route = updateChecker.installRoute(for: update)
            Divider()
            Button {
                route.perform()
            } label: {
                Label(updateTitle(update, route: route), systemImage: "arrow.down.circle.fill")
            }
        }
    }

    /// The menu closes on click, so the title has to say up front that the
    /// item copies a command rather than opening a download.
    private func updateTitle(_ update: ReleaseInfo, route: UpdateInstallRoute) -> String {
        switch route {
        case .homebrew: "Update Available: \(update.tagName) (Copy brew Command)"
        case .download: "Update Available: \(update.tagName)"
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
}
