#if !APPSTORE

    import Darwin
    import Foundation

    /// A line of the helper's stderr that the app acts on, per the contract in
    /// `tools/local-llm-helper/README.md`. Every field there is a number or a
    /// fixed word; a line of any other shape is not parsed and never logged.
    enum LocalModelHelperLine: Equatable {
        case loading
        case prefill(chunk: Int, total: Int)
        case writing(tokens: Int)
        case prompt(tokens: Int, contextLimit: Int, outputLimit: Int)

        /// The phase a progress line reports; nil for a lifecycle line. Progress
        /// lines, and only they, reset the no-progress deadline.
        var phase: String? {
            switch self {
            case .loading: "loading"
            case .prefill: "prefill"
            case .writing: "writing"
            case .prompt: nil
            }
        }

        static func parse(_ line: String) -> Self? {
            let words = line.split(separator: " ")
            var fields: [Substring: Substring] = [:]
            for word in words.dropFirst() {
                guard let separator = word.firstIndex(of: "=") else { return nil }
                fields[word[..<separator]] = word[word.index(after: separator)...]
            }
            let number = { (key: Substring) in fields[key].flatMap { Int($0) } }
            switch (words.first, fields["phase"] ?? fields["event"]) {
            case ("progress", "loading"):
                return .loading

            case ("progress", "prefill"):
                guard let chunk = number("chunk"), let total = number("total") else { return nil }
                return .prefill(chunk: chunk, total: total)

            case ("progress", "writing"):
                return number("tokens").map { .writing(tokens: $0) }

            case ("lifecycle", "prompt"):
                guard let tokens = number("tokens"), let context = number("context"), let output = number("output") else { return nil }
                return .prompt(tokens: tokens, contextLimit: context, outputLimit: output)

            default:
                return nil
            }
        }
    }

    /// One helper process, from its start to its confirmed exit. The helper gets
    /// a fixed argument vector (`run`, no shell), the request file as stdin and
    /// the run directory the request is in as working directory; its stdout is
    /// discarded and its stderr read for progress.
    ///
    /// While it runs, a poll on the run's own serial queue ends it when a
    /// deadline passes or the watchdog asks for it. Deadlines count only time the
    /// Mac is awake (`SuspendingClock`). Ending means SIGTERM, then SIGKILL after
    /// `LocalModelLimits.killGrace` if it is still running.
    ///
    /// Its state is touched only on `queue`, like `CLIProcessRunner.Run`'s; it is
    /// a separate type because that runner has no way to stop a program on
    /// request and no notion of progress.
    final class LocalModelHelperRunner: @unchecked Sendable {
        enum Termination: Equatable, Sendable {
            case exited(Int32)
            case signalled(Int32)

            var logField: String {
                switch self {
                case let .exited(status): "status=\(status)"
                case let .signalled(signal): "signal=\(signal)"
                }
            }
        }

        struct Ending: Equatable, Sendable {
            let termination: Termination
            /// Why the app asked it to stop, if it did.
            let stopReason: LocalModelStopReason?
            let promptTokens: Int?
            let tokensWritten: Int?
            let elapsed: Duration
        }

        /// What the run reports while it goes, for the diagnostics log.
        enum Event: Sendable {
            case phase(String)
            case prompt(tokens: Int, contextLimit: Int, outputLimit: Int)
            case stopping(LocalModelStopReason)
            /// It was still running after the grace period and got SIGKILL.
            case killed
        }

        /// A line longer than this is not one of the helper's and is dropped unread.
        private static let maxLineBytes = 4096

        private let queue = DispatchQueue(label: "com.meetingtranscriber.local-model-helper")
        private let process = Process()
        private let limits: LocalModelLimits
        private let watchdog: @Sendable () -> LocalModelStopReason?
        private let onEvent: @Sendable (Event) -> Void
        private let clock = SuspendingClock()

        private(set) var processIdentifier: Int32 = 0

        // Touched only on `queue`.
        private var startedAt: SuspendingClock.Instant
        private var lastProgressAt: SuspendingClock.Instant
        private var stderrSource: (any DispatchSourceRead)?
        private var timers: [any DispatchSourceTimer] = []
        private var lineBuffer: [UInt8] = []
        private var readBuffer = [UInt8](repeating: 0, count: 16 * 1024)
        private var stderrAtEnd = false
        private var phase: String?
        private var promptTokens: Int?
        private var tokensWritten: Int?
        private var stopReason: LocalModelStopReason?
        private var termination: Termination?
        private var ending: Ending?
        private var continuation: CheckedContinuation<Ending, Never>?

        private init(
            limits: LocalModelLimits,
            watchdog: @escaping @Sendable () -> LocalModelStopReason?,
            onEvent: @escaping @Sendable (Event) -> Void,
        ) {
            self.limits = limits
            self.watchdog = watchdog
            self.onEvent = onEvent
            startedAt = clock.now
            lastProgressAt = startedAt
        }

        /// Starts the helper at `executable` with the `request` file as its stdin,
        /// in the directory that file is in. `watchdog` is asked on every poll
        /// whether the helper must stop.
        static func start(
            executable: URL,
            request: URL,
            limits: LocalModelLimits,
            watchdog: @escaping @Sendable () -> LocalModelStopReason?,
            onEvent: @escaping @Sendable (Event) -> Void,
        ) throws(LocalModelFailure) -> LocalModelHelperRunner {
            let runner = LocalModelHelperRunner(limits: limits, watchdog: watchdog, onEvent: onEvent)
            var failure: LocalModelFailure?
            runner.queue.sync {
                do throws(LocalModelFailure) {
                    try runner.launch(executable: executable, request: request)
                } catch {
                    failure = error
                }
            }
            if let failure { throw failure }
            return runner
        }

        /// Asks the helper to stop. The first reason is kept, except that a
        /// cancellation replaces any other: the person asked for no protocol at all.
        func stop(_ reason: LocalModelStopReason) {
            queue.async { [self] in requestStop(reason) }
        }

        /// Waits for the helper's exit, and for the lines it wrote before it. A
        /// cancelled task stops the helper and still waits for its exit, which
        /// SIGKILL bounds.
        func waitForExit() async -> Ending {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    queue.async { [self] in
                        if let ending {
                            continuation.resume(returning: ending)
                        } else {
                            self.continuation = continuation
                        }
                    }
                }
            } onCancel: {
                stop(.cancelled)
            }
        }

        /// Stops the helper and blocks until it has exited, at most `grace`
        /// before SIGKILL. For the app's quit, which cannot wait asynchronously.
        func stopAndWait(grace: Duration) {
            queue.sync { requestStop(.cancelled) }
            let deadline = clock.now.advanced(by: grace)
            while process.isRunning, clock.now < deadline {
                usleep(10000)
            }
            if process.isRunning { kill(processIdentifier, SIGKILL) }
        }

        // MARK: - Launch

        private func launch(executable: URL, request: URL) throws(LocalModelFailure) {
            dispatchPrecondition(condition: .onQueue(queue))
            let input = open(request.path, O_RDONLY | O_NOFOLLOW)
            guard input >= 0 else { throw .runDirectory }
            defer { close(input) }
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { throw .couldNotStart }
            let (readEnd, writeEnd) = (ends[0], ends[1])
            process.executableURL = executable
            process.arguments = ["run"]
            process.currentDirectoryURL = request.deletingLastPathComponent()
            process.standardInput = FileHandle(fileDescriptor: input, closeOnDealloc: false)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle(fileDescriptor: writeEnd, closeOnDealloc: false)
            // Installed before `run()`, so an early exit is never missed;
            // cleared in `finish()`, and here when the start fails, so it never
            // keeps this runner alive.
            process.terminationHandler = { [self] ended in
                let termination: Termination = ended.terminationReason == .uncaughtSignal
                    ? .signalled(ended.terminationStatus)
                    : .exited(ended.terminationStatus)
                queue.async { self.exited(termination) }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                close(readEnd)
                close(writeEnd)
                throw .couldNotStart
            }
            close(writeEnd)
            processIdentifier = process.processIdentifier
            startedAt = clock.now
            lastProgressAt = startedAt
            _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: queue)
            source.setEventHandler { [self] in readChunk(from: readEnd) }
            source.setCancelHandler { close(readEnd) }
            stderrSource = source
            source.resume()
            startTimer(after: limits.pollInterval, repeating: limits.pollInterval) { [self] in poll() }
        }

        // MARK: - Stderr

        private func readChunk(from descriptor: Int32) {
            let (count, error) = readBuffer.withUnsafeMutableBytes { buffer in
                (read(descriptor, buffer.baseAddress, buffer.count), errno)
            }
            if count < 0, error == EAGAIN || error == EINTR { return }
            guard count > 0 else {
                // End of file, or a read error, which ends the pipe the same way.
                stderrAtEnd = true
                stderrSource?.cancel()
                stderrSource = nil
                if termination != nil { finish() }
                return
            }
            lineBuffer.append(contentsOf: readBuffer[0 ..< count])
            while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(bytes: lineBuffer[..<newline], encoding: .utf8)
                lineBuffer.removeSubrange(...newline)
                if let line, let parsed = LocalModelHelperLine.parse(line) { handle(parsed) }
            }
            if lineBuffer.count > Self.maxLineBytes { lineBuffer.removeAll() }
        }

        private func handle(_ line: LocalModelHelperLine) {
            if case let .prompt(tokens, context, output) = line {
                promptTokens = tokens
                onEvent(.prompt(tokens: tokens, contextLimit: context, outputLimit: output))
                return
            }
            lastProgressAt = clock.now
            if case let .writing(tokens) = line { tokensWritten = tokens }
            if let phase = line.phase, phase != self.phase {
                self.phase = phase
                onEvent(.phase(phase))
            }
        }

        // MARK: - Deadlines, stop, exit

        private func poll() {
            guard termination == nil, stopReason == nil else { return }
            let now = clock.now
            if startedAt.duration(to: now) >= limits.totalDeadline {
                requestStop(.deadline(.total))
            } else if lastProgressAt.duration(to: now) >= limits.noProgressDeadline {
                requestStop(.deadline(.noProgress))
            } else if let reason = watchdog() {
                requestStop(reason)
            }
        }

        private func requestStop(_ reason: LocalModelStopReason) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard termination == nil else { return }
            if let stopReason {
                if reason == .cancelled, stopReason != .cancelled { self.stopReason = reason }
                return
            }
            stopReason = reason
            onEvent(.stopping(reason))
            guard process.isRunning else { return }
            kill(processIdentifier, SIGTERM)
            startTimer(after: limits.killGrace) { [self] in
                guard termination == nil, process.isRunning else { return }
                kill(processIdentifier, SIGKILL)
                onEvent(.killed)
            }
        }

        private func exited(_ termination: Termination) {
            guard self.termination == nil else { return }
            self.termination = termination
            cancelTimers()
            if stderrAtEnd {
                finish()
            } else {
                startTimer(after: limits.drainAfterExit) { [self] in finish() }
            }
        }

        private func finish() {
            guard ending == nil, let termination else { return }
            cancelTimers()
            stderrSource?.cancel()
            stderrSource = nil
            process.terminationHandler = nil
            let ending = Ending(
                termination: termination,
                stopReason: stopReason,
                promptTokens: promptTokens,
                tokensWritten: tokensWritten,
                elapsed: startedAt.duration(to: clock.now),
            )
            self.ending = ending
            continuation?.resume(returning: ending)
            continuation = nil
        }

        private func startTimer(after delay: Duration, repeating interval: Duration? = nil, _ handler: @escaping @Sendable () -> Void) {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + delay.dispatchSeconds, repeating: interval?.dispatchSeconds ?? .infinity)
            timer.setEventHandler(handler: handler)
            timers.append(timer)
            timer.resume()
        }

        private func cancelTimers() {
            timers.forEach { $0.cancel() }
            timers.removeAll()
        }
    }

    fileprivate extension Duration {
        /// The duration in seconds, for Dispatch's interfaces.
        var dispatchSeconds: Double {
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }

#endif
