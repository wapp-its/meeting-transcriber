// swiftlint:disable file_length
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// Output policy captured when a job enters the queue. Capturing it per job
/// means a Settings change applies to the next recording without changing the
/// privacy semantics of a recording that is already being processed.
struct TranscriptOutputOptions {
    let includeFullTranscriptInProtocol: Bool
    let saveRawTranscriptSeparately: Bool
    let useAITitleForFilenames: Bool
}

/// Raw diarization output for one run of the diarize loop. `combined` is the
/// result fed into speaker naming (the prefixed dual-track merge, the app-only
/// or mic-only single-track fallback, or the single-source result); `app`/`mic`
/// are retained for the dual-track assignment step. Internal top-level (not `PipelineQueue`-nested)
/// because it crosses the queue ↔ `SpeakerNamingSession` boundary in both
/// directions via `SpeakerNamingSessionDelegate`.
struct DiarizationRun {
    let app: DiarizationResult?
    let mic: DiarizationResult?
    let combined: DiarizationResult?
}

@MainActor
@Observable
// swiftlint:disable:next attributes type_body_length
class PipelineQueue {
    /// Internal setter (not `private(set)`) because the stage and recovery
    /// extension methods in sibling files (PipelineQueue+Stages.swift,
    /// PipelineQueue+Recovery.swift) mutate jobs across the file boundary:
    /// in-place field updates, snapshot restore (whole-array assign), and
    /// recovery appends.
    var jobs: [PipelineJob] = []
    @ObservationIgnored private var completedJobRemovalTokens: [UUID: UUID] = [:]
    /// Fires for every finished export, first attempt or retry, with the short
    /// failure cause or nil on success.
    @ObservationIgnored var onNotionExportFinished: ((PipelineJob, String?) -> Void)?
    @ObservationIgnored var pendingNotionExports: [UUID: PendingNotionExport] = [:]
    @ObservationIgnored var notionExportTasks: [UUID: NotionExportRun] = [:]
    /// Internal (not private) because `loadSnapshot` in PipelineQueue+Recovery.swift
    /// reads it to locate the snapshot file.
    let logDir: URL

    /// File-backed skip list of already-processed recordings, consulted by
    /// `recoverOrphanedRecordings` so completed jobs aren't re-queued as
    /// orphans on the next launch.
    let processedLedger: ProcessedRecordingsLedger

    /// Append-only JSONL log of job state transitions (`pipeline_log.jsonl`).
    /// Self-ensures its own dir, so it doesn't share the queue's cached
    /// `logDirCreated` flag.
    let eventLog: PipelineEventLog

    /// Jobs the restore found interrupted mid-protocol, and what to do with
    /// them, derived from the snapshot state before it was reset to `.waiting`.
    ///
    /// Deliberately not persisted: the snapshot state IS the durable marking,
    /// and a quit before the resume runs simply degrades to a full run rather
    /// than losing anything. A second field would have to be kept in step with
    /// the state it was derived from, for no gain.
    var protocolResumeDispositions: [UUID: ProtocolResumeDisposition] = [:]

    /// The snapshot file did not read when this queue restored from it, so `jobs`
    /// says nothing about the jobs saved there. A queue that adopts this one's jobs
    /// takes this over with them; the next launch reads whatever the file holds then.
    var snapshotRestoreFailed = false

    /// Whether the protocol stage found a generator for a job, kept until the
    /// job's terminal state hands it to the meeting's outcome. The setting can
    /// change while the call runs, and a meeting is judged by the attempt it got.
    ///
    /// Not persisted: a quit restarts the stage, which decides again.
    var protocolGenerationOn: [UUID: Bool] = [:]

