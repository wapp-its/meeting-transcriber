import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingSummarizer")

/// Takes a meeting's notes summary each time the app saves its current notes (spec
/// R2, R5): from the notes' summary section (`MeetingSummary.section`), or, for
/// notes without one, from one call to the notes provider after the save, in the
/// background and apart from the pipeline's queue.
///
/// Calls run one at a time, in the order the saves came, each stopped after
/// `callTimeout`. A call's answer counts only while its save is the meeting's latest:
/// a newer save of the meeting, or the meeting leaving the lists (`forget`), stops it
/// and drops its answer. The summary file records the latest save as well
/// (`MeetingSummaryStore.beginNotesSave`), so a newer save or a removal in another
/// running build, or summaries cleared in the sheet, drop the answer too. Nothing is
/// kept across a quit, so a call that was started
/// is never made again at the next launch. A failed, timed-out or empty call stores
/// nothing and keeps the earlier summary; its one log line names the job's short id,
/// the provider and the outcome, never the notes or the answer.
@MainActor
final class MeetingSummarizer {
    /// The notes just saved: their text, or the file a re-run's success made current,
    /// which is read once, off the main actor (the swap can come in a later launch
    /// than the save).
    enum SavedNotes {
        case text(String)
        case file(URL)
    }

    let store: MeetingSummaryStore
    private let now: () -> Date
    private let callTimeout: Duration

    /// Each meeting's latest notes save.
    private var latestSave: [UUID: UUID] = [:]
    /// The calls not finished yet, by save, so a newer save or `forget` can stop one.
    private var calls: [UUID: (jobID: UUID, task: Task<Void, Never>)] = [:]
    /// The saves whose call ran out of time.
    private var timedOut: Set<UUID> = []
    /// The last call queued, which the next one waits for.
    private var lastCall: Task<Void, Never>?

    init(store: MeetingSummaryStore, now: @escaping () -> Date = Date.init, callTimeout: Duration = .seconds(180)) {
        self.store = store
        self.now = now
        self.callTimeout = callTimeout
    }

    /// The app saved `jobID`'s current notes. `generator` is the notes provider's
    /// factory, asked at most once, and only for notes without a summary section; nil
    /// from it (provider None) makes no call.
    func notesSaved(
        jobID: UUID, notes: SavedNotes, title: String, generator: @escaping @MainActor () -> (any ProtocolGenerating)?,
    ) {
        let save = UUID()
        latestSave[jobID] = save
        stopCalls(of: jobID)
        // In the file too, so a call still running in another build drops its answer.
        guard store.beginNotesSave(save, jobID: jobID) else {
            logger.error("[\(PipelineJob.shortID(for: jobID), privacy: .public)] summary_skipped reason=save_not_recorded")
            return
        }
        switch notes {
        case let .text(text):
            summarize(text, save: save, jobID: jobID, title: title, generator: generator)

        case let .file(url):
            Task { [weak self] in
                let text = await Self.read(url)
                guard let self, latestSave[jobID] == save else { return }
                guard let text else {
                    logger.info("[\(PipelineJob.shortID(for: jobID), privacy: .public)] summary_skipped reason=notes_unreadable")
                    return
                }
                summarize(text, save: save, jobID: jobID, title: title, generator: generator)
            }
        }
    }

    /// The meeting left every list (Move Meeting to Trash): a call for it stops and
    /// stores nothing, and its summaries go.
    func forget(jobID: UUID) {
        latestSave[jobID] = nil
        stopCalls(of: jobID)
        if !store.remove(jobID: jobID) {
            logger.error("[\(PipelineJob.shortID(for: jobID), privacy: .public)] summary_not_removed")
        }
    }

    /// Waits for every call queued so far. For tests.
    func awaitCalls() async {
        while let last = lastCall {
            await last.value
            if lastCall == last { return }
        }
    }

    // MARK: - Taking the summary

