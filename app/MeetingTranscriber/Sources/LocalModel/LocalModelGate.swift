#if !APPSTORE

    import Foundation

    /// The one way into the local model for the whole app (spec R10). It admits
    /// one helper at a time, from the memory check until the helper's exit is
    /// confirmed; every other caller waits in line. One shared instance, owned
    /// by `PipelineController`, so the queue, the speaker-naming paths and the
    /// regeneration all go through the same door.
    ///
    /// It also holds the guard's two decisions (spec R4): the admission check
    /// before a helper starts, and the watchdog that ends it while it runs.
    ///
    /// The line is FIFO by arrival, with one exception: a job whose helper was
    /// ended for a recording keeps its place, so jobs deferred by one recording
    /// resume in their original order. The place is held from the deferral
    /// until the job comes back, which its caller does at once, also when the
    /// recording ended before the helper had exited; nobody behind it is
    /// admitted meanwhile. A job that does not come back (a regeneration is not
    /// resumed) frees it after `LocalModelLimits.deferredHold`. Admission waits
    /// while a recording runs.
    ///
    /// Ready synchronously at init: nothing a job does before its state
    /// transition may wait for the gate to come up (a restored job races otherwise).
    @MainActor
    final class LocalModelGate {
        /// The job a generation belongs to. A caller that knows it sets it
        /// around the provider call (`LocalModelGate.$jobID.withValue(id) { ... }`),
        /// so the gate records which job owns the running helper and
        /// `cancel(jobID:)` can find it. Nil for a caller that has no job.
        @TaskLocal nonisolated static var jobID: UUID?

        struct Configuration: Sendable {
            var memoryProbe: any LocalModelMemoryProbing = SystemMemoryProbe()
            var limits = LocalModelLimits()
            /// Where run directories are made and leftovers looked for.
            var runDirectoryParent: URL = FileManager.default.temporaryDirectory
            var diagnostics: any DiagnosticsLogging = OSLogDiagnostics(category: "LocalModel")
        }

        /// Where every local-model line goes. Each one is content-free by
        /// construction: ids, counts, fixed words and memory figures.
        nonisolated let diagnostics: any DiagnosticsLogging

        private let configuration: Configuration
        /// The caller admitted now, from its memory check until its helper exited.
        private var owner: Turn?
        private var waiters: [Waiter] = []
        private var nextOrder = 0
        /// Jobs cancelled so far. A job on this list never starts a helper, also
        /// when it reaches the gate only after the cancel (a speaker-naming task
        /// has no handle that a cancel could reach).
        private var cancelledJobs: Set<UUID> = []
        /// The places held for jobs whose helper a recording ended, until they
        /// come back or the hold runs out.
        private var heldPlaces: [UUID: HeldPlace] = [:]
        private var isRecording = false

        init(configuration: Configuration = Configuration()) {
            self.configuration = configuration
            diagnostics = configuration.diagnostics
            let removed = LocalModelRunDirectory.removeLeftovers(in: configuration.runDirectoryParent)
            if removed > 0 { diagnostics.notice("local_model_leftovers removed=\(removed)") }
        }

        /// The job whose generation holds the gate now, if it has one.
        var ownerJobID: UUID? {
            owner?.jobID
        }

        /// Cancels every generation of `jobID`: one waiting in line leaves it, the
        /// running helper is ended if this job owns it, and a later attempt is
        /// refused. Other jobs and their helpers are untouched.
        func cancel(jobID: UUID) {
            cancelledJobs.insert(jobID)
            heldPlaces[jobID] = nil
            let leaving = waiters.filter { $0.jobID == jobID }
            waiters.removeAll { $0.jobID == jobID }
            leaving.forEach { $0.continuation.resume(throwing: CancellationError()) }
            let owns = owner?.jobID == jobID
            if owns { owner?.stop(.cancelled) }
            diagnostics.notice("local_model_cancel \(Self.logTag(jobID)) running=\(owns) waiting=\(leaving.count)")
            admitNext()
        }

        /// Whether a recording runs, from its start until it has fully stopped
        /// (paused included). A recording that starts ends the running helper,
        /// whose generation then ends deferred; while one runs, nothing is admitted.
        func setRecordingActive(_ active: Bool) {
            guard active != isRecording else { return }
            isRecording = active
            if active {
                owner?.stop(.recording)
            } else {
                admitNext()
            }
        }

        /// Ends the running helper before the app quits: SIGTERM, then SIGKILL
        /// after `LocalModelLimits.quitGrace`, blocking until then at most.
        func terminateForQuit() {
            owner?.stopAndWait(grace: configuration.limits.quitGrace)
        }

        nonisolated static func logTag(_ jobID: UUID?) -> String {
            "job=\(jobID.map(PipelineJob.shortID(for:)) ?? "none")"
        }

        // MARK: - Admission

        /// Waits for this caller's turn. Throws `CancellationError` for a
        /// cancelled job or task, also while it waits.
        private func admit(jobID: UUID?, tag: String) async throws -> Turn {
            if let jobID, cancelledJobs.contains(jobID) {
                diagnostics.notice("local_model_refused \(tag) reason=cancelled")
                throw CancellationError()
            }
            try Task.checkCancellation()
            let order = jobID.flatMap { heldPlaces.removeValue(forKey: $0)?.order } ?? takeOrder()
            if owner == nil, !isRecording, isNextInLine(order) {
                let turn = Turn(jobID: jobID, order: order)
                owner = turn
                return turn
            }
            let reason = isRecording ? "recording" : owner != nil ? "busy" : "held_place"
            diagnostics.notice("local_model_waiting \(tag) reason=\(reason)")
            let token = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(token: token, jobID: jobID, order: order, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.abandonWait(token) }
            }
        }

        private func takeOrder() -> Int {
            defer { nextOrder += 1 }
            return nextOrder
        }

        private func abandonWait(_ token: UUID) {
            guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }

        private func release(_ turn: Turn) {
            guard owner === turn else { return }
            owner = nil
            admitNext()
        }

        private func admitNext() {
            guard owner == nil, !isRecording,
                  let next = waiters.indices.min(by: { waiters[$0].order < waiters[$1].order }),
                  isNextInLine(waiters[next].order)
            else { return }
            let waiter = waiters.remove(at: next)
            let turn = Turn(jobID: waiter.jobID, order: waiter.order)
            owner = turn
            waiter.continuation.resume(returning: turn)
        }

        /// Whether nobody waiting, and no job whose place is held, comes before `order`.
        private func isNextInLine(_ order: Int) -> Bool {
            !waiters.contains { $0.order < order } && !heldPlaces.values.contains { $0.order < order }
        }

        /// Holds `order` for `jobID`, whose helper a recording ended, until it
        /// comes back or `LocalModelLimits.deferredHold` runs out.
        private func holdPlace(of jobID: UUID, order: Int) {
            let token = UUID()
            heldPlaces[jobID] = HeldPlace(order: order, token: token)
            let hold = configuration.limits.deferredHold
            Task { [weak self] in
                try? await Task.sleep(for: hold)
                self?.endHold(of: jobID, token: token)
            }
        }

        private func endHold(of jobID: UUID, token: UUID) {
            guard heldPlaces[jobID]?.token == token else { return }
            heldPlaces[jobID] = nil
            diagnostics.notice("local_model_place_freed \(Self.logTag(jobID)) reason=not_back")
            admitNext()
        }

        // MARK: - Types

        private struct HeldPlace {
            let order: Int
            /// Tells this hold from a later one for the same job.
            let token: UUID
        }

        private struct Waiter {
            let token: UUID
            let jobID: UUID?
            let order: Int
            let continuation: CheckedContinuation<Turn, any Error>
        }

        /// One admitted caller. A stop requested before its helper started is
        /// kept and applied when the helper is attached, or makes the caller
        /// give up before starting one.
        @MainActor
        private final class Turn {
            let jobID: UUID?
            let order: Int
            private(set) var stopReason: LocalModelStopReason?
            private var runner: LocalModelHelperRunner?

            init(jobID: UUID?, order: Int) {
                self.jobID = jobID
                self.order = order
            }

            func stop(_ reason: LocalModelStopReason) {
                if stopReason == nil || reason == .cancelled { stopReason = reason }
                runner?.stop(reason)
            }

            func attach(_ runner: LocalModelHelperRunner) {
                self.runner = runner
                if let stopReason { runner.stop(stopReason) }
            }

            func stopAndWait(grace: Duration) {
                stopReason = .cancelled
                runner?.stopAndWait(grace: grace)
            }
        }
    }

    // MARK: - Running a helper

    extension LocalModelGate {
        /// Runs `job` as the only local generation and returns the protocol text.
        /// Every other end throws a `LocalModelOutcome`, or `CancellationError`
        /// for a cancelled job. The gate is released on every path, once the
        /// helper's exit is confirmed.
        func run(_ job: LocalModelJob) async throws -> String {
            let jobID = Self.jobID
            let tag = Self.logTag(jobID)
            let turn = try await admit(jobID: jobID, tag: tag)
            defer { release(turn) }
            do {
                return try await runHelper(job, turn: turn, tag: tag)
            } catch LocalModelOutcome.deferredForRecording {
                if let jobID, !cancelledJobs.contains(jobID) { holdPlace(of: jobID, order: turn.order) }
                throw LocalModelOutcome.deferredForRecording
            }
        }

        private func runHelper(_ job: LocalModelJob, turn: Turn, tag: String) async throws -> String {
            if let reason = turn.stopReason { throw LocalModelOutcome.stopped(by: reason) }
            try Task.checkCancellation()
            let reading = configuration.memoryProbe.read()
            guard LocalModelMemoryGuard.admits(weightBytes: job.weightBytes, reading: reading) else {
                diagnostics.warning("local_model_refused \(tag) reason=low_memory \(reading.logFields) weights_mb=\(job.weightBytes >> 20)")
                throw LocalModelOutcome.lowMemory(reading)
            }
            let directory: URL
            do {
                directory = try LocalModelRunDirectory.make(in: configuration.runDirectoryParent)
            } catch {
                diagnostics.warning("local_model_failed \(tag) reason=run_directory")
                throw LocalModelOutcome.failure(.runDirectory)
            }
            defer { try? FileManager.default.removeItem(at: directory) }
            let requestFile = directory.appendingPathComponent("request.json")
            let outputFile = directory.appendingPathComponent("protocol.md")
            guard Self.writeRequest(for: job, outputFile: outputFile, limits: configuration.limits, to: requestFile) else {
                diagnostics.warning("local_model_failed \(tag) reason=run_directory")
                throw LocalModelOutcome.failure(.runDirectory)
            }
            // Keeps App Nap from slowing the app's side of the run; idle sleep
            // stays allowed, and the deadlines do not count it.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Writing a meeting protocol with the local model",
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let runner = try startHelper(job, requestFile: requestFile, tag: tag)
            diagnostics.notice(
                "local_model_started \(tag) model=\(job.modelFolder.lastPathComponent) pid=\(runner.processIdentifier) weights_mb=\(job.weightBytes >> 20) \(reading.logFields)",
            )
            turn.attach(runner)
            let ending = await runner.waitForExit()
            let result = LocalModelOutcome.resolve(
                ending.termination, stopReason: ending.stopReason, text: Self.protocolText(at: outputFile),
            ) { LocalModelJob.folderIsReachable(job.modelFolder) }
            diagnostics.notice("local_model_exit \(tag) \(Self.logFields(result)) \(Self.logFields(ending))")
            return try result.get()
        }

        private func startHelper(_ job: LocalModelJob, requestFile: URL, tag: String) throws -> LocalModelHelperRunner {
            let probe = configuration.memoryProbe
            let diagnostics = diagnostics
            do {
                return try LocalModelHelperRunner.start(
                    executable: job.helper,
                    request: requestFile,
                    limits: configuration.limits,
                    watchdog: {
                        let reading = probe.read()
                        return LocalModelMemoryGuard.mustTerminate(reading) ? .lowMemory(reading) : nil
                    },
                    onEvent: { event in diagnostics.notice(Self.logLine(for: event, tag: tag)) },
                )
            } catch {
                diagnostics.warning("local_model_failed \(tag) reason=\(error == .runDirectory ? "run_directory" : "could_not_start")")
                throw LocalModelOutcome.failure(error)
            }
        }

        /// The helper's request (`tools/local-llm-helper/README.md`), owner-only.
        /// It carries no sampling settings: those are fixed in the helper (spec A10).
        private static func writeRequest(for job: LocalModelJob, outputFile: URL, limits: LocalModelLimits, to file: URL) -> Bool {
            let request = HelperRequest(
                modelFolder: job.modelFolder.path,
                systemPrompt: job.systemPrompt,
                userPrompt: job.userPrompt,
                contextLimit: limits.contextTokens,
                outputLimit: limits.outputTokens,
                outputPath: outputFile.path,
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(request) else { return false }
            return FileManager.default.createFile(
                atPath: file.path, contents: data, attributes: [.posixPermissions: FileManager.ownerOnlyPermissions],
            )
        }

        /// The protocol the helper wrote, trimmed; nil when there is none. Decoded
        /// with invalid UTF-8 replaced: a helper stopped mid-character leaves a
        /// partial one at the end, which must not cost the whole text.
        private static func protocolText(at file: URL) -> String? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        // MARK: - Log lines

        nonisolated private static func logLine(for event: LocalModelHelperRunner.Event, tag: String) -> String {
            switch event {
            case let .phase(phase): "local_model_phase \(tag) phase=\(phase)"
            case let .prompt(tokens, context, output): "local_model_prompt \(tag) tokens=\(tokens) context=\(context) output=\(output)"
            case let .stopping(reason): "local_model_stopping \(tag) \(logFields(reason))"
            case .killed: "local_model_killed \(tag) after_grace=true"
            }
        }

        nonisolated private static func logFields(_ reason: LocalModelStopReason) -> String {
            switch reason {
            case .cancelled: "reason=cancelled"
            case .recording: "reason=recording"
            case let .lowMemory(reading): "reason=low_memory \(reading.logFields)"
            case let .deadline(deadline): "reason=deadline deadline=\(deadline.rawValue)"
            }
        }

        private static func logFields(_ result: Result<String, any Error>) -> String {
            switch result {
            case .success: "outcome=written"
            case let .failure(outcome as LocalModelOutcome): outcome.description
            case .failure: "outcome=cancelled"
            }
        }

        private static func logFields(_ ending: LocalModelHelperRunner.Ending) -> String {
            "\(ending.termination.logField) elapsed_s=\(ending.elapsed.components.seconds) prompt_tokens=\(ending.promptTokens.map(String.init) ?? "none") tokens=\(ending.tokensWritten ?? 0)"
        }

        /// The request object, field for field as the helper decodes it.
        private struct HelperRequest: Encodable {
            let modelFolder: String
            let systemPrompt: String
            let userPrompt: String
            let contextLimit: Int
            let outputLimit: Int
            let outputPath: String
        }
    }

#endif
