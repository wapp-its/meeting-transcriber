#if !APPSTORE

    import Foundation

    /// The helper's exit statuses. The helper defines them in
    /// `tools/local-llm-helper/Sources/LocalLLMHelper/ExitStatus.swift` and documents
    /// them in that package's README; the two packages share no code, so this is
    /// the app's copy, and `LocalModelGeneratorTests` reads the README table to
    /// keep the two in step.
    enum LocalModelHelperExitStatus: Int32 {
        /// The model ended the protocol; the output file holds all of it.
        case written = 0
        /// Anything not listed below.
        case failure = 1
        /// Generation stopped at the output limit; the text so far is kept.
        case incomplete = 10
        /// The model folder is missing, incomplete, unreadable or unsupported.
        case modelUnusable = 11
        /// Prompt plus output limit exceed the context limit; no weights loaded.
        case promptTooLong = 12
        /// SIGTERM, or the parent is gone; what was written is flushed first.
        case terminated = 13
    }

    /// Which deadline ended a helper.
    enum LocalModelDeadline: String, Sendable {
        /// The whole run took longer than `LocalModelLimits.totalDeadline`.
        case total
        /// No progress line arrived for `LocalModelLimits.noProgressDeadline`.
        case noProgress = "no_progress"
    }

    /// Why the app asked a running helper to stop.
    enum LocalModelStopReason: Equatable, Sendable {
        /// The job was cancelled, its task was cancelled, or the app quits.
        case cancelled
        /// A recording started.
        case recording
        /// The memory watchdog saw these readings.
        case lowMemory(LocalModelMemoryReading)
        case deadline(LocalModelDeadline)
    }

    /// A local generation that ended without a usable outcome of its own kind.
    enum LocalModelFailure: Error, Equatable {
        /// No executable helper in the app bundle.
        case helperMissing
        /// The private run directory or the request file in it could not be made.
        case runDirectory
        /// The helper could not be started.
        case couldNotStart
        /// The helper reported success but wrote no protocol text.
        case emptyOutput
        /// The helper exited with this status, unasked.
        case exitStatus(Int32)
        /// The helper was ended by this signal, unasked (a crash, an outside kill).
        case signal(Int32)
    }

    /// Every way a local generation ends other than a written protocol, which
    /// `LocalModelProtocolGenerator.generate` returns as text. Thrown as the
    /// error so the protocol stage can tell the outcomes apart (spec R11); a
    /// cancelled job throws `CancellationError` instead.
    ///
    /// `description` is content-free on purpose: `.incomplete` carries protocol
    /// text, and an error that is interpolated into a log line must not put it
    /// there (spec R12).
    enum LocalModelOutcome: Error, Equatable, CustomStringConvertible {
        /// Stopped at the output limit; the text written until then, trimmed.
        case incomplete(text: String)
        /// A recording started, so the helper was ended (or never started); the
        /// protocol runs again once no recording runs.
        case deferredForRecording
        /// Refused at start or ended by the watchdog; the readings that decided it.
        case lowMemory(LocalModelMemoryReading)
        /// No model folder chosen, it cannot be reached, or the helper found it unusable.
        case noModel
        /// Prompt plus output limit exceed the context limit; refused before any weights loaded.
        case promptTooLong
        /// A deadline ended a stuck helper.
        case deadline(LocalModelDeadline)
        case failure(LocalModelFailure)

        var description: String {
            switch self {
            case .incomplete: "outcome=incomplete"
            case .deferredForRecording: "outcome=deferred_for_recording"
            case let .lowMemory(reading): "outcome=low_memory \(reading.logFields)"
            case .noModel: "outcome=no_model"
            case .promptTooLong: "outcome=prompt_too_long"
            case let .deadline(deadline): "outcome=deadline deadline=\(deadline.rawValue)"
            case let .failure(failure): "outcome=failure failure=\(failure)"
            }
        }

        /// The outcome a stop the app asked for stands for.
        static func stopped(by reason: LocalModelStopReason) -> any Error {
            switch reason {
            case .cancelled: CancellationError()
            case .recording: deferredForRecording
            case let .lowMemory(reading): Self.lowMemory(reading)
            case let .deadline(deadline): Self.deadline(deadline)
            }
        }

        /// What a helper's end means for the job.
        ///
        /// - `text`: the output file's content, trimmed; nil when it is empty or unreadable.
        /// - `folderReachable`: asked only for an end the app did not ask for, so
        ///   a folder that vanished during the run (an ejected volume, whose
        ///   memory-mapped weights take the helper down) reports as no model.
        ///
        /// A cancellation wins over everything, the written text included: the
        /// person asked for no protocol. Any other stop the app asked for loses
        /// to a status that carries text (0, 10) or a verdict the helper reached
        /// before loading anything (11, 12), and explains every other end.
        static func resolve(
            _ termination: LocalModelHelperRunner.Termination,
            stopReason: LocalModelStopReason?,
            text: String?,
            folderReachable: () -> Bool,
        ) -> Result<String, any Error> {
            if stopReason == .cancelled { return .failure(CancellationError()) }
            if case let .exited(code) = termination, let status = LocalModelHelperExitStatus(rawValue: code) {
                switch status {
                case .written: return text.map { .success($0) } ?? .failure(failure(.emptyOutput))
                case .incomplete: return .failure(text.map { Self.incomplete(text: $0) } ?? failure(.emptyOutput))
                case .modelUnusable: return .failure(noModel)
                case .promptTooLong: return .failure(promptTooLong)
                case .failure, .terminated: break
                }
            }
            if let stopReason { return .failure(stopped(by: stopReason)) }
            guard folderReachable() else { return .failure(Self.noModel) }
            switch termination {
            case let .exited(code): return .failure(Self.failure(.exitStatus(code)))
            case let .signalled(signal): return .failure(Self.failure(.signal(signal)))
            }
        }
    }

#endif
