import Darwin
import Foundation
import os

/// Why a run was ended on request.
enum TerminationCause: String, Sendable {
    case sigterm
    /// The parent process exited (watched with a kqueue process source).
    case parentGone = "parent-gone"
    /// Standard input ended before a request arrived, which only happens when
    /// the parent went away before writing it.
    case stdinClosed = "stdin-closed"
}

/// The step a failed run failed in.
enum FailureStep: String, Sendable {
    case usage
    case badRequest = "bad-request"
    case template
    case outputFile = "output-file"
    case load
    case generation
}

/// One line the helper writes to stderr.
///
/// Every value in a line is a number or a fixed word declared in this file, and
/// no case takes a free-form string, so no line can carry prompt or protocol
/// text. Progress lines reset the app's no-progress deadline; lifecycle lines
/// are for its diagnostics.
enum StderrLine: Equatable, Sendable {
    /// Written once the SIGTERM handler and the parent watch are in place.
    case started
    /// The rendered prompt's size, before the context check.
    case prompt(tokens: Int, contextLimit: Int, outputLimit: Int)
    /// The weights start loading.
    case loading
    /// Prompt chunk `chunk` of `total` has been read into the cache.
    case prefill(chunk: Int, total: Int)
    /// `tokens` output tokens have been written and synced.
    case writing(tokens: Int)
    /// The last line before the process exits with `status`.
    case exited(ExitStatus, Detail?)

    enum Detail: Equatable, Sendable {
        case cause(TerminationCause)
        case failed(FailureStep)
        case problems(Int)
    }

    var text: String {
        switch self {
        case .started:
            "lifecycle event=started"

        case let .prompt(tokens, contextLimit, outputLimit):
            "lifecycle event=prompt tokens=\(tokens) context=\(contextLimit) output=\(outputLimit)"

        case .loading:
            "progress phase=loading"

        case let .prefill(chunk, total):
            "progress phase=prefill chunk=\(chunk) total=\(total)"

        case let .writing(tokens):
            "progress phase=writing tokens=\(tokens)"

        case let .exited(status, detail):
            "lifecycle event=exit status=\(status.rawValue) reason=\(status.reason)" + Self.suffix(detail)
        }
    }

    private static func suffix(_ detail: Detail?) -> String {
        switch detail {
        case nil: ""
        case let .cause(cause): " cause=\(cause.rawValue)"
        case let .failed(step): " error=\(step.rawValue)"
        case let .problems(count): " problems=\(count)"
        }
    }
}

enum HelperLog {
    /// One line per write(2), under a lock, so lines from the generation
    /// thread and the termination queue never interleave.
    private static let lock = OSAllocatedUnfairLock()

    static func write(_ line: StderrLine) {
        let data = Data((line.text + "\n").utf8)
        lock.withLock { Console.write(data, to: STDERR_FILENO) }
    }
}

/// Unbuffered output on the standard descriptors, so nothing waits in a stdio
/// buffer when the process ends with `_exit`.
enum Console {
    static func out(_ line: String) {
        write(Data((line + "\n").utf8), to: STDOUT_FILENO)
    }

    static func error(_ line: String) {
        write(Data((line + "\n").utf8), to: STDERR_FILENO)
    }

    /// Writes all of `data`, retrying short writes and EINTR. Other errors drop
    /// the rest: a reader that went away (EPIPE, SIGPIPE is ignored) must not
    /// stop the helper from reaching its own exit.
    static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                pointer += written
            }
        }
    }
}

enum HelperExit {
    /// Writes the exit line and ends the process at once. `_exit` skips atexit
    /// handlers and C++ static destructors, which must not run while MLX may
    /// still have work in flight on other threads. Everything the helper
    /// writes is unbuffered, and the output file is synced by its owner first.
    static func now(_ status: ExitStatus, _ detail: StderrLine.Detail? = nil) -> Never {
        HelperLog.write(.exited(status, detail))
        _exit(status.rawValue)
    }
}