    // Dependencies for processing
    let engine: (any TranscribingEngine)?
    let diarizationFactory: (() -> any DiarizationProvider)?
    /// Optional mode-overriding factory used by `lateDiarization` when the
    /// user picks a different mode in the re-run UI. `nil` = mode override
    /// not supported, `lateDiarization` falls back to `diarizationFactory()`
    /// (current global setting). Production wires both via `AppState`.
    let diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)?
    let protocolGeneratorFactory: (() -> (any ProtocolGenerating)?)?
    let outputDir: URL?
    /// Opens and closes security-scoped access on `outputDir`. Injectable so a
    /// test can record where and when the scope is held; see `SecurityScopeAccess`.
    let securityScope: SecurityScopeAccess
    /// `outputDir`, when this queue holds the security scope on it.
    ///
    /// Opened once in `init`, on the URL object this queue was built with (the
    /// one that resolved from the bookmark), and closed in `deinit`. Everything
    /// the queue and its naming session read or write under the output folder
    /// therefore runs inside it, with no call site opening a scope of its own.
    /// One scope for the lifetime rather than one per call, because the defect
    /// this replaces was a call site that opened none, or opened it on the
    /// wrong URL. A rebuilt queue opens its own; the queue it replaces keeps
    /// its scope until it is deallocated, which a running job delays, since
    /// the processing task holds the queue until the job returns.
    private let scopedOutputDir: URL?
    /// Where `DualSourceRecorder` writes, i.e. the audio this app produced and
    /// may therefore relocate. Injectable so a test can exercise the hand-off
    /// without writing into the real user directory; see `AudioPersistencePolicy`.
    let stagingDir: URL
    let diarizeEnabled: Bool
    /// Leave loudspeaker copies out of the transcript (`AppSettings.echoDedupEnabled`).
    let echoDedupEnabled: Bool

    /// Take the far end out of the microphone audio (`AppSettings.echoCancellationEnabled`).
    /// Wins over `echoDedupEnabled`; `EchoRemedy` holds that precedence.
    ///
    /// Read through a closure rather than copied at construction. The queue is
    /// built once when watching starts, so a copied value meant turning the
    /// feature on mid-session did nothing at all until watching was restarted:
    /// the switch said yes and the next recording was processed by a queue
    /// still holding no. Its neighbours here are still copies, which is the
    /// same latent problem; widening that is not this change's to make, and
    /// `transcriptOutputOptionsProvider` below shows the shape it would take.
    private let isEchoCancellationEnabled: () -> Bool

    var echoCancellationEnabled: Bool {
        isEchoCancellationEnabled()
    }

    /// Produces the canceller for a run, or nil when no model can be resolved.
    ///
    /// Stored non-optional with the production resolution as its default, so
    /// there is one thing to call rather than a factory and a fallback path
    /// that only one of them is ever tested. Returning an optional is what
    /// makes "no model available" injectable at all: with a factory that
    /// always produced a canceller, the branch that reports a missing model
    /// could only be reached by removing the file from the machine.
    let echoCancellerFactory: () -> (any EchoCancelling)?
    let numSpeakers: Int
    let micLabel: String
    /// Compatibility policy for snapshots created before a job carried its own
    /// output options.
    private let fallbackTranscriptOutputOptions: TranscriptOutputOptions
    /// Reads the current Settings only when a job is enqueued; the values are
    /// then copied onto the job and remain stable for its whole lifecycle.
    private let transcriptOutputOptionsProvider: () -> TranscriptOutputOptions
    /// Where a job's protocol template is read when its protocol is made.
    /// Internal because `generateProtocol` in PipelineQueue+Stages.swift reads it.
    let protocolTemplateStore: ProtocolTemplateStore
    /// The current default template: stamped on a job when it is admitted, and
    /// used for a job without one (an older snapshot, or a job no longer queued).
    /// Internal for the same reason as `protocolTemplateStore`.
    let defaultProtocolTemplateProvider: () -> ProtocolTemplateID
    let speakerMatcherFactory: () -> SpeakerMatcher
    let vadConfig: VADConfig?
    /// nil disables JSONL logging. AppState injects a real instance for production;
    /// tests leave it nil unless they explicitly want to assert on the log.
    let recognitionStatsLog: RecognitionStatsLog?
    /// Explicit canonical spelling rules, applied after the ASR engine returns
    /// text. Kept separate from decoder vocabulary because decoder hints are
    /// probabilistic while representation rules are deterministic.
    let terminologyNormalizer: () -> TerminologyNormalizer

    /// nil disables per-stage timing capture. AppState injects a real instance;
    /// tests leave it nil unless asserting on the log.
    let stageTimingLog: StageTimingLog?

    let completedJobLifetime: TimeInterval

    /// Resolve the exporter and its destination/output policy together for each export.
    let notionExportConfigurationProvider: (() -> NotionExportResolution)?

    /// Process-wide claim on the runs currently executing, so a replacement
    /// queue cannot start a job the queue it replaced is still working on.
    /// Defaults to the shared instance; tests inject their own to stay isolated
    /// from each other.
    let inFlightRuns: InFlightRunRegistry

    /// Durable store of finished-job records for the automation API readback.
    /// nil (default) disables it; production injects one, tests opt in.
    let terminalJobStore: TerminalJobStore?

    /// Durable record of each meeting's files, which deleting them reads. Same
    /// wiring as `terminalJobStore`: nil disables it, production injects one
    /// that outlives queue rebuilds.
    let meetingFileStore: MeetingFileStore?

    /// Cached FluidVAD instance — reused across jobs to avoid model reload.
    /// Internal (not private) because `preprocessWithVAD` in
    /// PipelineQueue+Stages.swift reads and writes it.
    var vad: FluidVAD?

    /// Internal setter (not `private(set)`) because `processNext` in
    /// PipelineQueue+Stages.swift clears this flag across the file boundary.
    var isProcessing = false

    /// Each job's running stage, as its menu line reads it. Changes only at a
    /// job event: a stage starting or ending, and the audio length becoming
    /// known. Never on a timer and never on a history reload, because the
    /// menu is rebuilt under the pointer whenever a value it reads changes.
    /// Read via `stageClock(forJobID:)`.
    private(set) var stageClocks: [UUID: StageClock] = [:]

    /// Historical wall-clock seconds per audio second per configuration (last
    /// 30 days), read only when a running stage's expected finish is filled
    /// in. Read from `stageTimingLog` when the queue is created and reloaded
    /// after each stage; empty until the log has data. No view reads it, so a refresh redraws
    /// nothing. Readable so a test can see which log a queue loaded.
    @ObservationIgnored private(set) var stageSpeedByConfig: [StageConfig: Double] = [:]

    /// How far back the speeds look.
    private static let stageHistoryWindow: TimeInterval = 30 * 86400

    /// When the current `.transcribing`/`.diarizing`/`.generatingProtocol` state
    /// was entered, per job — so `updateJobState` can record the state's duration
    /// on exit (keyed by job to stay correct if transitions ever interleave).
    /// Ignored by observation on purpose: no view needs a re-render when a stage
    /// starts, because `jobs[].state` is observed on its own, and a view that read
    /// this dictionary would be rebuilt on every transition for no gain.
    @ObservationIgnored private var stageStartByJob: [UUID: ContinuousClock.Instant] = [:]
    /// Seconds of sub-stages already logged as events of their own inside a
    /// job's current stage (the echo canceller's run inside `.transcribing`),
    /// taken out of the enclosing stage's event when that stage is left.
    /// Ignored by observation for the same reason as `stageStartByJob`.
    @ObservationIgnored private var excludedSubStageSecondsByJob: [UUID: Double] = [:]
    /// Audio length (seconds) each job processed, captured when transcription
    /// completes, so stage durations can be normalised into an RTF.
    /// Internal (not private) because `transcribe` in PipelineQueue+Stages.swift stamps it.
    var jobAudioSeconds: [UUID: Double] = [:]

    private var processTask: Task<Void, Never>?
    #if !APPSTORE
        /// The gate of the local generators this queue ran, so a cancel reaches
        /// a helper started from any path. Taken from the generator rather than
        /// handed in: it is the gate the job's generation went through, also
        /// after the provider was switched mid-run. Internal (not private)
        /// because PipelineQueue+LocalModel.swift sets it.
        @ObservationIgnored var localModelGate: LocalModelGate?
        /// Told what the protocol stage's local generations come to, for the
        /// notices of spec R4, R5 and R8 (`LocalModelJobNotices`).
        @ObservationIgnored var onLocalModelEvent: ((LocalModelEvent) -> Void)?
    #endif
    /// The task running each job's pipeline run, for as long as the run lasts.
    /// Cancelling a job cancels its entry here and nothing else. The job's state
    /// cannot stand in for this: a late speaker re-run and a late confirm move a
    /// job back to `.diarizing` / `.generatingProtocol` on a task of the naming
    /// session's own, while the queue may be running a different job.
    ///
    /// The run's own task rather than `processTask`, because `processTask` is
    /// only one of the ways into `processNext`: a caller awaiting `processNext`
    /// directly runs the job on its own task, and cancelling `processTask` then
    /// stopped whatever that task held, or nothing. Keyed by job rather than a
    /// single slot for the same reason: two such entries can overlap.
    /// Internal (not private) because `processNext` in PipelineQueue+Stages.swift
    /// fills it.
    @ObservationIgnored var pipelineRuns: [UUID: Task<Bool, Never>] = [:]
    /// The move of the last cancelled job's recording, which runs off the main
    /// actor. Tests await it; nothing else needs to.
    /// Internal (not private) because `relocateRecordingOfCancelledJob` in
    /// PipelineQueue+Stages.swift sets it.
    @ObservationIgnored var lastRecordingRelocation: Task<Void, Never>?

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    /// Called when confirming a job's speakers left names out of the speaker
    /// DB because their voice sample was unusable (NaN/Inf embedding), at
    /// most once per name and job — for notifications.
    var onUnusableVoices: ((PipelineJob, [String]) -> Void)?
    /// Names `onUnusableVoices` already reported, per job. A job can be
    /// confirmed more than once (late naming, re-runs): the same name needs
    /// telling once, a newly affected one still does.
    private var unusableVoicesReported: [UUID: Set<String>] = [:]

    // MARK: - Speaker Naming

    /// Owns the speaker-naming session (dialog, sidecars, recognition
    /// forensics, late re-run). Held strongly; the session holds this queue as
    /// a *weak* delegate, so there's no retain cycle. Exposed as a stored
    /// property so SwiftUI observation follows into the nested `@Observable`
    /// when the UI reads the forwarders below.
    let naming: SpeakerNamingSession

    /// RAM cache of naming data, owned by `naming`. Forwarded (get + set) so the
    /// direct-dict reads at `PipelineController` / `AppState+RPC` and the tests
    /// keep working AND keep observing the session's storage.
    var speakerNamingDataByJob: [UUID: SpeakerNamingData] {
        get { naming.speakerNamingDataByJob }
        set { naming.speakerNamingDataByJob = newValue }
    }

    /// Handler for speaker naming, owned by `naming`. Forwarded so tests can set
    /// it on the queue as before. When set, called instead of the default
    /// continuation-based popup.
    var speakerNamingHandler: ((SpeakerNamingData) async -> SpeakerNamingResult)? {
        get { naming.speakerNamingHandler }
        set { naming.speakerNamingHandler = newValue }
    }

    /// Naming data of the first job awaiting naming, nil when there is none.
    var pendingSpeakerNaming: SpeakerNamingData? {
        speakerNamingData(forJobID: nil)
    }

    /// Filesystem slug for a job's persisted artefacts. Thin alias for
    /// `SpeakerNamingStore.slug` — kept so existing call sites (`processNext`,
    /// tests) don't have to reach into the store for a pure helper.
    static func namingSlug(title: String, jobID: UUID, startTime: Date) -> String {
        SpeakerNamingStore.slug(title: title, jobID: jobID, startTime: startTime)
    }

    /// The job the naming window shows: `preferred` while it is awaiting
    /// naming, else the first job that is. Only ever a job awaiting naming.
    /// A selection can outlive that state (a re-run moves its job to
    /// `.diarizing`, and the window reopens when another job reaches naming),
    /// and showing that job again would offer a dialog whose answers the
    /// session no longer takes.
    func namingJobID(preferring preferred: UUID?) -> UUID? {
        let pending = pendingSpeakerNamingJobs
        if let preferred, pending.contains(where: { $0.id == preferred }) { return preferred }
        return pending.first?.id
    }

    /// Why the job's last re-run came back with nothing, for the dialog.
    func lateRerunFailure(forJobID jobID: UUID) -> SpeakerNamingRefusal? {
        naming.lateRerunFailures[jobID]
    }

    /// Naming data for the job `namingJobID(preferring:)` picks.
    func speakerNamingData(forJobID jobID: UUID?) -> SpeakerNamingData? {
        namingJobID(preferring: jobID).flatMap { speakerNamingDataByJob[$0] }
    }

    /// Diarizer mode used to produce the current `speakerNamingDataByJob`
    /// entry for the given job. `nil` for legacy jobs persisted before the
    /// field existed — callers fall back to the current global setting.
    func usedDiarizerMode(forJobID jobID: UUID) -> DiarizerMode? {
        jobs.first { $0.id == jobID }?.usedDiarizerMode
    }

    /// Jobs in speakerNamingPending state.
    var pendingSpeakerNamingJobs: [PipelineJob] {
        jobs.filter { $0.state == .speakerNamingPending }
    }

    /// Called by the UI (and the test handler) when the user confirms, skips, or
    /// re-runs speaker naming. Thin forwarder to the naming session, which
    /// always handles "late" completion — the pipeline never blocks on naming.
    /// Returns why the answer was not taken, nil when it was.
    @discardableResult
    func completeSpeakerNaming(
        jobID: UUID, result: SpeakerNamingResult, source: RecognitionSource = .dialog,
    ) -> SpeakerNamingRefusal? {
        naming.completeSpeakerNaming(jobID: jobID, result: result, source: source)
    }

    /// Called by the UI when the user confirms or skips speaker naming without a
    /// specific job in hand — resolves the first pending job and forwards to
    /// the session, which takes answers only for a job awaiting naming.
    func completeSpeakerNaming(result: SpeakerNamingResult, source: RecognitionSource = .dialog) {
        guard let jobID = pendingSpeakerNamingJobs.first?.id else { return }
        naming.completeSpeakerNaming(jobID: jobID, result: result, source: source)
    }

    /// Default factory for `speakerMatcherFactory`: a matcher that writes to a
    /// throwaway tmp path. Production callers (AppState) MUST inject an explicit
    /// factory pointing at the real `speakers.json`. This keeps the user's real
    /// DB safe from any test that constructs a PipelineQueue without injection.
    nonisolated static func throwawayMatcherFactory() -> () -> SpeakerMatcher {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineQueue-throwaway-\(UUID().uuidString).json")
        return { SpeakerMatcher(dbPath: path) }
    }

    /// Performs the actual disk write for the snapshot worker. Defaults to
    /// `PipelineSnapshot.save`; tests inject substitutes to count writes or
    /// simulate a stalled `replaceItemAt`.
    let snapshotWriter: @Sendable ([PipelineJob], URL) throws -> Void

    /// Simple init for skeleton tests and basic queue usage.
    ///
    /// `stagingDir` is a parameter rather than always `AppPaths.recordingsDir`
    /// because this queue decides from it whether finished audio is the app's
    /// own to relocate; a caller working in temp folders must be able to say so.
    ///
    /// `logDir` has no default for the same reason, more strongly: the snapshot,
    /// the event log and the processed-recordings ledger all live there, so a
    /// default of the app's own folder put every caller that left it out into
    /// the installed app's queue and history. Production passes
    /// `AppPaths.ipcDir` through `PipelineController.QueueEnvironment.production`.
    init(
        logDir: URL,
        stagingDir: URL = AppPaths.recordingsDir,
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = PipelineQueue.throwawayMatcherFactory(),
        snapshotWriter: @escaping @Sendable ([PipelineJob], URL) throws -> Void = PipelineSnapshot.save,
        stageTimingLog: StageTimingLog? = nil,
        completedJobLifetime: TimeInterval = 60,
        notionExportConfigurationProvider: (() -> NotionExportResolution)? = nil,
        terminalJobStore: TerminalJobStore? = nil,
        meetingFileStore: MeetingFileStore? = nil,
        inFlightRuns: InFlightRunRegistry? = nil,
        echoCancellationEnabled: @escaping () -> Bool = { false },
        echoCancellerFactory: (() -> (any EchoCancelling)?)? = nil,
        defaultProtocolTemplateProvider: @escaping () -> ProtocolTemplateID = { .builtIn },
        protocolTemplateStore: ProtocolTemplateStore = .production,
    ) {
        self.logDir = logDir
        self.processedLedger = ProcessedRecordingsLedger(logDir: self.logDir)
        eventLog = PipelineEventLog(logDir: self.logDir)
        self.engine = nil
        self.diarizationFactory = nil
        self.diarizationFactoryWithMode = nil
        self.protocolGeneratorFactory = nil
        self.outputDir = nil
        securityScope = .live
        scopedOutputDir = nil
        self.stagingDir = stagingDir
        self.diarizeEnabled = false
        echoDedupEnabled = true
        isEchoCancellationEnabled = echoCancellationEnabled
        self.echoCancellerFactory = echoCancellerFactory ?? { Self.bundledEchoCanceller() }
        self.numSpeakers = 0
        self.micLabel = "Me"
        let outputOptions = TranscriptOutputOptions(
            includeFullTranscriptInProtocol: true,
            saveRawTranscriptSeparately: true,
            useAITitleForFilenames: false,
        )
        fallbackTranscriptOutputOptions = outputOptions
        transcriptOutputOptionsProvider = { outputOptions }
        self.protocolTemplateStore = protocolTemplateStore
        self.defaultProtocolTemplateProvider = defaultProtocolTemplateProvider
        self.speakerMatcherFactory = speakerMatcherFactory
        self.snapshotWriter = snapshotWriter
        self.vadConfig = nil
        self.recognitionStatsLog = nil
        terminologyNormalizer = { TerminologyNormalizer() }
        self.stageTimingLog = stageTimingLog
        self.completedJobLifetime = completedJobLifetime
        self.notionExportConfigurationProvider = notionExportConfigurationProvider
        self.terminalJobStore = terminalJobStore
        self.meetingFileStore = meetingFileStore
        self.inFlightRuns = inFlightRuns ?? .shared
        naming = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: speakerMatcherFactory,
        )
        naming.delegate = self
        naming.onFilesChanged = { [weak self] in self?.noteNamingFiles(jobID: $0, $1) }
    }

    // MARK: - Known speaker names (issue #155)

    //
    // Cached snapshot of speaker names for the SpeakerNamingView's
    // "known voices" chip row. SwiftUI re-evaluates view bodies often
    // (every keystroke / hover / @State change in any sub-view), so
    // doing the work in the body — `speakerMatcherFactory().allSpeakerNames()`
    // — re-opens speakers.json and re-decodes every embedding per render.
    // With ~37 embeddings the main thread pinned at 100% CPU after
    // extended uptime (issue #155).
    //
    // The cache is refreshed on init and after every code path that
    // mutates the on-disk DB (recognition outcomes, rename, delete,
    // merge). UI reads `knownSpeakerNames` directly with zero I/O.

    private(set) var knownSpeakerNames: [String] = []

    func refreshKnownSpeakerNames() {
        let next = speakerMatcherFactory().allSpeakerNames()
        // Compare-before-assign: @Observable fires SwiftUI invalidations on
        // every set, even when the value is identical. The factory + decode
        // already happened at this point, but skipping the assign keeps
        // downstream view bodies from re-rendering unnecessarily.
        guard next != knownSpeakerNames else { return }
        knownSpeakerNames = next
    }

    /// Apply a speaker DB update via the matcher AND refresh the cached
    /// names in one step. Use instead of calling `matcher.updateDB(...)` +
    /// `refreshKnownSpeakerNames()` separately at internal pipeline sites.
    /// Internal (not private) because it is the `SpeakerNamingSessionDelegate`
    /// witness the session calls from `reapplySpeakerNames`; keeping the
    /// write+refresh pairing here preserves its atomicity (issue #155).
    func updateSpeakerDB(
        matcher: SpeakerMatcher,
        mapping: [String: String],
        embeddings: [String: [Float]],
        speakingTimes: [String: TimeInterval],
        jobID: UUID,
    ) {
        let outcome = matcher.updateDB(
            mapping: mapping,
            embeddings: embeddings,
            speakingTimes: speakingTimes,
        )
        refreshKnownSpeakerNames()
        // A DB that could not be read or written is reported by the matcher
        // itself, and then no voice was kept; only when the rest was saved is
        // the per-voice skip this job's to report.
        let reported = unusableVoicesReported[jobID, default: []]
        let newlyUnusable = outcome.unusableVoice.filter { !reported.contains($0) }
        guard outcome.persistence == .saved, !newlyUnusable.isEmpty,
              let job = job(withID: jobID) else { return }
        unusableVoicesReported[jobID] = reported.union(newlyUnusable)
        onUnusableVoices?(job, newlyUnusable)
    }

    /// Notification text for `onUnusableVoices`.
    static func unusableVoicesMessage(_ names: [String], in job: PipelineJob) -> String {
        "No usable voice sample for \(names.joined(separator: ", ")) in \"\(job.meetingTitle)\": too short "
            + "or too quiet to remember, so it will not be recognised next time. The transcript keeps the name."
    }

    /// Full init with all processing dependencies.
    init(
        engine: any TranscribingEngine,
        diarizationFactory: @escaping () -> any DiarizationProvider,
        diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)? = nil,
        protocolGeneratorFactory: @escaping () -> (any ProtocolGenerating)?,
        outputDir: URL,
        logDir: URL,
        stagingDir: URL = AppPaths.recordingsDir,
        diarizeEnabled: Bool = false,
        echoDedupEnabled: Bool = true,
        echoCancellationEnabled: @escaping () -> Bool = { false },
        echoCancellerFactory: (() -> (any EchoCancelling)?)? = nil,
        numSpeakers: Int = 0,
        micLabel: String = "Me",
        includeFullTranscriptInProtocol: Bool = true,
        saveRawTranscriptSeparately: Bool = true,
        useAITitleForFilenames: Bool = false,
        transcriptOutputOptionsProvider: (() -> TranscriptOutputOptions)? = nil,
        defaultProtocolTemplateProvider: @escaping () -> ProtocolTemplateID = { .builtIn },
        protocolTemplateStore: ProtocolTemplateStore = .production,
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = PipelineQueue.throwawayMatcherFactory(),
        snapshotWriter: @escaping @Sendable ([PipelineJob], URL) throws -> Void = PipelineSnapshot.save,
        vadConfig: VADConfig? = nil,
        recognitionStatsLog: RecognitionStatsLog? = nil,
        terminologyNormalizer: @escaping () -> TerminologyNormalizer = { TerminologyNormalizer() },
        stageTimingLog: StageTimingLog? = nil,
        completedJobLifetime: TimeInterval = 60,
        notionExportConfigurationProvider: (() -> NotionExportResolution)? = nil,
        terminalJobStore: TerminalJobStore? = nil,
        meetingFileStore: MeetingFileStore? = nil,
        inFlightRuns: InFlightRunRegistry? = nil,
        securityScope: SecurityScopeAccess = .live,
    ) {
        self.logDir = logDir
        self.processedLedger = ProcessedRecordingsLedger(logDir: self.logDir)
        eventLog = PipelineEventLog(logDir: self.logDir)
        self.engine = engine
        self.diarizationFactory = diarizationFactory
        self.diarizationFactoryWithMode = diarizationFactoryWithMode
        self.protocolGeneratorFactory = protocolGeneratorFactory
        self.outputDir = outputDir
        self.securityScope = securityScope
        scopedOutputDir = securityScope.start(outputDir) ? outputDir : nil
        self.stagingDir = stagingDir
        self.diarizeEnabled = diarizeEnabled
        self.echoDedupEnabled = echoDedupEnabled
        isEchoCancellationEnabled = echoCancellationEnabled
        self.echoCancellerFactory = echoCancellerFactory ?? { Self.bundledEchoCanceller() }
        self.numSpeakers = numSpeakers
        // "Remote" is the reserved routing tag for the app/remote track
        // (DiarizationProcess.remoteSpeakerLabel). If the user names the mic
        // speaker that too, mergeDualSourceSegments tags both tracks identically
        // and labelSegments' per-track filters each match every segment → app
        // audio is double-counted under both speakers. Fall back to the default
        // so the two routing tags can never collide. (This is the single source
        // of micLabel for both the tagging and the re-split, so sanitizing here
        // keeps them consistent.)
        self.micLabel = micLabel == DiarizationProcess.remoteSpeakerLabel ? "Me" : micLabel
        let outputOptions = TranscriptOutputOptions(
            includeFullTranscriptInProtocol: includeFullTranscriptInProtocol,
            saveRawTranscriptSeparately: saveRawTranscriptSeparately,
            useAITitleForFilenames: useAITitleForFilenames,
        )
        fallbackTranscriptOutputOptions = outputOptions
        self.transcriptOutputOptionsProvider = transcriptOutputOptionsProvider ?? { outputOptions }
        self.protocolTemplateStore = protocolTemplateStore
        self.defaultProtocolTemplateProvider = defaultProtocolTemplateProvider
        self.speakerMatcherFactory = speakerMatcherFactory
        self.snapshotWriter = snapshotWriter
        self.vadConfig = vadConfig
        self.recognitionStatsLog = recognitionStatsLog
        self.terminologyNormalizer = terminologyNormalizer
        self.stageTimingLog = stageTimingLog
        self.completedJobLifetime = completedJobLifetime
        self.notionExportConfigurationProvider = notionExportConfigurationProvider
        self.terminalJobStore = terminalJobStore
        self.meetingFileStore = meetingFileStore
        self.inFlightRuns = inFlightRuns ?? .shared
        naming = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: outputDir),
            speakerMatcherFactory: speakerMatcherFactory,
            diarizationFactory: diarizationFactory,
            diarizationFactoryWithMode: diarizationFactoryWithMode,
            protocolGeneratorFactory: protocolGeneratorFactory,
            outputDir: outputDir,
            recognitionStatsLog: recognitionStatsLog,
        )
        naming.delegate = self
        naming.onFilesChanged = { [weak self] in self?.noteNamingFiles(jobID: $0, $1) }
        // Read here, not in a Task: a job the restore resumes enters its stage
        // right at launch, and a finish missed when a stage starts is never
        // filled in later. A small local file, read like the snapshot is.
        if let stageTimingLog {
            stageSpeedByConfig = StageTimingStats.speedByConfig(
                events: stageTimingLog.loadRecentNow(within: Self.stageHistoryWindow),
            )
        }
    }

    /// May run off the main actor: the snapshot worker can hold the last
    /// reference. `SecurityScopeAccess` requires `stop` to be callable from
    /// any thread for that reason.
    deinit {
        if let scopedOutputDir {
            securityScope.stop(scopedOutputDir)
        }
    }

    var activeJobs: [PipelineJob] {
        jobs.filter { [.transcribing, .diarizing, .generatingProtocol].contains($0.state) }
    }

    var pendingJobs: [PipelineJob] {
        jobs.filter { $0.state == .waiting }
    }

    /// A job whose origin is not named counts as an import, the safe side: a
    /// caller that forgets makes a meeting the app never deletes.
    func enqueue(_ job: PipelineJob) {
        enqueue(job, origin: .imported)
    }

    func enqueue(_ inputJob: PipelineJob, origin: MeetingFileRecord.Origin) {
        var job = inputJob
        stampTranscriptOutputOptions(on: &job)
        jobs.append(job)
        meetingFileStore?.create(MeetingFileRecord(job: job, origin: origin))
        eventLog.append(jobID: job.id, event: "enqueued", from: nil, to: job.state)
        saveSnapshot()
        logger.info("Enqueued job: \(job.meetingTitle, privacy: .private) (\(job.id))")
        triggerProcessing()
    }

    /// Resolves the output policy for an existing job. The fallback keeps
    /// snapshots from versions before per-job settings compatible.
    /// Internal because pipeline stages in sibling files use it.
    func transcriptOutputOptions(forJobID jobID: UUID) -> TranscriptOutputOptions {
        guard let job = jobs.first(where: { $0.id == jobID }) else {
            return fallbackTranscriptOutputOptions
        }
        return TranscriptOutputOptions(
            includeFullTranscriptInProtocol: job.includeFullTranscriptInProtocol
                ?? fallbackTranscriptOutputOptions.includeFullTranscriptInProtocol,
            saveRawTranscriptSeparately: job.saveRawTranscriptSeparately
                ?? fallbackTranscriptOutputOptions.saveRawTranscriptSeparately,
            useAITitleForFilenames: job.useAITitleForFilenames
                ?? fallbackTranscriptOutputOptions.useAITitleForFilenames,
        )
    }

    /// Copy the current settings onto a newly admitted job: the transcript
    /// output options and, unless the job brought its own, the default protocol
    /// template. Recovery uses the same admission rule as regular enqueueing so
    /// a later settings change cannot change output handling for an already
    /// recovered recording.
    func stampTranscriptOutputOptions(on job: inout PipelineJob) {
        let outputOptions = transcriptOutputOptionsProvider()
        if job.includeFullTranscriptInProtocol == nil {
            job.includeFullTranscriptInProtocol = outputOptions.includeFullTranscriptInProtocol
        }
        if job.saveRawTranscriptSeparately == nil {
            job.saveRawTranscriptSeparately = outputOptions.saveRawTranscriptSeparately
        }
        if job.protocolTemplate == nil {
            job.protocolTemplate = defaultProtocolTemplateProvider()
        }
        if job.useAITitleForFilenames == nil {
            job.useAITitleForFilenames = outputOptions.useAITitleForFilenames
        }
    }

    /// Test-only: insert a fully-formed job at any state, bypassing
    /// `enqueue()` and the processing trigger. Lets snapshot/observer tests
    /// exercise terminal states (`.done`, `.error`) without spinning real
    /// engines. Production code MUST go through `enqueue()`.
    func insertJobForTesting(_ job: PipelineJob) {
        jobs.append(job)
    }

    /// Wait for the queue to drain: any in-flight processing finishes and no
    /// jobs remain in `.waiting`. Used by tests that enqueue a job and need to
    /// observe a terminal state without racing against the spawned process task
    /// from `enqueue` → `triggerProcessing()`.
    func awaitProcessing() async {
        while isProcessing || !pendingJobs.isEmpty {
            // A run first: its job stays `.waiting` until the run's task gets
            // going, and an already finished `processTask` would return at once
            // and spin this loop on the main actor the run needs.
            if let run = pipelineRuns.values.first {
                _ = await run.value
                // Lets the entry that ran it take the run off the record.
                await Task.yield()
            } else if let task = processTask {
                await task.value
            } else {
                // processTask not yet assigned — yield so the spawning Task
                // can run.
                await Task.yield()
            }
        }
        await awaitNotionExports()
    }

    /// Every folder a job's sidecars may sit in, newest last. What a cleanup
    /// wants: it has to reach all of them, since a job can have written under
    /// more than one root.
    ///
    /// One place for a decision that was spelled out at each call site in three
    /// different ways. An empty record in the job means it predates the field or
    /// never wrote sidecars, and then the folder this queue writes to is what
    /// the code did before the field existed.
    func allSidecarDirs(of job: PipelineJob) -> [URL] {
        job.sidecarDirs(orCurrent: outputDir)
    }

    /// The same folders a read should try, newest first.
    ///
    /// Newest first because that is where the latest write put the file, and
    /// several rather than one because a recorded folder is not proof that the
    /// file arrived: saving naming data logs its failure and carries on, so the
    /// newest folder can be one the write never reached while an earlier one
    /// still holds a usable cache.
    ///
    /// The same folders, not more: adding this queue's own folder for a job
    /// that recorded some would let a `_naming.json` the user already resolved,
    /// left behind in the current folder by a build that recorded only one
    /// folder, make the resume read the job as still needing a full run.
    func sidecarDirsNewestFirst(of job: PipelineJob) -> [URL] {
        allSidecarDirs(of: job).reversed()
    }

    ///
    /// - Parameter keepingFiles: for a job whose files have already gone one by
    ///   one through `MeetingFileRemover`'s checks. The cleanup below goes by name,
    ///   and would take whatever sits at those paths now, folders included.
    func removeJob(id: UUID, keepingFiles: Bool = false) {
        // An export-only retry still needs its job to retain a created page's
        // ID if the remote request completes after the menu closes.
        guard !jobs.contains(where: { $0.id == id && $0.state == .done && $0.notionExportStatus == .inProgress }) else { return }
        completedJobRemovalTokens.removeValue(forKey: id)
        // Read before the job leaves the list: only a job still in work can
        // own a local generation to end (see `cancelWork`).
        let wasInWork = jobs.contains { $0.id == id && $0.state != .done && $0.state != .error }
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            processedLedger.markProcessed(mixPath: jobs[index].mixPath)
            // Unconditional, because removing a job has to remove what belongs
            // to it. A job dismissed while still awaiting speaker naming used to
            // strand its sidecars for good: only cancelling cleaned them up, and
            // Cancel is not offered in that state. Nothing sweeps the output
            // folder for them and the job is gone from the snapshot that would
            // have named them. Resolved jobs have nothing left here, so this
            // costs them a no-op.
            // The folder is passed explicitly although `nil` would now resolve
            // to the same one: the discard path next door has to pass it (its
            // jobs are not in the list any more), and spelling it out at every
            // queue-side call keeps the three readable side by side.
            if keepingFiles {
                naming.forgetNamingData(jobID: id)
            } else {
                naming.removeNamingData(
                    jobID: id, slug: jobs[index].namingSlug, in: allSidecarDirs(of: jobs[index]),
                )
            }
            noteLeftQueue(jobID: id)
            jobs.remove(at: index)
        }
        cancelWork(of: id, endingLocalGeneration: wasInWork)
        forgetStageBookkeeping(for: id)
        // A restored job marked for a protocol-only resume keeps no claim on
        // that once it is gone.
        protocolResumeDispositions.removeValue(forKey: id)
        protocolGenerationOn.removeValue(forKey: id)
        saveSnapshot()
    }

    /// Stop what is still running for a job that is being dropped: its
    /// pipeline run, when this queue is running one for it, and its late naming
    /// work. Only the job's own work: a job in a working state may be in a late
    /// re-run or late confirm, on the naming session's tasks, while the queue
    /// runs a different job, and stopping the queue's run then stopped that
    /// other job half-way and left this one going. The late work is cancelled
    /// whatever the state, because accepting auto-names starts it while the job
    /// is still `.speakerNamingPending`.
    ///
    /// A local model generation of the job is ended too, through its gate
    /// (`cancelLocalModelGeneration`): the helper is a process of its own,
    /// which no task cancel reaches. Only for a job that was still in work
    /// (`endingLocalGeneration`), because the gate refuses every later attempt
    /// of a cancelled job, and regenerating a finished meeting's protocol runs
    /// under that job's ID long after the job left the list.
    private func cancelWork(of id: UUID, endingLocalGeneration: Bool) {
        pipelineRuns[id]?.cancel()
        naming.cancelLateWork(jobID: id)
        if endingLocalGeneration { cancelLocalModelGeneration(jobID: id) }
    }

    /// Checked again when the lifetime runs out: an export started or failed
    /// since keeps the job. Nothing holds the job while the menu is open: the
    /// menu lists no finished job whose export completed, whether or not the
    /// queue still holds it, so removing one cannot move a row under the
    /// pointer.
    private func expireCompletedJob(id: UUID) {
        guard jobs.contains(where: { $0.id == id && $0.state == .done && !$0.hasPendingNotionExport }) else { return }
        removeJob(id: id)
    }

    /// Cancel a job. Removes the job + cleans up sidecar files if naming was
    /// pending. Done/error jobs are not affected.
    ///
    /// The recording is marked processed, so the cancel holds. Without that,
    /// orphan recovery offers it again, and not only on the next launch:
    /// switching watching on rebuilds the queue and rebuilding scans for
    /// orphans, so the job the user just stopped came back within the session,
    /// relabelled as a recovered recording. Cancelling that copy only re-armed
    /// the loop. Re-importing the file by hand stays the way back and never
    /// consults the ledger.
    ///
    /// Everything else is what dismissing a job does, so it goes through
    /// `removeJob`: its naming data and sidecars go, its stage bookkeeping is
    /// forgotten, and its own work is stopped (`cancelWork`), whatever state
    /// it is in.
    ///
    /// The one thing of the job that is kept is its recording, moved out of
    /// staging into the output folder (`relocateRecordingOfCancelledJob`).
    /// The ledger mark above does not wait for that move: orphan recovery
    /// enqueues and processes an unmarked recording, so one still in staging
    /// while the move runs, or after it failed, has to be marked already.
    func cancelJob(id: UUID) {
        guard let job = job(withID: id), job.state != .done, job.state != .error else { return }
        relocateRecordingOfCancelledJob(job)
        removeJob(id: id)
    }

    func updateJobState(id: UUID, to newState: JobState, error: String? = nil) {
        applyJobState(id: id, to: newState, error: error, diarizerMode: nil)
    }

    /// Enter `.diarizing` for a run that diarizes in `mode`. The mode picks the
    /// history the stage's expected finish is read from. It is passed in, not
    /// read from the job, because the job's mode describes the naming data an
    /// earlier run left, which a late re-diarization in another mode is about
    /// to replace, and which a first run has not written yet.
    /// Internal (not private) because the diarize stage in
    /// PipelineQueue+Stages.swift calls it, and it is the
    /// `SpeakerNamingSessionDelegate` witness the late re-run calls.
    func startDiarizing(jobID: UUID, mode: DiarizerMode) {
        applyJobState(id: jobID, to: .diarizing, error: nil, diarizerMode: mode)
    }

    private func applyJobState(id: UUID, to newState: JobState, error: String?, diarizerMode: DiarizerMode?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let oldState = jobs[index].state
        // Skip a true no-op: same state AND no error to record. Without this,
        // re-entering the same state (e.g. the confirm path enters
        // `.generatingProtocol` twice) fires a redundant log line, snapshot
        // write, and `onJobStateChange` callback, and would latently schedule a
        // second `removeJob` cleanup Task on a re-`.done`. An error-only update
        // (same state, new message) must still apply and persist.
        guard oldState != newState || error != nil else { return }
        jobs[index].state = newState
        if let error { jobs[index].error = error }
        // The stale-naming day counts from the first entry, see
        // `namingDeadlineStart`. Returning from a late re-diarization is the
        // same wait, not a new one.
        if newState == .speakerNamingPending, jobs[index].namingStartedAt == nil {
            jobs[index].namingStartedAt = Date()
        }
        if newState == .done {
            removeRawTranscriptArtifactsIfSafe(for: index)
        } else if newState == .error,
                  !transcriptOutputOptions(forJobID: id).saveRawTranscriptSeparately,
                  jobs[index].transcriptPath != nil {
            let warning = "Raw transcript retained because the job did not complete"
            if !jobs[index].warnings.contains(warning) {
                jobs[index].warnings.append(warning)
            }
        }
        // Before the state-change callback, so whatever it starts reads the
        // finished meeting's outcome.
        noteOutcome(jobID: id, of: newState)
        recordStageTransition(from: oldState, to: newState, jobID: id, diarizerMode: diarizerMode)
        eventLog.append(jobID: id, event: "state_change", from: oldState, to: newState)
        saveSnapshot()
        onJobStateChange?(jobs[index], oldState, newState)

        if newState == .done || newState == .error {
            processedLedger.markProcessed(mixPath: jobs[index].mixPath)
            recordTerminalJob(jobs[index])
        }
        if newState == .done {
            startPendingNotionExport(jobID: id)
            scheduleCompletedJobRemoval(id: id)
            // A held export retries from its Markdown, never from the audio
            // sidecars, and it may be held for as long as the user leaves it.
            if jobs[index].hasPendingNotionExport {
                naming.removeNamingData(jobID: id, slug: jobs[index].namingSlug, in: allSidecarDirs(of: jobs[index]))
            }
        }
    }

    func scheduleCompletedJobRemoval(id: UUID) {
        guard jobs.contains(where: { $0.id == id && $0.state == .done && !$0.hasPendingNotionExport }) else { return }
        let token = UUID()
        completedJobRemovalTokens[id] = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.completedJobLifetime ?? 60))
            guard self?.completedJobRemovalTokens[id] == token else { return }
            self?.expireCompletedJob(id: id)
        }
    }

    /// Persist a durable terminal-state record so the automation API can read
    /// back a finished job's outcome even after `completedJobLifetime` removes
    /// it from the in-memory list. No-op when no store is wired.
    func recordTerminalJob(_ job: PipelineJob) {
        terminalJobStore?.record(TerminalJobRecord(job: job))
    }

    /// Deletes raw transcript artifacts only after a successfully completed job
    /// has saved a protocol. A failed or disabled protocol generator leaves the
    /// transcript intact so users can recover the meeting content instead of
    /// losing it with no generated minutes to show for it.
    private func removeRawTranscriptArtifactsIfSafe(for index: Int) {
        guard !transcriptOutputOptions(forJobID: jobs[index].id).saveRawTranscriptSeparately else { return }
        guard jobs[index].hasSavedProtocol else {
            if jobs[index].transcriptPath != nil {
                // Matched by /v1 clients and persisted jobs; keep the text stable.
                let warning = "Raw transcript retained because no protocol was saved"
                if !jobs[index].warnings.contains(warning) {
                    jobs[index].warnings.append(warning)
                }
            }
            return
        }

        let transcriptPath = jobs[index].transcriptPath
        let slug = jobs[index].namingSlug
        if let transcriptPath {
            do {
                try FileManager.default.removeItem(at: transcriptPath)
                logger.info("Transcript removed according to output setting")
                jobs[index].transcriptPath = nil
            } catch CocoaError.fileNoSuchFile {
                // A failed or interrupted write may leave only the path; the
                // desired final state is still no raw transcript.
                jobs[index].transcriptPath = nil
            } catch {
                logger.warning(
                    "Failed to remove transcript according to output setting: \(error.localizedDescription, privacy: .public)",
                )
                jobs[index].warnings.append("Raw transcript could not be removed")
            }
        }
        do {
            try naming.removeTranscriptSegments(slug: slug)
        } catch {
            logger.warning(
                "Failed to remove transcript segments according to output setting: \(error.localizedDescription, privacy: .public)",
            )
            let warning = "Raw transcript segments could not be removed"
            if !jobs[index].warnings.contains(warning) {
                jobs[index].warnings.append(warning)
            }
        }
        meetingFileStore?.markGone(jobID: jobs[index].id, roles: [.transcript, .segments])
    }

    func addWarning(id: UUID, _ message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard !jobs[index].warnings.contains(message) else { return }
        jobs[index].warnings.append(message)
    }

    /// Record which tracks of this job's recording had audio. Read back through
    /// `job(withID:)` like every other per-job field.
    func setTrackViability(id: UUID, _ viability: DualTrackViability) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].trackViability = viability
    }

    /// Attach the echo detector's verdict to a job. Recorded even when it did
    /// not fire, so a later "why does my transcript have duplicates" can tell a
    /// missed detection from one that never ran.
    /// Internal (not private) because `PipelineQueue+EchoBleed.swift` calls it.
    /// Record where stage 3 left a job's audio, and persist it.
    ///
    /// The snapshot write is the point. Leaving it to the next state transition
    /// works only where there is one: `generateProtocol` returns before its
    /// `.generatingProtocol` transition when no protocol generator is
    /// configured, so a quit right after the relocation would leave a snapshot
    /// still naming the emptied staging path and the restore would discard the
    /// job exactly as it did before this fix.
    func recordRelocatedAudio(jobID: UUID, _ paths: RelocatedAudioPaths) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].recordRelocatedAudio(paths)
        saveSnapshot()
        noteWritten(jobID: jobID, [(.mix, paths.mix), (.appTrack, paths.app), (.micTrack, paths.mic)])
    }

    func recordEchoVerdict(jobID: UUID, _ verdict: EchoDetectionDTO) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].echo = verdict
    }

    /// Record the recording's length from its frame count at 16 kHz, as stage
    /// 1 measured it. Zero frames (an empty recording, or audio that could not
    /// be read) are not recorded, so nil keeps meaning "not measured". No
    /// snapshot write of its own: the stage transition after stage 1 persists
    /// it, the terminal one included.
    ///
    /// A fresh job learns its length only here, inside the transcription
    /// stage, so this is where that stage's expected finish can first be
    /// computed.
    /// Internal (not private) because `PipelineQueue+Stages.swift` calls it.
    func recordAudioDuration(jobID: UUID, frames: Int) {
        guard frames > 0, let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].audioDuration = TimeInterval(frames) / TimeInterval(AudioConstants.targetSampleRate)
        estimateStageFinish(jobID: jobID)
    }

    /// Record how many microphone segments the merge left out of the transcript.
    /// Written after the verdict rather than with it: the count only exists once
    /// the segments are known, which is two stages later.
    /// The optional chain doubles as the guard: segments are only ever
    /// suppressed on an `.affected` verdict, so a nil `echo` means this count
    /// belongs to no measurement, and dropping it is more honest than
    /// inventing a verdict record to hang it on.
    /// Internal (not private) because `PipelineQueue+Stages.swift` calls it.
    func recordSuppressedSegments(jobID: UUID, _ count: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].echo?.suppressedSegments = count
    }

    /// Record whether the far end was taken out of the microphone audio.
    /// Written only once the stage has decided, so a job that never reached it
    /// keeps the field absent — and absent means nobody tried, which is not
    /// what false means.
    /// Guarded by the same optional chain as the suppressed count, for the same
    /// reason: cancellation only ever runs on an `.affected` verdict, so a nil
    /// `echo` means this answer belongs to no measurement.
    /// Internal (not private) because `PipelineQueue+EchoCancellation.swift`
    /// calls it.
    func recordEchoRemoved(jobID: UUID, _ removed: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].echo?.removed = removed
    }

    // MARK: - Stage timing metrics

    /// On every state change: if we left a timed stage, log its wall-clock
    /// duration; if we entered one, stamp its start and start its menu clock.
    /// Measuring per-state means the recorded duration covers exactly the
    /// stage the menu line names and excludes the speaker-naming pause (see
    /// `StageKind(jobState:)`). A sub-stage logged as an event of its own (the
    /// echo canceller's run inside `.transcribing`) is taken back out of the
    /// enclosing stage's event, so that stage's speed stays the cost of the
    /// stage for the jobs that never run it. The menu clock keeps the run,
    /// since the state is still `.transcribing` while it runs, so on an
    /// echo-cancelled job the stage ends later than the expected finish the
    /// menu line shows: the stage is taking longer, and moving the expected
    /// finish mid-stage would change a line the menu may only change at a job
    /// event.
    private func recordStageTransition(
        from oldState: JobState, to newState: JobState, jobID: UUID, diarizerMode: DiarizerMode?,
    ) {
        // A same-state "transition" (e.g. the confirm path re-enters
        // .generatingProtocol while already .generatingProtocol) is not a stage
        // boundary; ignore it so it neither logs a partial event nor resets the start.
        guard oldState != newState else { return }
        stageClocks.removeValue(forKey: jobID)
        let excluded = excludedSubStageSecondsByJob.removeValue(forKey: jobID) ?? 0
        if let leaving = StageKind(jobState: oldState), let start = stageStartByJob.removeValue(forKey: jobID) {
            // audioSeconds is 0 for stages with no known audio length (e.g. a
            // late re-diarization with no transcription this session);
            // aggregate() then excludes it from the RTF but still counts its
            // wall-clock.
            logStageTiming(
                stage: leaving, wallClock: max(0, (ContinuousClock.now - start).inSeconds - excluded),
                jobID: jobID, audioSeconds: jobAudioSeconds[jobID] ?? 0,
            )
        }
        if let entering = StageKind(jobState: newState) {
            stageStartByJob[jobID] = ContinuousClock.now
            startStageClock(entering, jobID: jobID, diarizerMode: diarizerMode)
        }
    }

    /// The running stage of a job as its menu line reads it, nil while the
    /// job is in no timed stage.
    func stageClock(forJobID jobID: UUID) -> StageClock? {
        stageClocks[jobID]
    }

    /// Start the menu clock for a stage just entered, keyed the way
    /// `logStageTiming` stamps that stage's events: transcription by engine
    /// alone, diarization by the mode this run diarizes with, protocol
    /// generation by the mode the job's diarization ran in.
    private func startStageClock(_ stage: StageKind, jobID: UUID, diarizerMode: DiarizerMode?) {
        let mode: DiarizerMode? = switch stage {
        case .echoCancelling, .transcribing: nil
        case .diarizing: diarizerMode
        case .generatingProtocol: usedDiarizerMode(forJobID: jobID)
        }
        stageClocks[jobID] = StageClock(
            config: StageConfig(stage: stage, engine: activeEngineTag, diarizerMode: mode?.rawValue),
            startedAt: Date(),
        )
        estimateStageFinish(jobID: jobID)
    }

    /// Fill in a running stage's expected finish the first time its audio
    /// length and its history's speed are both there, and never change one
    /// already filled in: the line it feeds may change only at a job event.
    /// The history leaves out the echo-cancellation seconds a stage ran
    /// (`excludedSubStageSecondsByJob`), so a run already spent here is added
    /// back to the start; one still to come shifts the finish when it ends
    /// (`recordEchoCancellationTiming`).
    private func estimateStageFinish(jobID: UUID) {
        guard var clock = stageClocks[jobID], clock.expectedFinish == nil,
              let finish = StageTimingStats.expectedFinish(
                  start: clock.startedAt.addingTimeInterval(excludedSubStageSecondsByJob[jobID] ?? 0),
                  audioSeconds: job(withID: jobID)?.audioDuration,
                  secondsPerAudioSecond: stageSpeedByConfig[clock.config],
              )
        else { return }
        clock.expectedFinish = finish
        stageClocks[jobID] = clock
    }

    /// Drop every per-job timing entry. One place, because the two exits that
    /// bypass the terminal transition (`removeJob`, `cancelJob`) each have to
    /// reap all of them, and a dictionary added to one and not the other is
    /// how a job cancelled mid-stage came to leak its entries once before.
    private func forgetStageBookkeeping(for id: UUID) {
        stageStartByJob.removeValue(forKey: id)
        stageClocks.removeValue(forKey: id)
        excludedSubStageSecondsByJob.removeValue(forKey: id)
        jobAudioSeconds.removeValue(forKey: id)
    }

    /// Record one echo-cancellation run on `micURL`: logged as its own stage
    /// event, remembered so leaving `.transcribing` can take it back out of
    /// that stage's event, and written to the job as `echo.cancellationSeconds`.
    /// One clock reading for all three, so the per-job record a driver reads
    /// over the API and the average Settings shows never disagree about what
    /// a run cost. The clock is read before anything else so the file's
    /// header read below is not inside the measured span.
    ///
    /// Called only for a run that processed the track, whatever the
    /// self-check then made of it; which runs that includes and why is on
    /// `EchoDetectionDTO.cancellationSeconds`. Dropped for a job that is no
    /// longer in the list, the same guard `recordEchoRemoved` applies, so a
    /// run finishing after its job was cancelled leaves no entry behind.
    /// Internal (not private) because `PipelineQueue+EchoCancellation.swift`
    /// calls it.
    func recordEchoCancellationTiming(jobID: UUID, startedAt: ContinuousClock.Instant, micURL: URL) {
        let wallClock = (ContinuousClock.now - startedAt).inSeconds
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        // Excluded from the enclosing stage only if there is one and the run
        // started inside it; a run outside any timed stage has nothing to be
        // taken out of, and charging it to whatever stage comes next would
        // shorten an unrelated event.
        if let stageStart = stageStartByJob[jobID], startedAt >= stageStart {
            excludedSubStageSecondsByJob[jobID, default: 0] += wallClock
            // The stage's expected finish was read from a history without
            // these seconds; the run ending is the job event that moves it.
            if let finish = stageClocks[jobID]?.expectedFinish {
                stageClocks[jobID]?.expectedFinish = finish.addingTimeInterval(wallClock)
            }
        }
        // Same optional chain as `recordEchoRemoved`, for the same reason: a
        // nil `echo` means this number belongs to no measurement.
        jobs[index].echo?.cancellationSeconds = wallClock
        // Normalised by the track the run processed, not by `jobAudioSeconds`:
        // transcription stamps that later, after this run.
        logStageTiming(
            stage: .echoCancelling, wallClock: wallClock, jobID: jobID,
            audioSeconds: Double(AudioMixer.frameCount(of: micURL)) / Double(AudioConstants.targetSampleRate),
        )
    }

    /// Append one stage-timing event, then refresh the cached speeds from the
    /// log so the next stage reads the new data point. Append and reload run in
    /// one Task so the reload is ordered strictly after the append (no race
    /// that could miss the just-logged event). `audioSeconds` is evaluated only
    /// when there is a log to write to, since one caller reads a file for it.
    private func logStageTiming(
        stage: StageKind, wallClock: Double, jobID: UUID, audioSeconds: @autoclosure () -> Double,
    ) {
        guard let stageTimingLog else { return }
        let event = StageTimingEvent(
            ts: Date(), jobID: jobID, stage: stage,
            wallClockSeconds: wallClock, audioSeconds: audioSeconds(),
            engine: stage.isEngineScoped ? activeEngineTag : nil,
            diarizerMode: stage.isEngineScoped ? usedDiarizerMode(forJobID: jobID)?.rawValue : nil,
        )
        Task { [weak self] in
            await stageTimingLog.append([event])
            await self?.reloadStageSpeeds()
        }
    }

    /// Concrete transcription-engine type name, the comparability tag stamped on
    /// logged events; also used to resolve a running stage's config.
    private var activeEngineTag: String? {
        engine.map { String(describing: type(of: $0)) }
    }

    /// Reload recent timings and recompute the per-config speeds. A clock that
    /// already has its expected finish keeps it. Internal (not private) so a
    /// test can reload the history the way the end of a stage does.
    func reloadStageSpeeds() async {
        guard let stageTimingLog else { return }
        let events = await stageTimingLog.loadRecent(within: Self.stageHistoryWindow)
        stageSpeedByConfig = StageTimingStats.speedByConfig(events: events)
    }

    // MARK: - Processing

    /// Kick off processing if not already running and there are waiting jobs.
    /// Internal (not private) because sibling-file extension methods re-trigger
    /// the queue: `processNext` (PipelineQueue+Stages.swift) after finishing a
    /// job, and `loadSnapshot` / `recoverOrphanedRecordings`
    /// (PipelineQueue+Recovery.swift) after restoring or recovering jobs.
    func triggerProcessing() {
        guard !isProcessing else { return }
        guard pendingJobs.first != nil else { return }
        isProcessing = true
        processTask = Task { [weak self] in
            await self?.processNext()
        }
    }

    // MARK: - Speaker Naming forwarders

    /// Auto-resolve pending naming items older than maxAge (default: 24h).
    /// Thin forwarder passing the queue's already-filtered
    /// `.speakerNamingPending` list to the session, which generates the protocol
    /// with auto-names, transitions them to .done, and deletes sidecar files.
    func cleanupStalePending(maxAge: TimeInterval = 86400) {
        naming.cleanupStalePending(pendingJobs: pendingSpeakerNamingJobs, maxAge: maxAge)
    }

    // MARK: - Log Directory

    private var logDirCreated = false

    private func ensureLogDir() {
        guard !logDirCreated else { return }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logDirCreated = true
    }

    /// Persist the current `jobs` array to disk. The write runs off the main
    /// actor through the one `PipelineSnapshotStore` for this `logDir`, which
    /// every queue writing there shares, so a stalled `replaceItemAt` cannot
    /// freeze the UI / RPC / watch loop, rapid successive calls coalesce into
    /// a write of the last state, and the order on disk follows the order of
    /// the saves even across a queue replacement.
    func saveSnapshot() {
        guard !isRetired else {
            logger.info("Snapshot save skipped: this queue was replaced")
            return
        }
        ensureLogDir()
        PipelineSnapshotStore.save(jobs, to: logDir, using: snapshotWriter)
    }

    /// Set by `PipelineController.rebuild()` on the queue it replaced. Its
    /// list stopped being the app's at the swap, so a save from it would put
    /// that list back over the active queue's: the store orders writes by
    /// when they were saved, not by which queue is current. Work that
    /// outlives the swap still runs on it (the staging recovery it started
    /// when it was built holds it until its scan returns); it just no longer
    /// writes the snapshot or takes on recovered recordings.
    private(set) var isRetired = false

    func retire() {
        isRetired = true
    }

    /// Wait until every snapshot write into this queue's `logDir` has landed,
    /// whichever queue saved it, including writes saved while this waited.
    /// The quit path waits through it (`PipelineController.awaitSnapshotFlushes`),
    /// and tests asserting on the file use it too.
    func awaitSnapshotFlush() async {
        await PipelineSnapshotStore.flush(logDir)
    }

    /// True while a snapshot write into this queue's `logDir` has not landed
    /// yet, whichever queue saved it. The quit path reads it to decide whether
    /// there is anything to wait for; tests read it to assert the writer
    /// drains and clears itself.
    var isSnapshotWorkerActive: Bool {
        PipelineSnapshotStore.existing(for: logDir) != nil
    }
}

