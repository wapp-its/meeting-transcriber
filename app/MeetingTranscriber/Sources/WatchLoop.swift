import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Native Swift watch loop that replaces the Python watcher.
///
/// Orchestrates: meeting detection → recording → enqueue to PipelineQueue.
@MainActor
@Observable
class WatchLoop {
    enum State: String {
        case idle
        case watching
        case recording
        case error
    }

    private(set) var state: State = .idle
    private(set) var currentMeeting: DetectedMeeting?
    private(set) var lastError: String?
    private(set) var detail: String = ""
    /// When the recording in progress was paused (`WatchLoop+Pause.swift`).
    private(set) var pausedSince: Date?

    // Manual recording
    private(set) var manualRecordingInfo: ManualRecordingInfo?
    /// Exposed for read-only access — AppState's per-channel level monitor polls
    /// `appLevelDBFS` / `micLevelDBFS` here at ~10 Hz to drive the asymmetric-silence
    /// indicator. Setter stays private so the recording lifecycle flows through
    /// this class only.
    private(set) var activeRecorder: (any RecordingProvider)?
    private var manualRecordingTask: Task<Void, Never>?

    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    // Dependencies
    let detector: any MeetingDetecting
    let recorderFactory: @MainActor () async -> any RecordingProvider
    var pipelineQueue: PipelineQueue?
    var permissionChecker: () async -> HealthCheckResult = { await PermissionHealthCheck.runLive() }

    // Settings
    let pollInterval: TimeInterval
    let endGracePeriod: TimeInterval
    let maxDuration: TimeInterval
    /// How long before `maxDuration` a recording is warned that it is about to
    /// end (`RecordingCapWarningPolicy`). Fixed in the app; injectable so tests
    /// can use a short maximum.
    let capWarningLead: TimeInterval
    /// How long the "meeting seems to have ended" question stays open before
    /// the recording ends anyway. Fixed at `meetingEndQuestionCountdown` in the
    /// app; injectable so tests need not wait it out.
    let meetingEndCountdown: TimeInterval
    /// "No Microphone" and the mic picker (nil = system default), read at every
    /// recording start: a loop lives as long as watching does, so snapshots
    /// went stale (issue #706), and a microphone chosen while watching is on
    /// reaches the next recording without restarting watching.
    let noMic: () -> Bool
    let micDeviceUID: () -> String?
    /// The running recording's source, nil once it ended; see `activeRecordingSource`.
    private(set) var recordingSource: RecordingSource?
    /// Dynamic accessor — read at recording-start time so toggling the setting
    /// at runtime takes effect on the next recording without an app restart.
    let verboseDiagnostics: () -> Bool
    /// Dynamic accessor — when true, skip the post-processing pipeline and
    /// instead write a `<basename>_meta.json` sidecar next to the recording.
    let recordOnly: () -> Bool
    /// Dynamic accessor — destination for record-only output (WAVs + sidecar
    /// JSON). Returns a `(scope, writeDir)` pair so we can call
    /// `startAccessingSecurityScopedResource()` on the *bookmark-resolved
    /// parent* (the URL the user actually picked) while writing into a
    /// `recordings/` subfolder. Calling start-access on a child URL silently
    /// fails inside the App Store sandbox — see `RecordOnlyDestination`.
    let recordOnlyDestination: () -> RecordOnlyDestination
    /// Puts a copy of a record-only file in the destination (see
    /// `RecordOnlyWrite`). A seam so a test can see which thread it runs on
    /// (see `writeRecordOnlyOffMain`).
    let recordOnlyFileTransfer: RecordOnlyWrite.Transfer
    /// Surface user-facing failures (e.g. sidecar write errors) that don't
    /// transition state to `.error`. Defaults to a silent no-op for tests.
    let notifier: any AppNotifying
    /// Where the automatic-stop lines go (`WatchLoop+MeetingEnd.swift`).
    let diagnostics: any DiagnosticsLogging

