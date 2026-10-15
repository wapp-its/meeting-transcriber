import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// Where the queue meets the local model's gate (spec R5, R6, R10): the job
/// identity a generation runs under, waiting out a recording that ended the
/// helper, and a job cancel that reaches the helper it owns.
///
/// Every protocol the queue writes passes `generateProtocol`, the queue's own
/// runs and every speaker-naming path alike (a confirm, a skip, the stale
/// cleanup and the restore's protocol-only resume all call it), so this is
/// the one place those paths meet the gate. Other providers go through
/// unchanged: none of them throws the deferred outcome.
extension PipelineQueue {
    /// Runs `generator` as `jobID`'s generation and returns the protocol text.
    ///
    /// A local generation a recording ended (`LocalModelOutcome.deferredForRecording`)
    /// is asked again at once, with the same generator, so the selection captured
    /// when the job reached this stage still holds. The wait for the recording to
    /// end is the gate's admission, not a poll here: the gate admits nothing
    /// while a recording runs and holds the deferred job's place in its line, so
    /// jobs deferred by one recording run again in their original order, each
    /// through the full start check. The job stays in `.generatingProtocol`
    /// throughout (spec A8), which is what makes a restart resume only this
    /// stage. Only the attempt that ends the loop reaches the caller, so a
    /// deferred attempt never records its outcome over the one that followed it.
    func generateWaitingOutRecordings(
        _ generator: sending any ProtocolGenerating, jobID: UUID,
        request: (transcript: String, title: String, meetingStartTime: Date?, instructions: ProtocolInstructions),
    ) async throws -> String {
        let diarized = ProtocolGenerator.looksDiarized(request.transcript)
        #if !APPSTORE
            if let local = generator as? LocalModelProtocolGenerator {
                localModelGate = local.gate
                return try await LocalModelGate.$jobID.withValue(jobID) {
                    var deferrals = 0
                    while true {
                        do {
                            return try await local.generate(
                                transcript: request.transcript, title: request.title, diarized: diarized,
                                meetingStartTime: request.meetingStartTime, instructions: request.instructions,
                            )
                        } catch LocalModelOutcome.deferredForRecording {
                            deferrals += 1
                            logger.info(
                                "[\(PipelineJob.shortID(for: jobID), privacy: .public)] protocol_deferred_for_recording deferrals=\(deferrals, privacy: .public)",
                            )
                        }
                    }
                }
            }
        #endif
        return try await generator.generate(
            transcript: request.transcript, title: request.title, diarized: diarized,
            meetingStartTime: request.meetingStartTime, instructions: request.instructions,
        )
    }

    /// Ends `jobID`'s local generation: its helper when it owns the running
    /// one, its place when it waits at the gate, and any later attempt.
    /// Another job's helper is never touched. Reaches a generation that runs
    /// in a speaker-naming task as well, which no task cancel of the queue does.
    func cancelLocalModelGeneration(jobID: UUID) {
        #if !APPSTORE
            localModelGate?.cancel(jobID: jobID)
        #endif
    }
}
