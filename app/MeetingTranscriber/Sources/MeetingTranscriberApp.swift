import Combine
import os.log
import SwiftUI

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Launch")

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
    static let showSettings = Notification.Name("showSettings")
    static let closeSettings = Notification.Name("closeSettings")
}

/// Renders the menu-bar icon and ticks the animation frame in its own
/// view body. Keeping the timer + frame @State scoped here means the
/// surrounding `MeetingTranscriberApp` scene body never re-evaluates on
/// each tick — only this view does. Without this isolation, animating
/// badges (recording, transcribing, …) would cascade re-renders through
/// every open Window.
private struct AnimatedMenuBarIcon: View {
    let badge: BadgeKind
    let pausedOverlay: Bool
    let watchingOverlay: Bool
    let questionOverlay: Bool
    let meetingEndCountdownOverlay: Bool
    let permissionOverlay: Bool
    let recordOnlyOverlay: Bool
    let micSilentOverlay: Bool
    let appSilentOverlay: Bool

    @State private var animationFrame = 0
    // `.default` (not `.common`) so the timer never fires inside the status-bar
    // menu's tracking loop — see MenuBarIcon.animationRunLoopMode for why.
    private let iconTimer = Timer.publish(
        every: 0.4, on: .main, in: MenuBarIcon.animationRunLoopMode,
    ).autoconnect()

    var body: some View {
        Image(nsImage: MenuBarIcon.image(
            badge: badge,
            animationFrame: animationFrame,
            pausedOverlay: pausedOverlay,
            watchingOverlay: watchingOverlay,
            questionOverlay: questionOverlay,
            meetingEndCountdownOverlay: meetingEndCountdownOverlay,
            permissionOverlay: permissionOverlay,
            recordOnlyOverlay: recordOnlyOverlay,
            micSilentOverlay: micSilentOverlay,
            appSilentOverlay: appSilentOverlay,
        ))
        .onReceive(iconTimer) { _ in
            let next = MenuBarIcon.nextFrame(animationFrame, badge: badge)
            if next != animationFrame {
                animationFrame = next
            }
        }
    }
}

/// Bridges a SwiftUI `Window` scene down to its hosting `NSWindow` so
/// window-level AppKit properties can be configured. macOS 14 (our deployment
/// target) has no scene-level `.windowLevel` / collection-behavior modifiers
/// (those are macOS 15+), so a zero-size representable placed in the content's
/// `.background` is the idiomatic way to reach the window. `configure` runs
/// once the view is attached and on subsequent updates; the window properties
/// it sets are sticky and idempotent.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if let window = nsView.window { configure(window) }
    }
}

// Not @main — AppLauncher owns the entry point so a selftest launch can
// divert before this scene (and AppState with it) is ever constructed.
struct MeetingTranscriberApp: App {
    // Holds every quit open until the pending pipeline snapshot is on disk.
    // Handed `appState` in `init`, through `AppDelegate.install`. Never read:
    // declaring the adaptor is what makes SwiftUI install the delegate, and
    // the analyzer cannot see that use.
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate // swiftlint:disable:this unused_declaration
    @State private var appState: AppState
    @State private var captionsWindow: LiveCaptionsWindowController?
    // The All Recordings window's search text, kept while the window is closed.
    // Read only through `$transcriptionsQuery`. Built with Xcode 27, `swiftlint
    // analyze` does not see a reference made through the projected value and
    // reports the property as unused.
    // swiftlint:disable:next unused_declaration
    @State private var transcriptionsQuery = ""
    @State private var regenerateSheet = RegenerateSheetState()
    @Environment(\.openWindow)
    private var openWindow

