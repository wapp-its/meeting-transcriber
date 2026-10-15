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

    /// Process-wide claim on the runs currently executing, so a replacement
    /// queue cannot start a job the queue it replaced is still working on.
    /// Defaults to the shared instance; tests inject their own to stay isolated
    /// from each other.
    let inFlightRuns: InFlightRunRegistry

    /// Durable store of finished-job records for the automation API readback.
    /// nil (default) disables it; production injects one, tests opt in.
    let terminalJobStore: TerminalJobStore?

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
    /// nothing.
    @ObservationIgnored private var stageSpeedByConfig: [StageConfig: Double] = [:]

    /// How far back the speeds look.
    private static let stageHistoryWindow: TimeInterval = 30 * 86400

    /// When the current `.transcribing`/`.diarizing`/`.generatingProtocol` state
    /// was entered, per job — so `updateJobState` can record the state's duration
    /// on exit (keyed by job to stay correct if transitions ever interleave).
    private var stageStartByJob: [UUID: ContinuousClock.Instant] = [:]
    /// Audio length (seconds) each job processed, captured when transcription
    /// completes, so stage durations can be normalised into an RTF.
    /// Internal (not private) because `transcribe` in PipelineQueue+Stages.swift stamps it.
    var jobAudioSeconds: [UUID: Double] = [:]

    private var processTask: Task<Void, Never>?
    /// The job `processNext` runs now, so a cancel cancels `processTask` only
    /// for that job: a speaker-naming path writes its protocol in a task of its
    /// own, and cancelling the queue's task for such a job would end the run
    /// of whichever job the queue is processing.
    /// Internal (not private) because `processNext` in PipelineQueue+Stages.swift
    /// sets it.
    @ObservationIgnored var processingJobID: UUID?
    #if !APPSTORE
        /// The gate of the local generators this queue ran, so a cancel reaches
        /// a helper started from any path. Taken from the generator rather than
        /// handed in: it is the gate the job's generation went through, also
        /// after the provider was switched mid-run. Internal (not private)
        /// because PipelineQueue+LocalModel.swift sets it.
        @ObservationIgnored var localModelGate: LocalModelGate?
    #endif
    /// Internal (not private) because `processNext` in PipelineQueue+Stages.swift
    /// reads this to distinguish a cancellation from a real pipeline error.
    var cancelledJobIDs = Set<UUID>()

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

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

    /// The currently displayed naming data (first pending item).
    var pendingSpeakerNaming: SpeakerNamingData? {
        guard let firstPendingJob = pendingSpeakerNamingJobs.first else { return nil }
        return speakerNamingDataByJob[firstPendingJob.id]
    }

    /// Filesystem slug for a job's persisted artefacts. Thin alias for
    /// `SpeakerNamingStore.slug` — kept so existing call sites (`processNext`,
    /// tests) don't have to reach into the store for a pure helper.
    static func namingSlug(title: String, jobID: UUID, startTime: Date) -> String {
        SpeakerNamingStore.slug(title: title, jobID: jobID, startTime: startTime)
    }

    /// Returns naming data for a specific job ID, or the first pending job as fallback.
    func speakerNamingData(forJobID jobID: UUID?) -> SpeakerNamingData? {
        if let jobID, let data = speakerNamingDataByJob[jobID] { return data }
        return pendingSpeakerNaming
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
    func completeSpeakerNaming(
        jobID: UUID, result: SpeakerNamingResult, source: RecognitionSource = .dialog,
    ) {
        naming.completeSpeakerNaming(jobID: jobID, result: result, source: source)
    }

    /// Called by the UI when the user confirms or skips speaker naming without a
    /// specific job in hand — resolves the first pending job (or any stashed
    /// naming data) and forwards to the session.
    func completeSpeakerNaming(result: SpeakerNamingResult, source: RecognitionSource = .dialog) {
        if let jobID = pendingSpeakerNamingJobs.first?.id ?? naming.speakerNamingDataByJob.keys.first {
            naming.completeSpeakerNaming(jobID: jobID, result: result, source: source)
        }
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
    init(
        logDir: URL? = nil,
        stagingDir: URL = AppPaths.recordingsDir,
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = PipelineQueue.throwawayMatcherFactory(),
        snapshotWriter: @escaping @Sendable ([PipelineJob], URL) throws -> Void = PipelineSnapshot.save,
        stageTimingLog: StageTimingLog? = nil,
        completedJobLifetime: TimeInterval = 60,
        terminalJobStore: TerminalJobStore? = nil,
        inFlightRuns: InFlightRunRegistry? = nil,
        echoCancellationEnabled: @escaping () -> Bool = { false },
        echoCancellerFactory: (() -> (any EchoCancelling)?)? = nil,
        defaultProtocolTemplateProvider: @escaping () -> ProtocolTemplateID = { .builtIn },
        protocolTemplateStore: ProtocolTemplateStore = .production,
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
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
        self.terminalJobStore = terminalJobStore
        self.inFlightRuns = inFlightRuns ?? .shared
        naming = SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: speakerMatcherFactory,
        )
        naming.delegate = self
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
        speakingTimes: [String: TimeInterval] = [:],
    ) {
        matcher.updateDB(
            mapping: mapping,
            embeddings: embeddings,
            speakingTimes: speakingTimes,
        )
        refreshKnownSpeakerNames()
    }

    /// Full init with all processing dependencies.
    init(
        engine: any TranscribingEngine,
        diarizationFactory: @escaping () -> any DiarizationProvider,
        diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)? = nil,
        protocolGeneratorFactory: @escaping () -> (any ProtocolGenerating)?,
        outputDir: URL,
        logDir: URL? = nil,
        stagingDir: URL = AppPaths.recordingsDir,
        diarizeEnabled: Bool = false,
        echoDedupEnabled: Bool = true,
        echoCancellationEnabled: @escaping () -> Bool = { false },
        echoCancellerFactory: (() -> (any EchoCancelling)?)? = nil,
        numSpeakers: Int = 0,
        micLabel: String = "Me",
        includeFullTranscriptInProtocol: Bool = true,
        saveRawTranscriptSeparately: Bool = true,
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
        terminalJobStore: TerminalJobStore? = nil,
        inFlightRuns: InFlightRunRegistry? = nil,
        securityScope: SecurityScopeAccess = .live,
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
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
        self.terminalJobStore = terminalJobStore
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

    func enqueue(_ inputJob: PipelineJob) {
        var job = inputJob
        stampTranscriptOutputOptions(on: &job)
        jobs.append(job)
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
            if let task = processTask {
                await task.value
            } else {
                // processTask not yet assigned — yield so the spawning Task
                // can run.
                await Task.yield()
            }
        }
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

    func removeJob(id: UUID) {
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
            naming.removeNamingData(
                jobID: id, slug: jobs[index].namingSlug, in: allSidecarDirs(of: jobs[index]),
            )
            jobs.remove(at: index)
        }
        stageStartByJob.removeValue(forKey: id)
        stageClocks.removeValue(forKey: id)
        jobAudioSeconds.removeValue(forKey: id)
        saveSnapshot()
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
    func cancelJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let state = jobs[index].state
        let slug = jobs[index].namingSlug
        // cancelJob removes the job directly (not via removeJob) and skips the
        // normal terminal transition, so reap the stage-timing bookkeeping here
        // too — otherwise a job cancelled mid-stage leaks these entries.
        stageStartByJob.removeValue(forKey: id)
        stageClocks.removeValue(forKey: id)
        jobAudioSeconds.removeValue(forKey: id)
        if state != .done, state != .error {
            processedLedger.markProcessed(mixPath: jobs[index].mixPath)
        }
        switch state {
        case .waiting:
            jobs.remove(at: index)
            saveSnapshot()

        case .transcribing, .diarizing, .generatingProtocol:
            cancelledJobIDs.insert(id)
            if processingJobID == id { processTask?.cancel() }
            cancelLocalModelGeneration(jobID: id)
            naming.removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

        case .speakerNamingPending:
            // User cancelled while waiting for late-confirm — drop the sidecar
            // files and the in-memory state so it doesn't sit around.
            naming.removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

        case .done, .error:
            break
        }
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
        recordStageTransition(from: oldState, to: newState, jobID: id, diarizerMode: diarizerMode)
        eventLog.append(jobID: id, event: "state_change", from: oldState, to: newState)
        saveSnapshot()
        onJobStateChange?(jobs[index], oldState, newState)

        if newState == .done || newState == .error {
            processedLedger.markProcessed(mixPath: jobs[index].mixPath)
            recordTerminalJob(jobs[index])
        }
        if newState == .done {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.completedJobLifetime ?? 60))
                self?.removeJob(id: id)
            }
        }
    }

    /// Persist a durable terminal-state record so the automation API can read
    /// back a finished job's outcome even after `completedJobLifetime` removes
    /// it from the in-memory list. No-op when no store is wired.
    private func recordTerminalJob(_ job: PipelineJob) {
        terminalJobStore?.record(TerminalJobRecord(job: job))
    }

    /// Deletes raw transcript artifacts only after a successfully completed job
    /// has saved a protocol. A failed or disabled protocol generator leaves the
    /// transcript intact so users can recover the meeting content instead of
    /// losing it with no generated minutes to show for it.
    private func removeRawTranscriptArtifactsIfSafe(for index: Int) {
        guard !transcriptOutputOptions(forJobID: jobs[index].id).saveRawTranscriptSeparately else { return }
        guard jobs[index].protocolPath != nil else {
            if jobs[index].transcriptPath != nil {
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
    /// `StageKind(jobState:)`).
    private func recordStageTransition(
        from oldState: JobState, to newState: JobState, jobID: UUID, diarizerMode: DiarizerMode?,
    ) {
        // A same-state "transition" (e.g. the confirm path re-enters
        // .generatingProtocol while already .generatingProtocol) is not a stage
        // boundary; ignore it so it neither logs a partial event nor resets the start.
        guard oldState != newState else { return }
        stageClocks.removeValue(forKey: jobID)
        if let leaving = StageKind(jobState: oldState), let start = stageStartByJob.removeValue(forKey: jobID) {
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            logStageTiming(stage: leaving, wallClock: seconds, jobID: jobID)
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
        case .transcribing: nil
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
    private func estimateStageFinish(jobID: UUID) {
        guard var clock = stageClocks[jobID], clock.expectedFinish == nil,
              let finish = StageTimingStats.expectedFinish(
                  start: clock.startedAt,
                  audioSeconds: job(withID: jobID)?.audioDuration,
                  secondsPerAudioSecond: stageSpeedByConfig[clock.config],
              )
        else { return }
        clock.expectedFinish = finish
        stageClocks[jobID] = clock
    }

    /// Append one stage-timing event, then refresh the cached speeds from the
    /// log so the next stage reads the new data point. Append and reload run in
    /// one Task so the reload is ordered strictly after the append (no race
    /// that could miss the just-logged event).
    private func logStageTiming(stage: StageKind, wallClock: Double, jobID: UUID) {
        guard let stageTimingLog else { return }
        // audioSeconds is 0 for stages with no known audio length (e.g. a late
        // re-diarization with no transcription this session); aggregate() then
        // excludes it from the RTF but still counts its wall-clock.
        let event = StageTimingEvent(
            ts: Date(), jobID: jobID, stage: stage,
            wallClockSeconds: wallClock, audioSeconds: jobAudioSeconds[jobID] ?? 0,
            engine: activeEngineTag,
            diarizerMode: usedDiarizerMode(forJobID: jobID)?.rawValue,
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

    // Latest jobs array queued for the snapshot worker. Overwritten on
    // each `saveSnapshot()` so a burst of state changes collapses into a
    // single write of the final state instead of N sequential writes.
    // nil ≠ `[]`: nil means "nothing to write", `[]` would mean "write
    // the empty-jobs state" (valid when the last job was removed).
    // swiftlint:disable:next discouraged_optional_collection
    private var pendingSnapshotJobs: [PipelineJob]?
    private var snapshotWorker: Task<Void, Never>?

    /// Dedicated actor that owns the `replaceItemAt` syscall. Calling
    /// `await snapshotWriterActor.write(...)` from inside the detached task
    /// is a genuine cross-actor hop — guaranteed to leave the caller's
    /// executor (in particular MainActor) and run on the actor's own
    /// executor. This sidesteps Swift Concurrency's synchronous-start
    /// optimization that would otherwise keep `Task.detached`'s body on
    /// the caller's thread until the first real suspension. A stalled
    /// `renamex_np` (Spotlight indexer race on macOS 26) now blocks only
    /// this actor — never the UI, RPC, or watch loop.
    private let snapshotWriterActor = SnapshotWriterActor()

    /// Persist the current `jobs` array to disk. The write runs on a
    /// detached task and hops to `snapshotWriterActor` for the actual I/O —
    /// a stalled `replaceItemAt` (macOS 26 `mds_stores` rename deadlock)
    /// can't freeze the UI / RPC / watch loop. Rapid successive calls
    /// coalesce: only the last state is actually written.
    /// Drop a snapshot write this queue still owes, for a queue that is being
    /// replaced.
    ///
    /// Both queues share one `logDir`, so they share `pipeline_queue.tmp`, and
    /// their serializing actors are per-queue and know nothing of each other.
    /// Left in place, the replaced queue's pending write and the replacement's
    /// own race on that one staging file: the loser of `replaceItemAt` fails
    /// with a missing source, and the winner may be the queue that is going
    /// away. Dropping the batch is enough to end the worker, which stops as
    /// soon as `takeNextSnapshotBatch` hands it nothing.
    func discardPendingSnapshot() {
        pendingSnapshotJobs = nil
    }

    func saveSnapshot() {
        ensureLogDir()
        pendingSnapshotJobs = jobs
        guard snapshotWorker == nil else { return }
        let dir = logDir
        let writer = snapshotWriter
        let writeActor = snapshotWriterActor
        snapshotWorker = Task.detached(priority: .utility) { [weak self] in
            while let next = await self?.takeNextSnapshotBatch() {
                await writeActor.write(jobs: next, to: dir, using: writer)
            }
        }
    }

    // swiftlint:disable discouraged_optional_collection
    @MainActor
    private func takeNextSnapshotBatch() -> [PipelineJob]? {
        guard let next = pendingSnapshotJobs else {
            snapshotWorker = nil
            return nil
        }
        pendingSnapshotJobs = nil
        return next
    }

    // swiftlint:enable discouraged_optional_collection

    /// Wait for any queued snapshot writes to land on disk. Used by tests
    /// asserting on the file; production code may call this before quit if
    /// it needs the last snapshot durable, but the recovery path doesn't
    /// require it (orphans are re-scanned at next launch).
    func awaitSnapshotFlush() async {
        await snapshotWorker?.value
    }

    /// Test-only: true while a background snapshot worker is running.
    /// Lets tests assert the worker drains and clears itself.
    var isSnapshotWorkerActive: Bool {
        snapshotWorker != nil
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
