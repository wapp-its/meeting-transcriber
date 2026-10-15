#if !APPSTORE

    import Foundation

    /// The fixed limits of a local run, all in one place. The pilot offers none
    /// of them as a setting (spec A2 for the first four).
    struct LocalModelLimits: Sendable {
        /// Prompt plus output, in tokens; also the size of the helper's KV cache.
        var contextTokens = 32768
        /// The most tokens the model may write.
        var outputTokens = 16000
        /// The longest a helper may run.
        var totalDeadline: Duration = .seconds(20 * 60)
        /// The longest a helper may go without a progress line.
        var noProgressDeadline: Duration = .seconds(3 * 60)
        /// How long a helper has after SIGTERM before SIGKILL. The helper stops
        /// at the next token and syncs its output, measured at about 2 s; 3 s
        /// leaves room for that and still ends it well inside the 5 s a
        /// recording start allows (spec R5).
        var killGrace: Duration = .seconds(3)
        /// The same when the app quits, which waits for it on the main thread.
        var quitGrace: Duration = .seconds(1)
        /// How often the deadlines and the memory watchdog are checked while a
        /// helper runs. Reading the memory figures costs microseconds.
        var pollInterval: Duration = .seconds(1)
        /// How long stderr may stay open after the helper exited, for its last lines.
        var drainAfterExit: Duration = .seconds(2)
    }

    /// What one generation hands the gate, fixed when it starts.
    struct LocalModelJob: Sendable {
        let helper: URL
        let modelFolder: URL
        let systemPrompt: String
        let userPrompt: String
        /// The size of the model's weight files, for the admission check.
        let weightBytes: UInt64

        /// Whether the model folder is there as a directory.
        static func folderIsReachable(_ folder: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Writes the protocol with a local MLX model, in a helper process the app
    /// starts for this one job and that exits afterwards (spec R3), through the
    /// app-wide `LocalModelGate`.
    ///
    /// The prompt is the one the other providers send: the system prompt from
    /// `ProtocolGenerator.buildSystemPrompt`, the transcript as the user prompt,
    /// as `OpenAIProtocolGenerator` splits them. The folder is the one the
    /// settings named when this generator was made, so a later change in
    /// Settings never reaches a run that already started.
    ///
    /// Returns the text only for a written protocol; every other end throws a
    /// `LocalModelOutcome`, or `CancellationError` for a cancelled job.
    struct LocalModelProtocolGenerator: ProtocolGenerating {
        let folder: LocalModelFolderSelection
        let language: String
        let gate: LocalModelGate
        /// Where the helper executable is; the bundled one in production.
        var locateHelper: @Sendable () -> URL? = { LocalModelHelperLocator.locate() }

        func generate(
            transcript: String,
            title _: String,
            diarized: Bool,
            meetingStartTime: Date?,
            instructions: ProtocolInstructions,
        ) async throws -> String {
            let tag = LocalModelGate.logTag(LocalModelGate.jobID)
            let diagnostics = gate.diagnostics
            guard let helper = locateHelper(), LocalModelHelperLocator.isExecutableFile(helper) else {
                diagnostics.warning("local_model_refused \(tag) reason=helper_missing")
                throw LocalModelOutcome.failure(.helperMissing)
            }
            guard let folderURL = folder.resolve() else {
                diagnostics.warning("local_model_refused \(tag) reason=no_model folder=\(folder.path.isEmpty ? "not_chosen" : "unresolvable")")
                throw LocalModelOutcome.noModel
            }
            // Held from before the helper starts until its exit is confirmed.
            let accessing = folderURL.startAccessingSecurityScopedResource()
            defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
            guard LocalModelJob.folderIsReachable(folderURL) else {
                diagnostics.warning("local_model_refused \(tag) reason=no_model folder=unreachable")
                throw LocalModelOutcome.noModel
            }
            let systemPrompt = ProtocolGenerator.buildSystemPrompt(
                diarized: diarized, language: language, meetingStartTime: meetingStartTime, instructions: instructions,
            )
            return try await gate.run(LocalModelJob(
                helper: helper,
                modelFolder: folderURL,
                systemPrompt: systemPrompt,
                userPrompt: transcript,
                weightBytes: LocalModelMemoryGuard.weightBytes(in: folderURL),
            ))
        }
    }

#endif
