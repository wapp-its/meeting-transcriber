import Darwin
import Dispatch
import os

/// Ends a run on request: SIGTERM from the app, or the app being gone.
///
/// Before generation starts nothing has been written, so a request ends the
/// process at once, whatever it is doing (reading stdin, loading weights).
/// While generation runs, a request cancels it; mlx-swift-lm checks for that
/// between prompt chunks and between tokens, and the run then flushes what it
/// wrote and exits with `ExitStatus.terminated`. After generation a request is
/// ignored, because the process is already on its way out with its own status.
final class Termination: Sendable {
    static let shared = Termination()

    private struct State {
        var cause: TerminationCause?
        var cancelGeneration: (@Sendable () -> Void)?
        var generationOver = false
    }

    private enum Action {
        case exitNow
        case cancel(@Sendable () -> Void)
        case ignore
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "local-llm-helper.termination")
    /// Dispatch sources stop when released, so they are kept for the
    /// process's lifetime. They are only appended to, never handed out.
    private let sources = OSAllocatedUnfairLock<[any DispatchSourceProtocol]>(uncheckedState: [])

    /// SIGTERM is ignored as a signal and handled on `queue` instead, where it
    /// may take a lock and write a line, which a signal handler may not.
    func handleSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [self] in request(.sigterm) }
        keep(source)
    }

    /// Watches the parent process with a kqueue `NOTE_EXIT` source. A parent
    /// that died before the source was armed has already handed this process
    /// to launchd, which the second `getppid()` notices.
    func watchParent() {
        let parent = getppid()
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in request(.parentGone) }
        keep(source)
        if parent == 1 || getppid() != parent { request(.parentGone) }
    }

    func request(_ cause: TerminationCause) {
        let action = state.withLock { state -> Action in
            if state.generationOver { return .ignore }
            if state.cause == nil { state.cause = cause }
            if let cancel = state.cancelGeneration { return .cancel(cancel) }
            return .exitNow
        }
        switch action {
        case .exitNow: HelperExit.now(.terminated, .cause(cause))
        case let .cancel(cancel): cancel()
        case .ignore: break
        }
    }

    /// From here on a request cancels through `cancel` instead of exiting.
    /// Returns false when a request already arrived, in which case the caller
    /// must not start.
    func beginGeneration(cancel: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard state.cause == nil else { return false }
            state.cancelGeneration = cancel
            return true
        }
    }

    /// Ends the cancellable phase and returns the request that arrived during
    /// it, if any.
    func endGeneration() -> TerminationCause? {
        state.withLock { state in
            state.generationOver = true
            state.cancelGeneration = nil
            return state.cause
        }
    }

    private func keep(_ source: any DispatchSourceProtocol) {
        sources.withLockUnchecked { $0.append(source) }
        source.resume()
    }
}