    private func summarize(
        _ notes: String, save: UUID, jobID: UUID, title: String, generator: @MainActor () -> (any ProtocolGenerating)?,
    ) {
        let shortID = PipelineJob.shortID(for: jobID)
        if let section = MeetingSummary.section(in: notes) {
            store(section, save: save, jobID: jobID, source: "section")
            return
        }
        guard let made = generator() else {
            logger.info("[\(shortID, privacy: .public)] summary_skipped reason=no_provider")
            return
        }
        let provider = String(describing: type(of: made))
        #if !APPSTORE
            if let command = made as? CommandProtocolGenerator, !command.receivesPrompt {
                logger.info("[\(shortID, privacy: .public)] summary_skipped provider=\(provider, privacy: .public) reason=no_prompt")
                return
            }
        #endif
        let previous = lastCall
        let request = MeetingSummary.notesForCall(notes)
        let task = Task.detached { [weak self] in
            // One call at a time: a call waits for the one queued before it.
            await previous?.value
            guard await self?.begin(save, jobID: jobID) == true else { return }
            let result: Result<String, any Error>
            do {
                result = try await .success(Self.call(made, notes: request, title: title))
            } catch {
                result = .failure(error)
            }
            await self?.finish(save, jobID: jobID, provider: provider, result: result)
        }
        calls[save] = (jobID, task)
        lastCall = task
    }

    /// Whether the call of `save` still runs now that its turn came, with its time
    /// limit started.
    private func begin(_ save: UUID, jobID: UUID) -> Bool {
        guard latestSave[jobID] == save, let task = calls[save]?.task else {
            calls[save] = nil
            return false
        }
        let limit = callTimeout
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, calls[save] != nil else { return }
            timedOut.insert(save)
            task.cancel()
        }
        return true
    }

    private func finish(_ save: UUID, jobID: UUID, provider: String, result: Result<String, any Error>) {
        calls[save] = nil
        let late = timedOut.remove(save) != nil
        let shortID = PipelineJob.shortID(for: jobID)
        guard latestSave[jobID] == save else {
            logger.info("[\(shortID, privacy: .public)] summary_dropped provider=\(provider, privacy: .public) reason=overtaken")
            return
        }
        // An answer that came after the time limit counts as none.
        switch late ? .failure(CancellationError()) : result {
        case let .success(answer):
            if let summary = MeetingSummary.clean(answer) {
                store(summary, save: save, jobID: jobID, source: "call provider=\(provider)")
            } else {
                logger.info("[\(shortID, privacy: .public)] summary_failed provider=\(provider, privacy: .public) outcome=empty")
            }

        case let .failure(error):
            let outcome = late ? "timed_out" : (error as? ProtocolError)?.logSummary ?? String(describing: type(of: error))
            logger.warning("[\(shortID, privacy: .public)] summary_failed provider=\(provider, privacy: .public) outcome=\(outcome, privacy: .public)")
        }
    }

    /// Stores the notes summary of `save` while the file holds it as the meeting's
    /// latest notes save: not after a newer save in any build, a cleared or a removed
    /// meeting.
    private func store(_ summary: String, save: UUID, jobID: UUID, source: String) {
        let date = now()
        let shortID = PipelineJob.shortID(for: jobID)
        let outcome = store.commit(save, jobID: jobID) { MeetingSummary.afterNotesSaved($0, notesSummary: summary, at: date) }
        switch outcome {
        case .stored:
            logger.info("[\(shortID, privacy: .public)] summary_taken source=\(source, privacy: .public)")

        case .overtaken:
            logger.info("[\(shortID, privacy: .public)] summary_dropped source=\(source, privacy: .public) reason=overtaken")

        case .failed:
            logger.error("[\(shortID, privacy: .public)] summary_not_saved")
        }
    }

    /// Stops the meeting's calls whose save is no longer its latest.
    private func stopCalls(of jobID: UUID) {
        for (save, call) in calls where call.jobID == jobID && latestSave[jobID] != save {
            call.task.cancel()
        }
    }

    // MARK: - The call

    /// The provider's answer: the notes as the text, the meeting's title, no speaker
    /// note, no meeting time and `MeetingSummary.instruction` as the template. A local
    /// model's call yields to meeting notes (`LocalModelGate.yields`) and waits out a
    /// recording as the notes do.
    nonisolated private static func call(_ generator: any ProtocolGenerating, notes: String, title: String) async throws -> String {
        let instructions = ProtocolInstructions(template: MeetingSummary.instruction, background: nil)
        #if !APPSTORE
            if let local = generator as? LocalModelProtocolGenerator {
                return try await LocalModelGate.$yields.withValue(true) {
                    while true {
                        do {
                            return try await local.generate(
                                transcript: notes, title: title, diarized: false, meetingStartTime: nil, instructions: instructions,
                            )
                        } catch LocalModelOutcome.deferredForRecording {
                            try Task.checkCancellation()
                        }
                    }
                }
            }
        #endif
        return try await generator.generate(transcript: notes, title: title, diarized: false, meetingStartTime: nil, instructions: instructions)
    }

    nonisolated private static func read(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            try? String(contentsOf: url, encoding: .utf8)
        }.value
    }
}
