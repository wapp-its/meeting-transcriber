#if !APPSTORE

    import Foundation
    import os

    /// Runs mt-update for this app: the bounded `--check --porcelain`, the
    /// install in the background, whether a recorded install still runs, and
    /// which build this process is. The real `MtUpdateInstalling`; the
    /// sandboxed App Store build cannot start processes and has none of it.
    ///
    /// Both runs write stdout and stderr into a log file this app opens, never
    /// into a pipe: the install keeps writing after mt-update has quit this
    /// app, and a write to a pipe nobody reads would end it with SIGPIPE,
    /// possibly between deleting the old bundle and moving in the new one.
    struct MtUpdateProvider: MtUpdateInstalling {
        static let defaultCheckTimeout: TimeInterval = 300
        static let installLogName = "mt-update.log"
        static let checkLogName = "mt-update-check.log"
        /// How long mt-update's process group has between SIGTERM and SIGKILL
        /// once a check runs out of time.
        static let killGrace: TimeInterval = 1
        /// How often a stopped check looks whether its process group is gone.
        static let groupPollInterval: TimeInterval = 0.1

        let executableURL: URL
        let homeDirectory: URL
        let logDirectory: URL
        /// The environment the child's is built from; `MtUpdateEnvironment`
        /// drops its `MT_` variables and extends its `PATH`.
        let baseEnvironment: [String: String]
        let checkTimeout: TimeInterval
        /// This build's identity, read from its bundle at creation: stored as
        /// values, so the provider stays `Sendable` without holding a `Bundle`.
        private let gitCommitHash: String
        private let runningExecutableURL: URL?

        init(
            executableURL: URL,
            homeDirectory: URL,
            logDirectory: URL,
            baseEnvironment: [String: String],
            checkTimeout: TimeInterval = Self.defaultCheckTimeout,
            bundle: Bundle = .main,
        ) {
            self.executableURL = executableURL
            self.homeDirectory = homeDirectory
            self.logDirectory = logDirectory
            self.baseEnvironment = baseEnvironment
            self.checkTimeout = checkTimeout
            gitCommitHash = bundle.gitCommitHash
            runningExecutableURL = bundle.executableURL
        }

        /// The provider when this build takes its updates from mt-update
        /// (`MtUpdateSource.isActive`), nil otherwise. A path that cannot be
        /// read counts as no mt-update. `logDirectory` defaults to
        /// `PersistentDiagnosticLog.logDirectory`, read only when the provider
        /// is made, because reading it creates the folder.
        static func detect(
            fileManager: FileManager = .default,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            runningBundlePath: String = Bundle.main.bundleURL.path,
            logDirectory: URL? = nil,
        ) -> Self? {
            let executable = homeDirectory.appending(path: MtUpdateSource.executablePathInHome)
            guard MtUpdateSource.isActive(
                isAppStoreBuild: false,
                executableIsPresent: fileManager.isExecutableFile(atPath: executable.path),
                runningBundlePath: runningBundlePath,
            ) else { return nil }
            return Self(
                executableURL: executable,
                homeDirectory: homeDirectory,
                logDirectory: logDirectory ?? PersistentDiagnosticLog.logDirectory,
                baseEnvironment: ProcessInfo.processInfo.environment,
            )
        }

        var installLogPath: String {
            logDirectory.appendingPathComponent(Self.installLogName).path
        }

        var checkLogPath: String {
            logDirectory.appendingPathComponent(Self.checkLogName).path
        }

        func currentBuild() -> BuildIdentity {
            let modified = runningExecutableURL.flatMap { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            }
            return BuildIdentity(gitCommitHash: gitCommitHash, executableModified: modified)
        }

        // MARK: - Check

        /// Runs `mt-update --check --porcelain` for at most `checkTimeout`.
        /// A check that runs out of time returns only once mt-update's whole
        /// process group has ended, so no `git` it started is still working
        /// on mt-update's checkout or writing into the next check's log.
        func check() async -> MtUpdateCheckOutcome {
            let log: FileHandle
            do {
                log = try openLog(at: checkLogPath)
            } catch {
                return .failed(.notStartable(error.localizedDescription))
            }
            let process = makeProcess(arguments: ["--check", "--porcelain"], output: log)
            let run = await Self.runBounded(process, timeout: checkTimeout)
            try? log.close()
            switch run {
            case let .notStarted(reason):
                return .failed(.notStartable(reason))

            case .timedOut:
                return .failed(.timedOut)

            case let .exited(exit):
                let output = (try? Data(contentsOf: URL(fileURLWithPath: checkLogPath))) ?? Data()
                // Lossy, so one invalid byte in mt-update's other lines does
                // not lose the whole answer (hence not the failable initializer).
                // swiftlint:disable:next optional_data_string_conversion
                return MtUpdatePorcelain.parse(exit: exit, output: String(decoding: output, as: UTF8.self))
            }
        }

        private enum BoundedRun {
            case exited(MtUpdateExit)
            case timedOut
            case notStarted(String)
        }

        /// Starts `process` and waits for it, at most `timeout`. Then its
        /// process group (the child leads its own) gets SIGTERM, SIGKILL after
        /// `killGrace`, and the run returns once the group is empty. Whichever
        /// of exit and deadline comes first decides the result.
        private static func runBounded(_ process: Process, timeout: TimeInterval) async -> BoundedRun {
            await withCheckedContinuation { continuation in
                let decided = OSAllocatedUnfairLock(initialState: false)
                let decide: @Sendable () -> Bool = {
                    decided.withLock { done in
                        defer { done = true }
                        return !done
                    }
                }
                // Installed before `run()`, so an early exit is never missed.
                process.terminationHandler = { ended in
                    if decide() { continuation.resume(returning: .exited(MtUpdateExit(ended))) }
                }
                do {
                    try process.run()
                } catch {
                    if decide() { continuation.resume(returning: .notStarted(error.localizedDescription)) }
                    return
                }
                let group = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard decide() else { return }
                    kill(-group, SIGTERM)
                    awaitGroupEnd(group, killAt: .now() + killGrace) {
                        continuation.resume(returning: .timedOut)
                    }
                }
            }
        }

        /// Calls `done` once no process is left in `group`; from `killAt` on,
        /// each look sends the group SIGKILL first.
        private static func awaitGroupEnd(_ group: pid_t, killAt: DispatchTime, done: @escaping @Sendable () -> Void) {
            if kill(-group, 0) == -1, errno == ESRCH {
                done()
                return
            }
            if DispatchTime.now() >= killAt { kill(-group, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + groupPollInterval) {
                awaitGroupEnd(group, killAt: killAt, done: done)
            }
        }

        // MARK: - Install

        /// Starts mt-update's install mode, which outlives this app: nothing
        /// here signals it, and none of its standard streams is a pipe.
        /// `onExit` fires once if it ends while this app still runs. Throws
        /// when the log cannot be opened or the child cannot be launched.
        func startInstall(onExit: @escaping @Sendable (MtUpdateExit) -> Void) throws -> MtUpdateLaunch {
            let log = try openLog(at: installLogPath)
            // The child holds its own copy of the descriptor.
            defer { try? log.close() }
            let process = makeProcess(arguments: [], output: log)
            // Installed before `run()`, so an early exit is never missed.
            process.terminationHandler = { ended in onExit(MtUpdateExit(ended)) }
            try process.run()
            let pid = process.processIdentifier
            return MtUpdateLaunch(pid: pid, processStart: Self.startTime(of: pid))
        }

        // MARK: - Liveness

        /// True only while `launch.pid` is alive and, when the record has a
        /// start time, that process started at the same microsecond: a later
        /// process that reuses the ID never reads as mt-update.
        func isRunning(_ launch: MtUpdateLaunch) -> Bool {
            guard let started = Self.startTime(of: launch.pid) else { return false }
            guard let recorded = launch.processStart else { return true }
            return abs(recorded.timeIntervalSince(started)) < 0.000_000_5
        }

        /// When `pid` started, as the kernel records it, or nil when no such
        /// process exists. A missing pid answers success with size 0.
        private static func startTime(of pid: pid_t) -> Date? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let started = info.kp_proc.p_starttime
            return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
        }

        // MARK: - Child

        private func makeProcess(arguments: [String], output: FileHandle) -> Process {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = MtUpdateEnvironment.build(base: baseEnvironment, home: homeDirectory.path)
            process.currentDirectoryURL = homeDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            return process
        }

        /// A log could not be created or truncated.
        struct LogNotOpened: LocalizedError {
            let path: String
            let reason: String

            var errorDescription: String? {
                "cannot open \(path): \(reason)"
            }
        }

        /// Creates the log at `path` owner-only, or empties the existing one.
        private func openLog(at path: String) throws(LogNotOpened) -> FileHandle {
            // A failure here shows as the open's own error below.
            try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(FileManager.ownerOnlyPermissions))
            guard descriptor >= 0 else { throw LogNotOpened(path: path, reason: String(cString: strerror(errno))) }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
    }

    extension MtUpdateExit {
        /// How an ended `process` ended: by a signal, or with its exit code.
        init(_ process: Process) {
            self = process.terminationReason == .uncaughtSignal
                ? .signaled(process.terminationStatus)
                : .exited(process.terminationStatus)
        }
    }

#endif