// MARK: - Meeting file record

/// The hooks that keep a meeting's `MeetingFileRecord` in step with its files.
/// All on the main actor, like every other change to a job. A failed record
/// write is logged by the store and goes no further: no hook can fail a job.
extension PipelineQueue {
    /// The one way a write of a listed file reaches the record: its path and,
    /// read now, its identity. An atomic write replaces the file and with it its
    /// inode, so a writer that skips this leaves the record naming a file that
    /// is gone, and a later deletion refuses the app's own file as replaced.
    func noteWritten(jobID: UUID, role: MeetingFile.Role, path: URL) {
        noteWritten(jobID: jobID, [(role, path)])
    }

    /// Several files in one record write. A nil path is a slot the job does not
    /// have, which lists nothing.
    func noteWritten(jobID: UUID, _ written: [(role: MeetingFile.Role, path: URL?)]) {
        // Read from memory, so a job without a record costs no lock, and outside
        // `update`, so the file system calls below do not run under the lock.
        guard let meetingFileStore, let origin = meetingFileStore.record(for: jobID)?.origin else { return }
        let files = written.compactMap { role, path in
            path.map { MeetingFile(role: role, url: $0, owned: origin.owns(role)) }
        }
        meetingFileStore.list(files, jobID: jobID)
    }