    /// The open "meeting seems to have ended" question and the answer parked
    /// for the next poll. Internal for `WatchLoop+MeetingEnd.swift`, which owns
    /// both, the way the consent extension owns `pendingConsentQuestion`. The
    /// id is set exactly while the question's countdown runs, which is what
    /// the menu bar icon's pulse reads (`AppState.meetingEndCountdownOverlay`).
    var meetingEndQuestionID: String?
    var meetingEndAnswer: ReceivedMeetingEndAnswer?
    /// When "Stop Recording" was chosen, parked for the wait's next poll (`WatchLoop+StopByHand.swift`).
    var stopByHandRequestedAt: Date?
    /// Apps kept out of detection until their signal has gone once (`WatchLoop+RedetectionHold.swift`).
    var redetectionHolds = RedetectionHolds()
    var silencePrompt: SilencePromptRuntime
    /// The recording's pauses, from its capture start to its stop (`WatchLoop+Pause.swift`).
    var recordingPauses: RecordingPauseRecord?

    /// Wall-clock source. Defaults to `Date()`; tests inject a `TestClock`
    /// so timing-sensitive paths become deterministic instead of racing
    /// against `Task.sleep`'s actual jitter on loaded CI runners.
    let nowProvider: () -> Date
    /// Sleep primitive. Defaults to `Task.sleep`; tests inject the
    /// matching `TestClock.sleep` so virtual time advances synchronously.
    let sleepProvider: (TimeInterval) async throws -> Void
    /// Process-alive probe. Defaults to `kill(pid, 0) == 0`; tests inject
    /// a closure with a deterministic answer so the
    /// `monitorManualRecording` switch arms can be exercised without
    /// spawning a real subprocess.
    let pidAliveCheck: (pid_t) -> Bool

    /// Suppresses re-prompting after a declined consent prompt (issue #503).
    /// Internal so the consent gate can live in `WatchLoop+Consent.swift`.
    var consentPolicy: BrowserConsentPolicy
    let denyListStore: any ConsentDenyListStoring
    /// Dynamic accessor — the apps whose meetings record without the consent
    /// prompt (`AppSettings.recordWithoutAskingApps`). Read at every detection,
    /// like the deny list, so a Settings change applies without restarting
    /// watching. Empty by default: every detected meeting asks.
    let recordWithoutAskingApps: () -> [String]

    /// The consent prompt currently parked, nil when no question is open. The
    /// answer is awaited in `consentTask` rather than inline, so this is what
    /// keeps a second prompt from going out on every poll while the first one
    /// waits. Internal (not `private(set)`) because `WatchLoop+Consent.swift`
    /// owns the transitions; `pendingConsentApp` there is its app's name.
    var pendingConsentQuestion: ConsentQuestion?

    /// Apps (identity keys) that needed a prompt while that one was open. Not a
    /// queue: they are kept out of detection until that question settles, so
    /// none of them can hide a meeting that needs no prompt, and are detected
    /// and asked about afterwards if their call still runs.
    var appsWaitingForPrompt: Set<String> = []

    /// A meeting the user approved, waiting for the loop to pick it up.
    /// Recordings start in the loop and nowhere else, so an answer arriving
    /// out of band parks here instead of starting one from the consent task.
    var approvedConsentMeeting: DetectedMeeting?
    /// "Record with Options…" choices for the open question, then for the meeting it approved (`WatchLoop+Consent.swift`).
    var pendingConsentProtocolOptions: MeetingProtocolOptions?
    var approvedConsentProtocolOptions: MeetingProtocolOptions?

    /// The task awaiting the parked answer. Held so `stop()` can let go of it.
    var consentTask: Task<Void, Never>?

    private var watchTask: Task<Void, Never>?

    /// Hook called when state changes (for UI updates, notifications, etc.)
    var onStateChange: ((State, State, PhaseChangeCause) -> Void)?
    /// Told true as a detected meeting's capture begins and false once its recorder stopped, also after `stop()` left `.recording`.
    var onMeetingCapture: ((Bool) -> Void)?
    /// Told once a manual recording has ended, after `stopManualRecording` went idle; a quit (`stop()`, `finishForQuit`) never tells it.
    var onManualRecordingEnded: (() -> Void)?

