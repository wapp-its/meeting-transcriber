#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CLIProcessRunner")

    /// Starts one command-line program for a protocol provider and collects
    /// what it prints. The program gets a fixed argument vector through
    /// `Process`, never a shell, in the working directory and environment it
    /// is given, with optional bytes on stdin. `run` returns its exit status
    /// with stdout and stderr and never interprets either.
    ///
    /// The pipes are read and written by dispatch sources on a serial queue
    /// of the run's own, so no thread of Swift's cooperative pool ever waits
    /// on a pipe, and every source and parent-side pipe end is released
    /// before `run` returns. A background process the program leaves behind
    /// holding a pipe open therefore neither holds up the run nor outlives it
    /// on this side.
    enum CLIProcessRunner {
        /// Wall-clock limit for one run of any CLI provider.
        static let defaultTimeout: TimeInterval = 600
        static let defaultMaxStdoutBytes = 32 << 20
        static let defaultMaxStderrBytes = 1 << 20
        /// How long the pipes may stay open once the program has exited.
        static let drainAfterExit: TimeInterval = 2
        /// How long a program that was sent SIGTERM has before SIGKILL.
        static let killGrace: TimeInterval = 1

        /// Install locations of CLI tools. App bundles inherit a minimal
        /// `PATH`, so these are searched and prepended to the child's `PATH`.
        static let searchPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "/opt/homebrew/bin",
        ]

        struct Request: Sendable {
            let executable: URL
            let arguments: [String]
            let environment: [String: String]
            let workingDirectory: URL
            /// Written to the program's stdin, which is then closed; nil
            /// connects stdin to `/dev/null`.
            let standardInput: Data?
            let timeout: TimeInterval
            /// More stdout than this stops the program and fails the run.
            let maxStdoutBytes: Int
            /// Stderr beyond this is read and discarded.
            let maxStderrBytes: Int

            init(
                executable: URL,
                arguments: [String],
                environment: [String: String],
                workingDirectory: URL,
                standardInput: Data?,
                timeout: TimeInterval,
                maxStdoutBytes: Int = CLIProcessRunner.defaultMaxStdoutBytes,
                maxStderrBytes: Int = CLIProcessRunner.defaultMaxStderrBytes,
            ) {
                self.executable = executable
                self.arguments = arguments
                self.environment = environment
                self.workingDirectory = workingDirectory
                self.standardInput = standardInput
                self.timeout = timeout
                self.maxStdoutBytes = maxStdoutBytes
                self.maxStderrBytes = maxStderrBytes
            }
        }

        struct Output: Sendable, Equatable {
            /// `Process.terminationStatus`.
            let status: Int32
            let stdout: Data
            let stderr: Data
        }

        enum Failure: Error, Equatable {
            /// The program could not be started; carries the launch error's
            /// description, nothing the program printed.
            case couldNotStart(String)
            case timedOut
            case stdoutTooLarge
        }

        /// `base` with `CLAUDECODE` removed (a nested Claude CLI would take
        /// itself for an embedded session) and `searchPaths` prepended to
        /// `PATH`.
        static func environment(base: [String: String], searchPaths: [String] = Self.searchPaths) -> [String: String] {
            var environment = base
            environment.removeValue(forKey: "CLAUDECODE")
            let extraPaths = searchPaths.joined(separator: ":")
            environment["PATH"] = "\(extraPaths):\(environment["PATH"] ?? "/usr/bin:/bin")"
            return environment
        }

        /// Create a new, empty, owner-only (`0700`) directory under `parent`
        /// for one CLI run, and return it. The caller starts the program
        /// there and removes the directory when the run ends.
        ///
        /// Without a working directory of its own the child inherits the
        /// app's, which for a launched app is `/`, and a CLI that looks
        /// around its working directory at startup makes macOS ask the user
        /// for Desktop, Documents, Downloads and iCloud Drive on the app's
        /// behalf. The default parent is the per-user temporary directory,
        /// which is private to the user and has no privacy-protected folder
        /// on its path or beneath it.
        ///
        /// A new directory per run, not one shared folder, so a run never
        /// sees what an earlier or concurrent run left there. The name is
        /// unique and creation fails rather than reuse a directory that
        /// already exists. Throws when the directory cannot be created;
        /// there is deliberately no fallback to the inherited directory.
        static func makeRunDirectory(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
            let directory = parent.appendingPathComponent("MeetingTranscriber-cli-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700],
            )
            return directory
        }

        /// Run `request` to its end. One deadline, `request.timeout`, covers
        /// the program's exit and the reads: when it passes first the
        /// program gets SIGTERM, then SIGKILL `killGrace` later if it is
        /// still running, and the run throws `.timedOut` without waiting for
        /// either. Stdout beyond its cap stops the program the same way and
        /// throws `.stdoutTooLarge`. Once the program has exited the pipes
        /// get at most `drainAfterExit` more to reach end-of-file; what was
        /// read by then is returned. The stdin writer is never waited for.
        static func run(_ request: Request) async throws -> Output {
            let run = Run(request: request)
            return try await withCheckedThrowingContinuation { continuation in
                run.start(continuation)
            }
        }
    }

    extension CLIProcessRunner {
        /// One run. Its state is touched only on `queue`, which is what makes
        /// sharing it between the caller, the termination handler and the
        /// dispatch sources safe.
        private final class Run: @unchecked Sendable {
            private enum Channel {
                case stdout, stderr
            }

            private typealias PipeEnds = (read: Int32, write: Int32)

            private let request: Request
            private let queue = DispatchQueue(label: "com.meetingtranscriber.cli-process-runner")
            private let process = Process()
            private var continuation: CheckedContinuation<Output, any Error>?
            private var result: Result<Output, Failure>?
            private var stdout = Data()
            private var stderr = Data()
            private var stdoutAtEnd = false
            private var stderrAtEnd = false
            private var exitStatus: Int32?
            private var bytesWritten = 0
            /// Open pipe sources by descriptor; each one's cancel handler
            /// closes its descriptor and removes it.
            private var sources: [Int32: any DispatchSourceProtocol] = [:]
            private var timers: [any DispatchSourceTimer] = []
            private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

            init(request: Request) {
                self.request = request
            }

            func start(_ continuation: CheckedContinuation<Output, any Error>) {
                queue.async { [self] in
                    self.continuation = continuation
                    launch()
                }
            }

            // MARK: - Launch

            private func launch() {
                dispatchPrecondition(condition: .onQueue(queue))
                let pipes: [PipeEnds]
                do throws(Failure) {
                    pipes = try Self.makePipes(count: request.standardInput == nil ? 2 : 3)
                } catch {
                    finish(.failure(error))
                    return
                }
                let (output, errors) = (pipes[0], pipes[1])
                let input = pipes.count > 2 ? pipes[2] : nil
                let childEnds = [output.write, errors.write] + (input.map { [$0.read] } ?? [])
                let parentEnds = [output.read, errors.read] + (input.map { [$0.write] } ?? [])
                // A program that exits without reading its input must make the
                // write fail with EPIPE, not kill the app with SIGPIPE.
                if let input { _ = fcntl(input.write, F_SETNOSIGPIPE, 1) }

                process.executableURL = request.executable
                process.arguments = request.arguments
                process.environment = request.environment
                process.currentDirectoryURL = request.workingDirectory
                process.standardOutput = FileHandle(fileDescriptor: output.write, closeOnDealloc: false)
                process.standardError = FileHandle(fileDescriptor: errors.write, closeOnDealloc: false)
                process.standardInput = input.map { FileHandle(fileDescriptor: $0.read, closeOnDealloc: false) }
                    ?? FileHandle.nullDevice
                // Installed before `run()`, so an early exit is never missed.
                process.terminationHandler = { [self] ended in
                    let status = ended.terminationStatus
                    queue.async { self.programExited(status: status) }
                }
                do {
                    try process.run()
                } catch {
                    (childEnds + parentEnds).forEach { close($0) }
                    finish(.failure(.couldNotStart(error.localizedDescription)))
                    return
                }
                childEnds.forEach { close($0) }

                for descriptor in parentEnds {
                    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                }
                watch(output.read, channel: .stdout)
                watch(errors.read, channel: .stderr)
                if let input, let data = request.standardInput { feed(data, into: input.write) }
                startTimer(after: request.timeout) { [self] in deadlinePassed() }
            }

            /// `count` pipes; on failure, every descriptor already made is
            /// closed again.
            private static func makePipes(count: Int) throws(Failure) -> [PipeEnds] {
                var pipes: [PipeEnds] = []
                for _ in 0 ..< count {
                    var descriptors: [Int32] = [-1, -1]
                    guard pipe(&descriptors) == 0 else {
                        let reason = String(cString: strerror(errno))
                        pipes.forEach { close($0.read); close($0.write) }
                        throw .couldNotStart(reason)
                    }
                    pipes.append((descriptors[0], descriptors[1]))
                }
                return pipes
            }

            // MARK: - Pipes

            private func watch(_ descriptor: Int32, channel: Channel) {
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [self] in readChunk(from: descriptor, channel: channel) }
                adopt(source, for: descriptor)
            }

            private func feed(_ data: Data, into descriptor: Int32) {
                guard !data.isEmpty else {
                    close(descriptor)
                    return
                }
                let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [self] in writeChunk(of: data, to: descriptor) }
                adopt(source, for: descriptor)
            }

            private func adopt(_ source: any DispatchSourceProtocol, for descriptor: Int32) {
                source.setCancelHandler { [self] in
                    close(descriptor)
                    sources[descriptor] = nil
                    resumeOnceReleased()
                }
                sources[descriptor] = source
                source.resume()
            }

            /// One read per event, so a program that keeps a pipe full cannot
            /// keep the queue from running the deadline.
            private func readChunk(from descriptor: Int32, channel: Channel) {
                let (count, error) = readBuffer.withUnsafeMutableBytes { buffer in
                    (read(descriptor, buffer.baseAddress, buffer.count), errno)
                }
                if count < 0, error == EAGAIN || error == EINTR { return }
                guard count > 0 else {
                    // End of file, or a read error, which ends the pipe the same way.
                    reachedEnd(of: channel, descriptor: descriptor)
                    return
                }
                let chunk = readBuffer[0 ..< count]
                switch channel {
                case .stdout:
                    guard stdout.count + count <= request.maxStdoutBytes else {
                        stopProgram()
                        finish(.failure(.stdoutTooLarge))
                        return
                    }
                    stdout.append(contentsOf: chunk)

                case .stderr:
                    stderr.append(contentsOf: chunk.prefix(max(0, request.maxStderrBytes - stderr.count)))
                }
            }

            /// One write per event; the last one, or a failed one, closes stdin.
            private func writeChunk(of data: Data, to descriptor: Int32) {
                let (written, error) = data.withUnsafeBytes { bytes -> (Int, Int32) in
                    guard let base = bytes.baseAddress else { return (0, 0) }
                    return (write(descriptor, base + bytesWritten, bytes.count - bytesWritten), errno)
                }
                if written > 0 {
                    bytesWritten += written
                    if bytesWritten < data.count { return }
                } else if error == EAGAIN || error == EINTR {
                    return
                } else {
                    logger.debug("cli_stdin_write_failed errno=\(error, privacy: .public)")
                }
                sources[descriptor]?.cancel()
            }

            private func reachedEnd(of channel: Channel, descriptor: Int32) {
                switch channel {
                case .stdout: stdoutAtEnd = true

                case .stderr: stderrAtEnd = true
                }
                sources[descriptor]?.cancel()
                if stdoutAtEnd, stderrAtEnd, exitStatus != nil { finishWithWhatWasRead() }
            }

            // MARK: - Exit, deadline, end

            private func programExited(status: Int32) {
                process.terminationHandler = nil
                guard result == nil else { return }
                exitStatus = status
                if stdoutAtEnd, stderrAtEnd {
                    finishWithWhatWasRead()
                    return
                }
                startTimer(after: CLIProcessRunner.drainAfterExit) { [self] in finishWithWhatWasRead() }
            }

            private func deadlinePassed() {
                guard exitStatus == nil else {
                    finishWithWhatWasRead()
                    return
                }
                stopProgram()
                finish(.failure(.timedOut))
            }

            private func finishWithWhatWasRead() {
                guard let exitStatus else { return }
                finish(.success(Output(status: exitStatus, stdout: stdout, stderr: stderr)))
            }

            /// SIGTERM now, SIGKILL `killGrace` later if the program is still
            /// running. Neither is waited for.
            private func stopProgram() {
                guard process.isRunning else { return }
                process.terminate()
                let process = process
                DispatchQueue.global().asyncAfter(deadline: .now() + CLIProcessRunner.killGrace) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }

            private func startTimer(after seconds: TimeInterval, handler: @escaping @Sendable () -> Void) {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + seconds)
                timer.setEventHandler(handler: handler)
                timers.append(timer)
                timer.resume()
            }

            /// Records the outcome and cancels every timer and pipe source;
            /// the caller is resumed once the last source has closed its
            /// descriptor.
            private func finish(_ outcome: Result<Output, Failure>) {
                dispatchPrecondition(condition: .onQueue(queue))
                guard result == nil else { return }
                result = outcome
                timers.forEach { $0.cancel() }
                timers.removeAll()
                sources.values.forEach { $0.cancel() }
                resumeOnceReleased()
            }

            private func resumeOnceReleased() {
                guard let result, sources.isEmpty, let continuation else { return }
                self.continuation = nil
                continuation.resume(with: result)
            }
        }
    }

#endif
