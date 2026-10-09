import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineController")

/// How `QueueEnvironment` is wired in production, with the staging-folder
/// recovery it hands each new queue. Split out of `PipelineController.swift` to
/// keep that file under the `file_length` limit, as `AppSettings+Computed` and
/// `AudioMixer+AssetFallback` are. Pure move; no behavioural difference from
/// declaring these inline.
extension PipelineController.QueueEnvironment {
    static var production: Self {
        Self(
            logDir: nil,
            stagingDir: AppPaths.recordingsDir,
            recoverStagedRecordings: PipelineController.recoverStagedRecordings(into:levelBalance:),
        )
    }
}

extension PipelineController {
    /// The staged recovery pass started last. Each new pass waits for it
    /// before doing anything, orphan scan included, so passes run one at a
    /// time in this process: a queue rebuilt while an earlier pass is still
    /// re-mixing or cutting (watching stopped and started again) would
    /// otherwise cut, restore or queue the same recording twice at once, and
    /// two cuts would share the cut's fixed working-file names.
    @MainActor private(set) static var stagedRecoveryPass: Task<Void, Never>?

    private static func recoverStagedRecordings(into q: PipelineQueue, levelBalance: Bool) {
        startStagedRecovery(into: q, levelBalance: levelBalance, diagnostics: OSLogDiagnostics(category: "RecoveredCut"))
    }

    /// Fire-and-forget: dir scan + per-file attr probes run off-main so app
    /// startup (and the first call to `enqueueFiles`) isn't blocked by a slow
    /// filesystem. Recovered jobs appear in `queue.jobs` once the scan returns.
    /// The pass is returned so a test can wait for it.
    @discardableResult
    static func startStagedRecovery(
        into q: PipelineQueue,
        levelBalance: Bool,
        diagnostics: any DiagnosticsLogging,
    ) -> Task<Void, Never> {
        let previous = stagedRecoveryPass
        let pass = Task {
            await previous?.value
            // The staging folder comes from the queue, not from `AppPaths`:
            // the steps below repair, re-mix, cut and delete files, so a
            // controller built against another staging folder would otherwise
            // reach into the real one, which is exactly what injecting the
            // folder was meant to prevent. Detached so the dir scans and
            // per-file rewrites run off-main and don't block startup (same
            // reason the orphan scan offloads its own filesystem work).
            let staging = q.stagingDir
            let unsettled = await Task.detached(priority: .utility) {
                recoverStagingFolder(staging, levelBalance: levelBalance, diagnostics: diagnostics)
            }.value
            await recoverOrphans(
                into: q, holdingBack: unsettled.map { staging.appendingPathComponent($0 + RecordingFileSuffix.mix) },
            )
        }
        stagedRecoveryPass = pass
        return pass
    }

    /// Rescue recordings whose writer was killed mid-stream (#379) and cut
    /// back the ones the app died with while asking whether their meeting
    /// ended, before the orphan scan enqueues the results. Order matters:
    ///   1. collect the stored meeting-end cuts and record when each
    ///      recording's capture stopped, before steps 2 and 3 rewrite and
    ///      create track files,
    ///   2. repair unfinalized WAV headers so a crashed mic track reads,
    ///   3. re-mix crashed recordings (raw app .tmp + mic) into a _mix.wav,
    ///   4. delete any temp the re-mix couldn't use,
    ///   5. apply the collected cuts to the recordings that now have a mix.
    /// Returns the stems step 5 left unsettled, which the orphan scan must
    /// pass over (`RecoveredCut.apply`).
    @discardableResult
    nonisolated static func recoverStagingFolder(
        _ staging: URL,
        levelBalance: Bool,
        diagnostics: any DiagnosticsLogging,
    ) -> Set<String> {
        let pendingCuts = RecoveredCut.collect(in: staging, diagnostics: diagnostics)
        let repaired = WavHeaderRepair.repairUnfinalized(in: staging)
        if repaired > 0 { logger.info("Repaired \(repaired) unfinalized recording(s) on launch") }
        let recovered = DualSourceRecorder.recoverCrashedRecordings(in: staging, levelBalance: levelBalance)
        if recovered > 0 { logger.info("Recovered \(recovered) crashed recording(s) on launch") }
        DualSourceRecorder.cleanupTempFiles(recordingsDir: staging)
        return RecoveredCut.apply(pendingCuts, in: staging, diagnostics: diagnostics)
    }

    /// The orphan scan, passing over the mixes in `holdingBack`. Each is held
    /// in the queue's run registry, which the scan already skips as audio a
    /// run is busy with, for as long as the scan runs, and released after
    /// it, so the next pass, which restores the hidden track first, can
    /// queue it.
    static func recoverOrphans(
        into q: PipelineQueue,
        holdingBack mixes: [URL],
        recordingsDir: URL = AppPaths.recordingsDir,
    ) async {
        let holds = mixes.map { (id: UUID(), mix: $0) }
        for hold in holds {
            _ = q.inFlightRuns.begin(jobID: hold.id, mixPath: hold.mix)
        }
        defer {
            for hold in holds {
                q.inFlightRuns.end(jobID: hold.id)
            }
        }
        await q.recoverOrphanedRecordings(recordingsDir: recordingsDir)
    }
}