    init() {
        // Built first, as the property initialiser it replaces was. Handed to
        // the application delegate here because `init` runs before the run
        // loop, so every quit request finds it, however early it comes and
        // whether or not the menu-bar item is ever shown.
        let state = AppState(pipelineEnvironment: .production, notifier: NotificationManager.shared)
        #if !APPSTORE
            PersistentDiagnosticLog.cleanup()
            // Reap any `log stream` children orphaned by a previous crash/SIGKILL
            // (re-parented to launchd) so they can't accumulate across launches.
            // `reapOrphans` is nonisolated, so it runs off the main actor.
            // The reap is deliberately NOT ordered before the streamer start — an
            // orphan surviving a few extra ms is benign next to blocking launch,
            // and the new streamer is matched by parent pid so it's never reaped.
            Task(priority: .utility) { await PersistentDiagnosticLog.reapOrphans() }
            state.startPersistentLogStreamer()
        #endif
        _appState = State(initialValue: state)
        AppDelegate.install(state)
        AppPaths.migrateIfNeeded()
        NotificationManager.shared.setUp()
        state.pipeline.restorePendingNotionExports()
        // The verdict was taken in `AppLauncher.main()`, before `AppState` was
        // built. It is reported here because this is the first point at which
        // the notification centre is set up (issue #703).
        Self.reportPreviousExit(AppLauncher.previousExit, to: NotificationManager.shared)
        // Temp-file cleanup moved into the queue-build recovery flow
        // (`PipelineController.recoverStagedRecordings`): a crashed
        // `_app_raw.tmp` must be
        // re-mixed by `recoverCrashedRecordings` BEFORE it's cleaned up, so the
        // delete can no longer run first here (issue #379).
        let suppressAutoWatch = ProcessInfo.processInfo.environment["MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH"] == "1"
        // Auto-watch: schedule on main run loop after app finishes launching.
        // E2E drivers that force channel-health flags via env var also set
        // `MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1` so a +3 s
        // `toggleWatching` doesn't reset the forced flag through the
        // normal `channelHealth.stop()` path.
        if (CommandLine.arguments.contains("--auto-watch")
            || UserDefaults.standard.bool(forKey: "autoWatch"))
            && !suppressAutoWatch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .autoWatchStart, object: nil)
            }
        }
    }

    // One scene per declaration, not one `body` holding the whole tree. The
    // analyze build passes `-warn-long-function-bodies=300` with warnings as
    // errors, so a getter that type-checks slowly is a build failure, and the
    // whole tree as a single expression shared one budget and crossed it on a
    // GitHub-hosted runner. Each declaration below is type-checked on its own
    // budget. Nothing leaves `body`'s evaluation: the properties are read from
    // the same closures at the same moment, so `@Observable` records the same
    // reads, and the scene order, window ids and modifiers are unchanged.
    var body: some Scene {
        MenuBarExtra {
            menuBarContent
        } label: {
            menuBarLabel
        }

        speakerNamingWindow
        settingsWindow
        recordAppWindow
        transcriptionsWindow
        consentOptionsWindow
    }

    // MARK: - Menu Bar

    private var menuBarContent: some View {
        MenuBarView(
            status: appState.currentStatus,
            isWatching: appState.isWatching,
            pipelineQueue: appState.pipelineQueue,
            updateChecker: appState.updateChecker,
            updateInstallBlockedReason: appState.updateInstallBlockedReason,
            history: appState.pipeline.terminalJobStore.records,
            noMic: appState.settings.noMic,
            manualRecordingPendingOrActive: appState.watching.isManualRecording,
            isRecordingPaused: appState.isRecordingPaused,
            consentQuestion: appState.pendingConsentQuestion,
            microphoneMenu: appState.microphoneMenuState,
            outputMenu: appState.outputMenuState,
            notionExportEnabled: appState.settings.notionExportEnabled,
            actions: menuActions,
        )
    }

    private var menuActions: MenuActions {
        MenuActions(
            installUpdate: { appState.installUpdate() },
            startStop: { appState.watching.toggleWatching() },
            recordApp: { bringWindowToFront(id: "record-app") },
            recordMicrophone: { appState.watching.startMicrophoneRecording() },
            stopManualRecording: appState.canStopRecording ? {
                appState.watching.stopRecording()
            } : nil,
            togglePause: appState.canPauseRecording ? {
                appState.watching.togglePause()
            } : nil,
            openJob: { Self.openJob($0, scopeRoot: appState.settings.effectiveOutputDir) },
            openLastNotes: openLastNotes,
            openSettings: { bringWindowToFront(id: "settings") },
            nameSpeakers: appState.hasPendingSpeakerNamingJobs ? {
                showNamingWindow()
            } : nil,
            processFiles: processAudioFiles,
            showAllTranscriptions: { bringWindowToFront(id: TranscriptionsView.windowID) },
            removeFailedJob: { id in appState.pipeline.removeFailedJob(id: id) },
            dismissJob: { id in appState.pipelineQueue.removeJob(id: id) },
            answerConsent: { question, granted in appState.answerConsentQuestion(question, granted: granted) },
            recordConsentWithOptions: openConsentOptions,
            quit: quit,
            selectMicrophone: { appState.settings.micDeviceUID = $0 },
            selectOutput: { appState.output.select(uid: $0) },
        )
    }

    private var allRecordingsActions: AllRecordingsActions {
        AllRecordingsActions(
            openProtocol: { AllRecordingsActions.openFile($0, scopeRoot: appState.settings.effectiveOutputDir) },
            openTranscript: { AllRecordingsActions.openFile($0, scopeRoot: appState.settings.effectiveOutputDir) },
            reveal: { AllRecordingsActions.revealFile($0, scopeRoot: appState.settings.effectiveOutputDir) },
            openInNotion: { Self.openInNotion(.notion($0)) },
            regenerate: { regenerateSheet.present(entry: $0, using: appState.protocolRegenerator) },
            retry: { appState.pipeline.retryJob(id: $0) },
            remove: { appState.pipeline.removeFailedJob(id: $0) },
            dismiss: { appState.pipelineQueue.removeJob(id: $0) },
            cancel: { appState.pipelineQueue.cancelJob(id: $0) },
            nameSpeakers: { id in
                appState.selectedNamingJobID = id
                bringWindowToFront(id: "speaker-naming")
            },
            openProtocolsFolder: { AllRecordingsActions.openFolder(appState.settings.effectiveOutputDir) },
            canRetry: { appState.pipeline.canRetryJob(id: $0) },
            filesOnDisk: { AllRecordingsActions.readFilesOnDisk(of: $0, scopeRoot: appState.settings.effectiveOutputDir) },
            meetingFiles: { appState.pipeline.meetingFileStore.record(for: $0) },
            audioOnDisk: { entry in
                appState.pipeline.meetingFileStore.record(for: entry.id).map { record in
                    AllRecordingsActions.readAudioOnDisk(of: record, scopeRoot: appState.settings.effectiveOutputDir)
                }
            },
            reloadMeetingFiles: { appState.pipeline.meetingFileStore.reload() },
            moveAudioToTrash: { appState.pipeline.moveAudioToTrash(jobID: $0, named: $1) },
            moveMeetingToTrash: { appState.pipeline.moveMeetingToTrash(jobID: $0, named: $1) },
            retryDeletion: { appState.pipeline.retryDeletion(jobID: $0) },
            setKeep: { appState.pipeline.setKeep(jobID: $0, $1) },
            retention: { appState.settings.recordingRetention },
            bundleID: appState.pipeline.meetingFileStore.bundleID,
            templateChoices: { appState.protocolTemplateChoices() },
            optionsUse: { appState.protocolOptionsUse() },
            chooseFile: { RegenerateProtocolView.chooseFile(startingIn: appState.settings.effectiveOutputDir) },
            resolveFile: { try appState.protocolRegenerator.target(for: $0) },
            generate: { target, options in
                Task { await appState.protocolRegenerator.regenerate(target, options: options) }
            },
        )
    }

    private var menuBarLabel: some View {
        Label {
            Text(appState.currentStateLabel)
        } icon: {
            AnimatedMenuBarIcon(
                badge: appState.currentBadge,
                pausedOverlay: appState.isRecordingPaused,
                watchingOverlay: appState.isWatching,
                questionOverlay: appState.awaitingUserAnswer,
                meetingEndCountdownOverlay: appState.meetingEndCountdownOverlay,
                permissionOverlay: appState.hasPermissionProblem,
                recordOnlyOverlay: appState.settings.recordOnly,
                // `recordingSilentActive` paints both halves; folded into the
                // hoisted overlay props so MenuBarIcon only needs the two
                // per-channel overlay inputs.
                micSilentOverlay: appState.micSilentOverlay,
                appSilentOverlay: appState.appSilentOverlay,
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoWatchStart)) { _ in
            if !appState.isWatching {
                appState.watching.toggleWatching(userInitiated: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
            showNamingWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            bringWindowToFront(id: "settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeSettings)) { _ in
            closeWindow(id: "settings")
        }
        .task {
            await appState.engines.preloadActiveModel()
        }
        .task {
            appState.resumeUpdateAfterLaunch()
            appState.updateChecker.startPeriodicChecks(settings: appState.settings)
        }
        .task {
            appState.remoteVocabulary.start()
        }
        .task { appState.recordingRetention.start() }
        .task {
            await appState.startPermissionChecks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check permissions when the user returns to the app (e.g. from System
            // Settings after toggling a permission). Debounced so rapid Cmd-Tab cycles
            // don't repeatedly churn the mic HAL via the 500 ms probe.
            appState.permissions.recheck()
        }
        .onChange(of: appState.shouldShowLiveCaptions, initial: true) { _, visible in
            let controller = captionsWindow ?? LiveCaptionsWindowController(
                state: appState.liveCaptions, size: appState.settings.liveCaptionsSize,
            )
            captionsWindow = controller
            if visible {
                controller.show()
            } else {
                controller.hide()
            }
        }
        // Not `initial: true`: the controller is created with the current
        // preset above, and a hidden bar picks the preset up on `show()`.
        .onChange(of: appState.settings.liveCaptionsSize) { _, size in
            captionsWindow?.apply(size: size)
        }
    }

    // MARK: - Windows

    private var speakerNamingWindow: some Scene {
        Window("Name Speakers", id: "speaker-naming") {
            speakerNamingContent
                // Pin the naming window so it stays visible + on top while the
                // user works in other apps instead of vanishing on focus loss
                // (issue #504). Applied via the hosting NSWindow because macOS 14
                // has no scene-level window-level / collection-behavior modifier.
                .background(WindowAccessor { NamingWindowPolicy.apply(to: $0) })
                .onAppear {
                    // Close restored window if no naming data available (macOS state restoration)
                    if appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty {
                        closeWindow(id: "speaker-naming")
                    }
                }
                // Auto-close when the pending list drains. Covers RPC-driven
                // skip (`POST /action/skipNaming`), where the data layer
                // transitions but the UI callback never fires.
                .onChange(of: appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty) { _, isEmpty in
                    if isEmpty {
                        closeWindow(id: "speaker-naming")
                    }
                }
        }
        .windowResizability(.contentSize)
    }

    private var settingsWindow: some Scene {
        Window("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                whisperKitEngine: appState.engines.whisperKit,
                parakeetEngine: appState.engines.parakeetEngine,
                updateChecker: appState.updateChecker,
                updateInstallBlockedReason: appState.updateInstallBlockedReason,
                onInstallUpdate: { appState.installUpdate() },
                remoteVocabulary: appState.remoteVocabulary,
                notificationVisibility: appState.permissions.notificationVisibility,
                // Share the pipeline's actor instance so both writers serialise on
                // the same `recognition_log.jsonl` file. Fallback only fires in the
                // test-only PipelineQueue init that intentionally leaves it nil.
                recognitionStatsLog: appState.pipeline.queue.recognitionStatsLog ?? RecognitionStatsLog(),
                // Same actor instance the pipeline writes to, so both writers
                // serialise on stage_timing.jsonl. Fallback fires only in the
                // test-only PipelineQueue init that leaves it nil.
                stageTimingLog: appState.pipeline.queue.stageTimingLog ?? StageTimingLog(),
                enrollmentDiarizerFactory: { FluidDiarizer(mode: appState.settings.diarizerMode) },
                namingDialogActive: appState.pipeline.queue.pendingSpeakerNaming != nil,
                pipelineBusy: appState.pipeline.queue.isProcessing,
                onSpeakerMutate: appState.pipeline.queue.refreshKnownSpeakerNames,
                // The pipeline's file and the app's notifier, so Known Voices
                // and enrollment edit the same DB and report through one channel.
                speakerMatcherFactory: SpeakerMatcher.factory(
                    dbPath: appState.pipeline.speakersDB, notifier: appState.notifier,
                ),
                legacyWhisperModels: appState.engines.legacyWhisperModels,
                retentionActions: RetentionSettingsActions(
                    preview: { await appState.recordingRetention.preview(for: $0) },
                    apply: { appState.recordingRetention.apply($0) },
                ),
            )
        }
        .windowResizability(.contentSize)
    }

    private var recordAppWindow: some Scene {
        Window("Start Recording", id: "record-app") {
            AppPickerView(
                appsProvider: SystemRunningAppsProvider(),
                // The controller's wide predicate, not `appState.isManualRecording`.
                // That one is loop-only for the menu bar's Stop item and reads
                // false for the whole in-flight window. This window outlives the
                // menu item that opened it — it closes only on its own Start or
                // Cancel — so it has to stay truthful across both halves.
                startWouldBeRefused: appState.watching.isManualRecording,
                noMic: appState.settings.noMic,
                templateChoices: { appState.protocolTemplateChoices() },
                optionsUse: { appState.protocolOptionsUse() },
                onStartRecording: { request, options in
                    appState.watching.startRecording(request, protocolOptions: options)
                    closeWindow(id: "record-app")
                },
                onCancel: { closeWindow(id: "record-app") },
            )
        }
        .windowResizability(.contentSize)
    }

    private var transcriptionsWindow: some Scene {
        Window("All Recordings", id: TranscriptionsView.windowID) {
            TranscriptionsView(
                entries: appState.pipeline.transcriptionEntries,
                query: $transcriptionsQuery,
                actions: allRecordingsActions,
                regenerateSheet: regenerateSheet,
                regenerationPhase: appState.protocolRegenerator.phase,
            )
            // Starts the pipeline the way an import does, so failed jobs from an
            // earlier session are in the queue and can be retried. Also runs when
            // macOS restores the window at launch.
            .onAppear { appState.pipeline.prepareTranscriptionsWindow() }
        }
        .defaultSize(width: 760, height: 520)
    }

    private var consentOptionsWindow: some Scene {
        Window("Record Meeting", id: ConsentOptionsView.windowID) {
            ConsentOptionsView(
                question: appState.consentOptionsQuestion,
                templateChoices: { appState.protocolTemplateChoices() },
                optionsUse: { appState.protocolOptionsUse() },
                onRecord: { question, options in
                    appState.answerConsentQuestion(question, granted: true, protocolOptions: options)
                },
                onClose: { closeWindow(id: ConsentOptionsView.windowID) },
            )
        }
        .windowResizability(.contentSize)
    }

    /// "Record with Options…" on the menu's recording prompt.
    private func openConsentOptions(_ question: ConsentQuestion) {
        appState.consentOptionsQuestion = question
        bringWindowToFront(id: ConsentOptionsView.windowID)
    }

    // MARK: - Speaker Naming Window

    /// Open the naming window on a pinned job, from the menu and from
    /// `.showSpeakerNaming` alike.
    private func showNamingWindow() {
        appState.pinShownNamingJob()
        bringWindowToFront(id: "speaker-naming")
    }

    private var speakerNamingContent: some View {
        Group {
            if let data = appState.pipeline.queue.speakerNamingData(
                forJobID: appState.selectedNamingJobID,
            ) {
                VStack(spacing: 0) {
                    speakerNamingPicker
                    speakerNamingForm(data: data)
                }
            } else {
                Text("No speaker data available.")
                    .padding()
            }
        }
        // Whatever opened the window or changed what it shows (a restored
        // window, an RPC answer for the shown job), the selection follows.
        .onChange(
            of: appState.pipeline.queue.namingJobID(preferring: appState.selectedNamingJobID),
            initial: true,
        ) { _, _ in
            appState.pinShownNamingJob()
        }
    }

    @ViewBuilder private var speakerNamingPicker: some View {
        if appState.pipeline.queue.pendingSpeakerNamingJobs.count > 1 {
            NamingJobPicker(
                jobs: appState.pipeline.queue.pendingSpeakerNamingJobs,
                selection: Binding(
                    get: {
                        appState.pipeline.queue.namingJobID(preferring: appState.selectedNamingJobID)
                    },
                    set: { appState.selectedNamingJobID = $0 },
                ),
            )
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func speakerNamingForm(
        data: PipelineQueue.SpeakerNamingData,
    ) -> some View {
        SpeakerNamingView.answering(
            data: data,
            knownSpeakerNames: appState.pipeline.queue.knownSpeakerNames,
            currentDiarizerMode: appState.pipeline.queue.usedDiarizerMode(forJobID: data.jobID)
                ?? appState.settings.diarizerMode,
            pendingJobCount: appState.pipeline.queue.pendingSpeakerNamingJobs.count,
            balanceSampleLevels: appState.settings.levelBalanceEnabled,
            onDismissRequest: { closeWindow(id: "speaker-naming") },
            notice: appState.pipeline.queue.lateRerunFailure(forJobID: data.jobID)?.message,
            // Labelled: `onDismissRequest` is a closure too, and SwiftFormat
            // and SwiftLint disagree on trailing syntax for the last of two.
            // swiftlint:disable:next trailing_closure
            onAnswer: { result in
                if let refusal = appState.pipeline.queue.completeSpeakerNaming(jobID: data.jobID, result: result) {
                    return refusal.message
                }
                // The next job awaiting naming, pinned; none left closes the
                // window.
                appState.selectedNamingJobID = nil
                appState.pinShownNamingJob()
                if appState.selectedNamingJobID == nil { closeWindow(id: "speaker-naming") }
                return nil
            },
        )
    }

    // MARK: - UI Actions

    private func processAudioFiles() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio or Video Files"
        panel.allowedContentTypes = AudioImportTypes.pickerTypes(
            ffmpegAvailable: FFmpegHelper.isAvailable,
        )
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        let pairingDelegate = PairedImportPanelDelegate()
        panel.delegate = pairingDelegate
        panel.accessoryView = pairingDelegate.accessoryView
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        appState.pipeline.enqueueFiles(panel.urls)
    }

    private func bringWindowToFront(id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
        // Ensure the window is brought to front even if already open
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == id {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func closeWindow(id: String) {
        for window in NSApp.windows where window.identifier?.rawValue == id {
            window.close()
        }
    }

    /// Only asks to terminate: stopping watching and finishing a recording
    /// happen in `AppDelegate`, which every quit path goes through, and this
    /// one alone used to do them.
    private func quit() {
        logger.info("Menu Quit requested")
        NSApplication.shared.terminate(nil)
    }

    /// "Open Last Notes": a local file through the output folder's scope and
    /// its moved-or-deleted notice, a Notion page through `ProtocolOpener`,
    /// which hands it to a running Notion app.
    private func openLastNotes(_ target: JobOpenTarget) {
        switch target {
        case let .file(url):
            Self.openLastNotesFile(url, scopeRoot: appState.settings.effectiveOutputDir, notifier: NotificationManager.shared)

        case .notion:
            Self.openInNotion(target)
        }
    }
}
