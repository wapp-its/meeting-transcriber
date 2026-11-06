// One staging recovery at a time in this process, each judging file ages from
// when it was asked for.
//
// Every queue rebuild starts a staging recovery (header repair, crash re-mix,
// temp cleanup). Two that overlap on one crashed stem can end with a
// microphone-only mix over the complete one: the second finds the stem not yet
// mixed, the first mixes it and consumes the raw app temp, and the second
// rebuilds from the microphone track alone. The cleanup of one can also delete
// a raw temp the other is about to re-mix.
//
// The gate is a serial queue. A caller waits by suspending, not by parking a
// thread of the cooperative pool: the work runs on the gate's own queue. It
// covers this process only; a second running app instance shares the staging
// folder and is not covered.
//
// A recovery that waited behind another (a re-mix of a long recording takes
// minutes) still tells a crashed recording from a live one by the time of its
// request: every age guard in the work is measured from `requestedAt`, so a
// recording that began while it waited, and whose tracks then stopped
// advancing, does not become eligible merely because the wait was long.
import Foundation

enum StagingRecoveryGate {
    private static let queue = DispatchQueue(label: "com.meetingtranscriber.staging-recovery", qos: .utility)

    /// The file work of the staging recovery production runs on each queue
    /// build (`PipelineController.recoverStagingFolder`: collect the stored
    /// meeting-end cuts, repair unfinalized headers, re-mix crashed
    /// recordings, delete the temps the re-mix could not use, apply the
    /// cuts), through the gate, without level balancing and without
    /// reporting which recordings a cut left unsettled. `minAge` is the age
    /// guard, measured back from `requestedAt`. Production calls the same
    /// steps through `run` from `PipelineController.startStagedRecovery`,
    /// which needs the unsettled recordings for its orphan scan.
    static func recover(in staging: URL, requestedAt: Date = Date(), minAge: TimeInterval = 30) async {
        _ = await run {
            PipelineController.recoverStagingFolder(
                staging,
                levelBalance: false,
                diagnostics: OSLogDiagnostics(category: "RecoveredCut"),
                requestedAt: requestedAt,
                minAge: minAge,
            )
        }
    }

    /// Run `work` once every staging recovery started before it in this
    /// process has finished, and hand back what it returned.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