    init(
        detector: any MeetingDetecting = WatchLoop.defaultDetector(),
        recorderFactory: @MainActor @escaping () async -> any RecordingProvider = { DualSourceRecorder() },
        pipelineQueue: PipelineQueue? = nil,
        pollInterval: TimeInterval = 3.0,
        endGracePeriod: TimeInterval = 15.0,
        maxDuration: TimeInterval = 14400,
        capWarningLead: TimeInterval = RecordingCapWarningPolicy.defaultLead,
        meetingEndCountdown: TimeInterval = WatchLoop.meetingEndQuestionCountdown,
        noMic: @escaping () -> Bool = { false },
        micDeviceUID: @escaping () -> String? = { nil },
        verboseDiagnostics: @escaping () -> Bool = { false },
        recordOnly: @escaping () -> Bool = { false },
        recordOnlyDestination: @escaping () -> RecordOnlyDestination = {
            .unscoped(AppPaths.recordingsDir)
        },
        recordOnlyFileTransfer: @escaping RecordOnlyWrite.Transfer = RecordOnlyWrite.linkOrCopy,
        recordWithoutAskingApps: @escaping () -> [String] = { [] },
        speechActivity: @escaping () -> SpeechActivity? = { nil },
        silencePromptAfter: @escaping () -> TimeInterval? = { nil },
        notifier: any AppNotifying = SilentNotifier(),
        diagnostics: any DiagnosticsLogging = OSLogDiagnostics(category: "WatchLoop"),
        nowProvider: @escaping () -> Date = Date.init,
        sleepProvider: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        },
        pidAliveCheck: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 },
        consentPolicy: BrowserConsentPolicy = BrowserConsentPolicy(),
        denyListStore: any ConsentDenyListStoring = InMemoryConsentDenyListStore(),
    ) {
        self.detector = detector
        self.recorderFactory = recorderFactory
        self.pipelineQueue = pipelineQueue
        self.pollInterval = pollInterval
        self.endGracePeriod = endGracePeriod
        self.maxDuration = maxDuration
        self.capWarningLead = capWarningLead
        self.meetingEndCountdown = meetingEndCountdown
        self.noMic = noMic
        self.micDeviceUID = micDeviceUID
        self.verboseDiagnostics = verboseDiagnostics
        self.recordOnly = recordOnly
        self.recordOnlyDestination = recordOnlyDestination
        self.recordOnlyFileTransfer = recordOnlyFileTransfer
        self.notifier = notifier
        self.diagnostics = diagnostics
        self.nowProvider = nowProvider
        self.sleepProvider = sleepProvider
        self.pidAliveCheck = pidAliveCheck
        self.consentPolicy = consentPolicy
        self.denyListStore = denyListStore
        self.recordWithoutAskingApps = recordWithoutAskingApps
        self.silencePrompt = SilencePromptRuntime(speechActivity: speechActivity, after: silencePromptAfter)
    }

    nonisolated static var defaultOutputDir: URL {
        AppPaths.downloadsProtocolsDir
    }

    nonisolated static func defaultDetector() -> any MeetingDetecting {
        PowerAssertionDetector()
    }

    // MARK: - Start / Stop

    func start() {
        guard watchTask == nil else { return }

        returnToWatching()
        logger.info("Watch mode started (poll: \(self.pollInterval)s, grace: \(self.endGracePeriod)s)")

        watchTask = Task { [weak self] in
            guard let self else { return }
            await self.watchLoop()
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        // Answer a parked prompt before the state goes idle: a question that
        // outlives the watching it was asked on behalf of would sit in
        // Notification Center offering to record with watching switched off.
        declineParkedConsent()
        cleanupManualRecording()
        redetectionHolds.removeAll()
        update { next in
            next.phase = .idle
            next.currentMeeting = nil
            next.detail = ""
        }
        logger.info("Watch mode stopped")
    }

    /// Whether a quit has to wait for this loop: it is watching (and so may be
    /// recording, or about to), or a manual recording is running.
    var hasWorkBeforeQuit: Bool {
        watchTask != nil || activeRecorder != nil
    }

    /// Set by `finishForQuit`: the recording in flight is stopped with
    /// `stopOffMain`, so the quit's budget (a main-actor timer) can fire while
    /// the mix runs (see `TerminationFlush.recordingBudget` for what it does
    /// not bound), and a manual start still waiting for its recorder gives up
    /// instead of recording into the exit.
    var finishingForQuit = false

    /// Stop for a quit, returning once whatever was recording has been
    /// enqueued (or written record-only). `stop()` is not enough: it drops a
    /// manual recording unstopped, and the watch task finalizes an auto one
    /// after `stop()` has returned. A mix the exit cuts off is re-mixed by the
    /// next launch's crash recovery, without the title, app and participants.
    func finishForQuit() async {
        finishingForQuit = true
        await stopManualRecordingForQuit()
        let recording = watchTask
        stop()
        await recording?.value
    }

    // MARK: - Manual Recording

    func startManualRecording(pid: pid_t, appName: String, title: String, protocolOptions: MeetingProtocolOptions? = nil) async throws {
        try await startManualRecording(
            source: .forApp(pid: pid, noMic: noMic()),
            appName: appName,
            title: title,
            protocolOptions: protocolOptions,
        )
    }

    /// Record the microphone with no process tap, for a meeting that happens in
    /// the room rather than in an app (issue #633).
    ///
    /// Deliberately ignores `noMic`: that setting decides whether an *app*
    /// recording also takes the microphone, and honouring it here would turn
    /// this into a recording of nothing. Keeping the entry point out of reach
    /// while it is set is the menu's job, not this one's — a caller that got
    /// here asked for the microphone by name.
    func startMicrophoneRecording(protocolOptions: MeetingProtocolOptions? = nil) async throws {
        try await startManualRecording(
            source: .micOnly,
            appName: ManualRecordingInfo.microphoneAppName,
            title: ManualRecordingInfo.microphoneTitle,
            protocolOptions: protocolOptions,
        )
    }

    private func startManualRecording(
        source: RecordingSource,
        appName: String,
        title: String,
        protocolOptions: MeetingProtocolOptions?,
    ) async throws {
        guard state != .recording else {
            logger.warning("Cannot start manual recording — already recording")
            return
        }
        // Read before the awaits, like the `noMic` behind `source`.
        let micDeviceUID = micDeviceUID()

        // Gate on what this path needs, not on overall health (see `blocksRecording`).
        let health = await permissionChecker()
        if let refusal = health.recordingRefusalReason(for: source) {
            throw RecorderError.permissionDenied(refusal)
        }

        // Stop auto-watch if active
        watchTask?.cancel()
        watchTask = nil
        // Same reason as in `stop()`: with the poll loop gone there is nothing
        // left to act on an answer, so the question must not stay open.
        declineParkedConsent()

        let recorder = await recorderFactory()
        // The quit may have begun while the recorder was being built.
        guard !finishingForQuit else { throw CancellationError() }
        try recorder.start(
            source: source, micDeviceUID: micDeviceUID,
            debugLogging: verboseDiagnostics(),
        )
        let startedAt = nowProvider()
        silencePrompt.manualStartedAt = startedAt
        recordingPauses = RecordingPauseRecord(startedAt: startedAt)

        let pid = source.appPID
        recordingSource = source
        activeRecorder = recorder
        update { next in
            next.phase = .recording
            next.manualRecordingInfo = ManualRecordingInfo(pid: pid, appName: appName, title: title, protocolOptions: protocolOptions)
            next.detail = "Recording: \(title)"
        }

        manualRecordingTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorManualRecording(pid: pid)
        }

        let target = pid.map { "PID \($0)" } ?? "no target process"
        logger.info("Manual recording started for \(appName) (\(target)): \(title, privacy: .private)")
    }

    func stopManualRecording(cutAt: Date? = nil) {
        guard let (recorder, info) = takeManualRecording() else { return }
        do {
            let (recording, pauses) = try stopManualCapture(recorder, cutAt: cutAt)
            enqueueRecording(
                title: info.title, appName: info.appName, recording: recording, trigger: .manual, pauses: pauses,
                protocolOptions: info.protocolOptions,
            )
            finishManualRecording(failure: nil)
        } catch {
            finishManualRecording(failure: error)
        }
    }

    private func stopManualRecordingForQuit() async {
        guard let (recorder, info) = takeManualRecording() else { return }
        do {
            try await stopAndEnqueueForQuit(
                recorder, title: info.title, appName: info.appName, trigger: .manual,
                protocolOptions: info.protocolOptions,
            )
            finishManualRecording(failure: nil)
        } catch {
            finishManualRecording(failure: error)
        }
    }

    /// Clears the bookkeeping before the recorder stops, so the level poll
    /// and a second stop find no recorder that is half stopped.
    private func takeManualRecording() -> (any RecordingProvider, ManualRecordingInfo)? {
        guard let recorder = activeRecorder, let info = manualRecordingInfo else { return nil }
        manualRecordingTask?.cancel()
        manualRecordingTask = nil
        activeRecorder = nil
        return (recorder, info)
    }

    /// `failure` is what the stop threw, nil when it produced a recording.
    private func finishManualRecording(failure: (any Error)?) {
        var failureMessage: String?
        if let failure {
            logger.error("Failed to stop manual recording: \(failure.localizedDescription, privacy: .public)")
            if !isNothingRecordedAtQuit(failure) { failureMessage = failure.localizedDescription }
        }

        update { next in
            next.phase = .idle
            next.manualRecordingInfo = nil
            next.detail = ""
            if let failureMessage { next.lastError = failureMessage }
        }
        if !finishingForQuit { onManualRecordingEnded?() }
    }

    private func cleanupManualRecording() {
        endSilencePrompt()
        manualRecordingTask?.cancel()
        manualRecordingTask = nil
        activeRecorder = nil
        update { next in next.manualRecordingInfo = nil }
    }

    // MARK: - Watch Loop

    private func watchLoop() async {
        while !Task.isCancelled {
            releaseEndedRedetectionHolds()
            // A prompt answered since the last poll comes first: the answer
            // arrives out of band, but recordings only ever start here.
            // Re-checked because up to a poll interval has passed since the
            // answer, and the call may have ended in it.
            if let approved = takeApprovedConsent(), detector.isMeetingActive(approved.meeting),
               !appsHeldFromDetection.contains(approved.meeting.pattern.identityKey) {
                if await runMeeting(approved.meeting, protocolOptions: approved.protocolOptions) { return }
            } else if let meeting = detector.checkOnce(excluding: appsExcludedFromDetection.union(appsHeldFromDetection)) {
                // A detected meeting asks before recording unless its app
                // records without asking. See WatchLoop+Consent.swift.
                // Asking does NOT block this loop — that is the whole point:
                // an unanswered prompt used to stop `checkOnce()` from running
                // for a full minute, so a call that needed no prompt and
                // started in that window went unrecorded. The app being asked
                // about, and every app waiting for that answer, is excluded
                // from detection for the same reason: each is re-detected
                // every poll, and as the one meeting a poll returns it would
                // hide every other app's call behind it.
                if requestConsentIfNeeded(for: meeting) {
                    try? await sleepProvider(pollInterval)
                    continue
                }
                if await runMeeting(meeting) { return }
            }

            try? await sleepProvider(pollInterval)
        }
    }

    /// Record one meeting to completion and return to watching. True means the
    /// loop was cancelled mid-recording and must exit.
    private func runMeeting(_ meeting: DetectedMeeting, protocolOptions: MeetingProtocolOptions? = nil) async -> Bool {
        var endReason = MeetingEndReason.ended
        do {
            endReason = try await handleMeeting(meeting, protocolOptions: protocolOptions)
        } catch {
            if error is CancellationError || isNothingRecordedAtQuit(error) { return true }
            let msg = "Recording error: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            update { next in
                next.phase = .error
                next.lastError = error.localizedDescription
                next.detail = "Recording error: \(error.localizedDescription)"
            }
            try? await sleepProvider(10)
        }

        // After a split the next call is already live. Neither the cooldown
        // nor a reset applies: the app's confirmation count still stands
        // from the detection that started this recording, so this poll
        // confirms the new call at once instead of `confirmationCount` polls
        // later, which would cut its first seconds. It still passes the
        // consent gate like any detection.
        var nextCall: DetectedMeeting?
        if endReason == .replacedByNewCall {
            if !Task.isCancelled,
               let next = detector.checkOnce(excluding: appsExcludedFromDetection.union(appsHeldFromDetection)) {
                if !requestConsentIfNeeded(for: next) { nextCall = next }
            } else {
                detector.reset()
            }
        } else {
            detector.reset(appName: meeting.pattern.identityKey)
        }

        // Back to watching first, also after a split, so the next recording
        // gets its own `.recording` transition. Both transitions run in one
        // main-actor stretch, so no UI renders the gap. A split straight into
        // the next call is marked so the handler skips what only a real stop
        // does (see `PhaseChangeCause`).
        if !Task.isCancelled { returnToWatching(cause: nextCall == nil ? .regular : .callSplit) }
        if let nextCall { return await runMeeting(nextCall) }
        return false
    }

    private func returnToWatching(cause: PhaseChangeCause = .regular) {
        update(cause: cause) { next in
            next.phase = .watching
            next.currentMeeting = nil
            next.detail = "Polling for meetings..."
        }
    }

    // MARK: - Meeting Handling

    @discardableResult
    func handleMeeting(_ meeting: DetectedMeeting, protocolOptions: MeetingProtocolOptions? = nil) async throws -> MeetingEndReason {
        defer { stopByHandRequestedAt = nil }
        onMeetingCapture?(true)
        defer { onMeetingCapture?(false) }
        let title = Self.cleanTitle(meeting.windowTitle)

        // --- Recording ---
        let source = RecordingSource.forApp(pid: meeting.windowPID, noMic: noMic())
        let micDeviceUID = micDeviceUID()
        recordingSource = source
        update { next in
            next.phase = .recording
            next.currentMeeting = meeting
            next.detail = "Recording: \(title)"
            next.lastError = nil
        }

        let recorder = await recorderFactory()
        // A quit or a stop that came while the recorder was being built: a
        // recording started now would end at once, empty, as an error.
        try Task.checkCancellation()
        try recorder.start(
            source: source,
            micDeviceUID: micDeviceUID,
            debugLogging: verboseDiagnostics(),
        )
        activeRecorder = recorder
        defer { activeRecorder = nil }
        // Where a cut is measured from, with the stop below (see `cutBack`).
        let recordingStartedAt = nowProvider()
        recordingPauses = RecordingPauseRecord(startedAt: recordingStartedAt)

        // Read participants (Teams)
        var participants: [String] = []
        if meeting.pattern.appName == "Microsoft Teams",
           let names = ParticipantReader.readParticipants(pid: meeting.windowPID),
           !names.isEmpty {
            logger.info("Detected \(names.count) participants")
            participants = names
        }

        // Wait for the meeting to end. A cancelled watch task (Stop Watching,
        // which calls `stop()` → `watchTask.cancel()`) comes back here like a
        // natural end, so the recording is finalized rather than discarded
        // (see `waitForMeetingEnd` and `finishMeetingRecording`).
        let end = try await waitForMeetingEnd(meeting, storingCutsIn: (recorder, recordingStartedAt))
        try await finishMeetingRecording(
            meeting, recorder: recorder, startedAt: recordingStartedAt, end: end,
            participants: participants, protocolOptions: protocolOptions,
        )
        return end.reason
    }

    // MARK: - Helpers

    /// Single funnel through which every observable-field mutation flows.
    /// Build the next snapshot, hand it to `apply` to commit only the
    /// fields that actually changed, and let `apply` fire `onStateChange`
    /// on a phase transition. Co-located mutations stay coherent
    /// (a phase-change-plus-detail-update is one funnel call, not two
    /// separate property writes that consumers could observe mid-flight).
    /// Every way out of `.recording` also ends a pause. Internal so the
    /// extensions in `WatchLoop+*.swift` write through it too.
    func update(cause: PhaseChangeCause = .regular, _ transform: (inout WatchLoopState) -> Void) {
        var next = snapshot
        transform(&next)
        if next.phase != .recording { next.pausedSince = nil }
        apply(next, cause: cause)
    }

    /// Commit a new snapshot field-wise. Each `if old != new { old = new }`
    /// guard avoids gratuitous `@Observable` invalidations for fields the
    /// transform left alone; emit `onStateChange` if the phase moved.
    private func apply(_ next: WatchLoopState, cause: PhaseChangeCause) {
        let oldPhase = state
        if state != next.phase { state = next.phase }
        if currentMeeting != next.currentMeeting { currentMeeting = next.currentMeeting }
        if lastError != next.lastError { lastError = next.lastError }
        if detail != next.detail { detail = next.detail }
        if manualRecordingInfo != next.manualRecordingInfo {
            manualRecordingInfo = next.manualRecordingInfo
        }
        if pausedSince != next.pausedSince { pausedSince = next.pausedSince }
        if oldPhase == .recording, next.phase != .recording { recordingSource = nil }
        if oldPhase != next.phase {
            onStateChange?(oldPhase, next.phase, cause)
        }
    }
}
