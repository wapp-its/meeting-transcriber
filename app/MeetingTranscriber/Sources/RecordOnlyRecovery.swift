import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "StagingRecovery")

/// What a staged recovery pass needs to file the recordings it recovers the
/// way record-only mode files a recording that ended normally, instead of
/// queuing them for processing. The controller hands one to every pass; the
/// pass calls `isOn` when it hands its recordings on, after its staging work
/// and its orphan scan, so the setting at that moment decides.
struct RecordOnlyRecovery {
    /// `AppSettings.recordOnly`.
    let isOn: @MainActor () -> Bool
    /// Whether a quit has begun, asked before each write. A quit in
    /// record-only mode writes the recording it stopped off the main actor
    /// and keeps that recording's staging files until its sidecar commits,
    /// so a pass writing it as well would file it twice, or take its files
    /// away from under the quit's copy. What a pass passes over this way
    /// stays in staging for the next launch.
    let quitHasBegun: @MainActor () -> Bool
    /// The folder the watch loops write into, resolved per write, so the
    /// output-folder fallback and its one-time notice apply as on a live stop.
    let destination: @MainActor () -> RecordOnlyDestination
    let notifier: any AppNotifying
}

extension PipelineController {
    /// The record-only side of every staged recovery pass this controller's
    /// queues run.
    var recordOnlyRecovery: RecordOnlyRecovery {
        RecordOnlyRecovery(
            isOn: { [settings] in settings.recordOnly },
            quitHasBegun: { [weak self] in self?.quitHasBegun() == true },
            destination: { [outputDirectory] in .production(parent: outputDirectory.resolve()) },
            notifier: notifier,
        )
    }
}

extension PipelineQueue {
    /// Record-only mode's hand-on of a recovery pass, in place of
    /// `adoptOrphanedRecordings`: each scanned recording is written into the
    /// output folder with its sidecar, as a live record-only stop writes one,
    /// and gets no job. The scan ran on another task, so right before each
    /// write the recording is asked again, here on the main actor: its mix is
    /// still in staging, no job, run or ledger entry accounts for it (what the
    /// adoption asks again), the queue is not retired and no quit has begun.
    /// A recording that fails any of these is skipped with no write, no
    /// notice and no job, its files left where they are.
    ///
    /// A failed write leaves the recording in staging for the next pass, and
    /// one notice per pass says how many failed. It is never processed
    /// instead.
    func fileOrphanedRecordings(_ scanned: [PairedRecordingResolver.Group], recordOnly: RecordOnlyRecovery) async {
        var filed = 0
        var failed = 0
        for group in scanned {
            guard !isRetired, !recordOnly.quitHasBegun() else { break }
            guard let mix = group.mix, isStillOrphaned(mix) else { continue }
            let destination = recordOnly.destination()
            let (stem, app, mic) = (group.stem, group.app, group.mic)
            do {
                // Off the main actor: into an output folder on another volume
                // each file is a copy.
                let kept = try await Task.detached(priority: .utility) {
                    try RecordOnlyWrite.recovered(stem: stem, mix: mix, app: app, mic: mic, into: destination).perform()
                }.value
                filed += 1
                RecordOnlyWrite.reportStagingFilesKept(kept, to: recordOnly.notifier)
            } catch {
                failed += 1
                let code = error as NSError
                logger.error(
                    "Record-only recovery: a recording could not be written (\(code.domain, privacy: .public) \(code.code, privacy: .public))",
                )
            }
        }
        if failed > 0 {
            recordOnly.notifier.notify(title: "Record-only output failed", body: Self.recoveredWriteFailedBody(failed), urgency: .standard)
        }
        if filed > 0 {
            logger.info("Record-only recovery: filed \(filed, privacy: .public), failed \(failed, privacy: .public)")
        }
    }

    /// Whether a scanned mix is still in staging and still nobody's.
    private func isStillOrphaned(_ mix: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: mix.path) else { return false }
        let path = mix.standardizedFileURL.path
        return !accountedForMixPaths().contains(path) && !processedLedger.load().contains(path)
    }

    private static func recoveredWriteFailedBody(_ count: Int) -> String {
        count == 1
            ? "A recovered recording could not be written to the output folder. "
            + "It stays in the app's staging folder and is tried again later."
            : "\(count) recovered recordings could not be written to the output folder. "
            + "They stay in the app's staging folder and are tried again later."
    }
}

extension RecordOnlyWrite {
    /// The write for a recording the recovery pass found in staging. Nothing
    /// about how it was started survived the crash, so it gets the title the
    /// processing path gives it, no app, participants, trigger or pauses, its
    /// tracks aligned at their starts, and a stop at its start plus the length
    /// of its mix. Reads the files, so it runs off the main actor.
    static func recovered(stem: String, mix: URL, app: URL?, mic: URL?, into destination: RecordOnlyDestination) -> Self {
        let startedAt = recordedStart(stem: stem, files: [mix, app, mic].compactMap(\.self))
        return RecordOnlyWrite(
            title: PipelineQueue.recoveredRecordingTitle(stem: stem),
            appName: "Unknown",
            recording: RecordingResult(mixPath: mix, appPath: app, micPath: mic, micDelay: 0, recordingStartDate: startedAt),
            trigger: nil,
            participants: [],
            stoppedAt: startedAt.addingTimeInterval(RecordingCut.duration(of: mix) ?? 0),
            destination: destination,
            transfer: linkOrCopy,
        )
    }

    /// The recorder names a recording by its local start time
    /// (`yyyyMMdd_HHmmss`), read here in the current time zone. A stem that is
    /// not such a time takes the earliest creation date of the files.
    private static func recordedStart(stem: String, files: [URL]) -> Date {
        if let date = DateFormatter.filenameStamp("yyyyMMdd_HHmmss").date(from: stem) { return date }
        let created = files.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
        return created.min() ?? Date()
    }
}
