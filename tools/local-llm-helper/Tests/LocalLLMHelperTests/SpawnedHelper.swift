import Darwin
import Foundation
import os
import XCTest

/// Where the helper executable is when tests run.
enum HelperBinary {
    /// The build `swift test` makes next to the test bundle.
    static var built: URL {
        let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        let directory = bundle?.bundleURL.deletingLastPathComponent() ?? URL(fileURLWithPath: ".build/debug")
        return directory.appendingPathComponent("local-llm-helper")
    }

    /// The release build, which only `swift build -c release` makes.
    static var release: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/release/local-llm-helper")
    }
}

/// A child process with its three standard descriptors on pipes, reaped with
/// wait4(2) so its exit status and peak resident memory can be read. Foundation's
/// `Process` reaps its child itself and exposes neither the memory nor a way to
/// keep standard input open without writing to it.
final class SpawnedHelper {
    struct Ending {
        /// The exit status, or nil when a signal ended the process.
        let status: Int32?
        let signal: Int32?
        /// ru_maxrss, which macOS reports in bytes.
        let peakResidentBytes: Int
    }

    let pid: pid_t
    let stdout: PipeReader
    let stderr: PipeReader
    private var stdinDescriptor: Int32

    init(_ executable: String, _ arguments: [String]) throws {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else { throw POSIXError(.EMFILE) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child, so a pipe of a test
        // running in parallel can never hold this child's input open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environment)
        close(input[0])
        close(output[1])
        close(errors[1])
        guard result == 0 else {
            close(input[1])
            close(output[0])
            close(errors[0])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
        self.pid = pid
        stdinDescriptor = input[1]
        stdout = PipeReader(descriptor: output[0])
        stderr = PipeReader(descriptor: errors[0])
    }

    deinit {
        closeStdin()
        if wait4(pid, nil, WNOHANG, nil) == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, nil, 0)
        }
    }

    func send(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(stdinDescriptor, base + offset, buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    func closeStdin() {
        if stdinDescriptor >= 0 { close(stdinDescriptor) }
        stdinDescriptor = -1
    }

    /// Waits for the process to end. On timeout, or as soon as `abort` holds,
    /// kills it and returns nil.
    func waitForEnding(timeout: TimeInterval = 30, abort: () -> Bool = { false }) -> Ending? {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var usage = rusage()
        while Date() < deadline, !abort() {
            if wait4(pid, &status, WNOHANG, &usage) == pid {
                let signal = status & 0x7F
                return Ending(
                    status: signal == 0 ? (status >> 8) & 0xFF : nil,
                    signal: signal == 0 ? nil : signal,
                    peakResidentBytes: Int(usage.ru_maxrss),
                )
            }
            usleep(20000)
        }
        kill(pid, SIGKILL)
        waitpid(pid, nil, 0)
        return nil
    }
}

/// Reads one pipe to its end on a background thread.
final class PipeReader: Sendable {
    private let buffer = OSAllocatedUnfairLock(initialState: (data: Data(), ended: false))

    init(descriptor: Int32) {
        Thread.detachNewThread { [buffer] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(descriptor, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                let bytes = Data(chunk[0 ..< count])
                buffer.withLock { $0.data.append(bytes) }
            }
            close(descriptor)
            buffer.withLock { $0.ended = true }
        }
    }

    var text: String {
        buffer.withLock { String(bytes: $0.data, encoding: .utf8) ?? "" }
    }

    /// Waits until the text contains `fragment`; false on timeout or when the
    /// pipe ended without it.
    func waitFor(_ fragment: String, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (text, ended) = buffer.withLock { (String(bytes: $0.data, encoding: .utf8) ?? "", $0.ended) }
            if text.contains(fragment) { return true }
            if ended { return false }
            usleep(20000)
        }
        return false
    }

    /// Waits until every writer has closed the pipe.
    func waitForEnd(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buffer.withLock({ $0.ended }) { return true }
            usleep(20000)
        }
        return false
    }
}