    /// Files moved on disk by the title rename. Each `source` was resolved before
    /// its move, and the destination is resolved here, after it, while it exists;
    /// see `MeetingFile.resolvedPath`.
    func noteMoved(jobID: UUID, _ moved: [(source: String, destination: URL)]) {
        guard !moved.isEmpty else { return }
        let resolved = moved.map { (source: $0.source, destination: MeetingFile.resolvedPath($0.destination)) }
        meetingFileStore?.update(jobID: jobID) { record in
            for move in resolved {
                record.followMove(from: move.source, to: move.destination)
            }
        }
    }

    /// What the speaker naming session did to a meeting's files.
    private func noteNamingFiles(jobID: UUID, _ change: SpeakerNamingSession.FileChange) {
        switch change {
        case let .namingSaved(path):
            noteWritten(jobID: jobID, role: .naming, path: path)

        case let .transcriptRewritten(path):
            noteWritten(jobID: jobID, role: .transcript, path: path)

        case .sidecarsRemoved:
            meetingFileStore?.markGone(jobID: jobID, roles: [.naming, .mix16k, .app16k, .mic16k, .segments])
        }
    }

    /// The job left the queue. A job that had reached an outcome keeps it: the
    /// queue's own removal of a finished one says nothing about how it ended.
    func noteLeftQueue(jobID: UUID) {
        meetingFileStore?.update(jobID: jobID) { record in
            if record.outcome == .inProgress { record.outcome = .leftUnfinished }
        }
    }

    /// The outcome a state stands for: a terminal one, or `.waiting`, which only
    /// a Retry enters as a change, so the meeting is judged by the new run. The
    /// states in between change nothing here: a job only gets there with its
    /// outcome still in progress.
    ///
    /// Whether generation was on is what the protocol stage found when it ran.
    /// A naming skipped with no generator or lost at a restore reaches `.done`
    /// without that stage, so it asks now, the moment it passed the stage by.
    private func noteOutcome(jobID: UUID, of state: JobState) {
        guard let meetingFileStore else { return }
        switch state {
        case .done:
            let generationOn = protocolGenerationOn.removeValue(forKey: jobID) ?? (protocolGeneratorFactory?() != nil)
            meetingFileStore.update(jobID: jobID) { $0.outcome = .finished(protocolExpected: generationOn) }

        case .error:
            protocolGenerationOn.removeValue(forKey: jobID)
            meetingFileStore.update(jobID: jobID) { $0.outcome = .failed }

        case .waiting:
            meetingFileStore.update(jobID: jobID) { $0.outcome = .inProgress }

        default:
            break
        }
    }
}

// MARK: - SpeakerNamingSessionDelegate

extension PipelineQueue: SpeakerNamingSessionDelegate {
    /// A value copy of the tracked job, addressed by id (never by a stale index).
    func job(withID id: UUID) -> PipelineJob? {
        jobs.first { $0.id == id }
    }

    /// Persist the per-job naming metadata on the (queue-owned) job. `nil` for
    /// either field means "leave unchanged". Mutates `jobs` in place (no
    /// snapshot write — matches the previous inline mutations).
    func setNamingMetadata(
        jobID: UUID, slug: String?, usedDiarizerMode: DiarizerMode?, wroteSidecarsIn: URL?,
    ) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if let slug { jobs[idx].namingSlug = slug }
        if let usedDiarizerMode { jobs[idx].usedDiarizerMode = usedDiarizerMode }
        // Only the folder the caller says it wrote to. Stage 3 records its own,
        // but a run that fails before it would leave the naming data where
        // nothing that reads the job finds it once the setting moves. Recording
        // a folder the write never reached is worse than not recording it: the
        // read trusts this order to find the newest payload, so a folder that
        // holds nothing would take the front of the queue. Records rather than
        // overwrites; see `previousSidecarOutputDirs`.
        if let wroteSidecarsIn { jobs[idx].recordSidecarOutputDir(wroteSidecarsIn) }
    }
}

private extension Duration {
    /// Whole and fractional seconds as one `Double`.
    var inSeconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
