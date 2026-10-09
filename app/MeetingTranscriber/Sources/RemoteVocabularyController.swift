import Foundation
import Observation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RemoteVocabulary")

/// Keeps the URL source's downloaded copy current and says what Settings shows
/// about it. `AppState` owns it as `remoteVocabulary`.
///
/// - **Nothing happens before `start()`.** `AppState` is built by many unit
///   tests, and `start()` deletes this bundle's copies for every address but
///   the configured one; with a test's empty address that would be the user's
///   real copy. So `init` only stores its inputs, and the menu-bar `.task`
///   calls `start()`.
/// - **When it checks:** at `start()`, `debounce` after the source, address or
///   token last changed, on `refreshNow()`, and every `interval`, only while
///   the source is `.url` and the address valid, and never two at once.
/// - **Generations.** Every change of source, address or token starts a new
///   generation and cancels the check in flight. A result that still arrives
///   for an older generation is dropped, so a copy fetched for one address
///   never lands after the address changed.
/// - **Adopting.** A download is validated like the local file and stored only
///   when it differs from the cached text. A 304 or an identical body rewrites
///   only the sidecar, so the engines do not prepare unchanged terms again. A
///   failed check keeps the copy.
/// - **The status names the copy the engines read.** The copy a failure
///   reports is whatever `RemoteVocabularyCache.load(for:)` returns after it,
///   never a value remembered in memory.
@MainActor
@Observable
final class RemoteVocabularyController {
    /// What one finished check did, as its log line reports it.
    enum CheckOutcome: Equatable {
        /// A new text was stored.
        case updated(termCount: Int, at: Date)
        /// The server confirmed the copy: a 304, or the same text again.
        case unchanged(termCount: Int, updatedAt: Date, checkedAt: Date)
        case failed(RemoteVocabularyFailure)
    }

    private(set) var status: RemoteVocabularyStatus = .inactive
    private(set) var isChecking = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let fetcher: any RemoteVocabularyFetching
    @ObservationIgnored private let cache: RemoteVocabularyCache
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = 0
    /// The normalized address whose copy is kept.
    @ObservationIgnored private var keptAddress = ""
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        fetcher: any RemoteVocabularyFetching = RemoteVocabularyFetcher(),
        debounce: Duration = .seconds(2),
        interval: Duration = .seconds(60 * 60),
        now: @escaping () -> Date = { Date() },
    ) {
        self.settings = settings
        self.fetcher = fetcher
        self.cache = settings.remoteVocabularyCache
        self.debounce = debounce
        self.interval = interval
        self.now = now
    }

    /// Deletes this bundle's copies for other addresses, repairs the copy for
    /// the configured one, publishes the status, then checks at once and every
    /// `interval`. A second call does nothing.
    func start() {
        guard !started else { return }
        started = true
        keptAddress = currentAddress
        cache.discardAll(except: keptAddress)
        status = idleStatus()
        observeSettings()
        beginCheck()
        // `Task.sleep(for:)` runs on the continuous clock, so a check that came
        // due while the Mac slept runs right after wake.
        Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.beginCheck()
            }
        }
    }

    /// "Update now". Does nothing while a check runs, with the local-file
    /// source or an invalid address; otherwise it replaces a pending check.
    func refreshNow() {
        beginCheck()
    }

    /// The public part of a check's log line: the outcome and the HTTP status
    /// of the answer, "none" when no answer arrived. Built from these two values
    /// alone, so neither the address, the token nor a term can reach it.
    static func logDescription(of outcome: CheckOutcome, result: RemoteVocabularyFetchResult) -> String {
        let httpStatus = switch result {
        case .modified: "200"
        case .notModified: "304"
        case let .failed(.httpStatus(code)): "\(code)"
        case .failed: "none"
        }
        let what = switch outcome {
        case .updated: "updated"
        case .unchanged: "unchanged"
        case let .failed(failure): "failed (\(failure.message))"
        }
        return "\(what), HTTP \(httpStatus)"
    }

    // MARK: - Private

    private var currentAddress: String {
        RemoteVocabulary.normalizedAddress(settings.remoteVocabularyURL)
    }

    /// The status while no check runs. A copy whose sidecar was not trusted
    /// has no check time, so it shows as being checked: whenever this is
    /// computed with the URL source and a valid address, a check is due.
    private func idleStatus() -> RemoteVocabularyStatus {
        guard settings.vocabularySource == .url else { return .inactive }
        if case let .failure(problem) = RemoteVocabulary.validateAddress(settings.remoteVocabularyURL) {
            return .addressProblem(problem)
        }
        guard let copy = cache.load(for: currentAddress) else { return .notDownloaded }
        guard let checkedAt = copy.checkedAt else { return .checking }
        return .current(termCount: copy.termCount, updatedAt: copy.updatedAt, checkedAt: checkedAt)
    }

    /// `withObservationTracking` fires once per registration, so each change
    /// re-arms it (the `EngineController` pattern).
    private func observeSettings() {
        withObservationTracking {
            _ = settings.vocabularySource
            _ = settings.remoteVocabularyURL
            _ = settings.remoteVocabularyTokenRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    /// Starts a new generation: the check in flight and a pending one are
    /// dropped, copies for an address no longer configured are deleted (the
    /// engines already read only the new address's file), and a check follows
    /// `debounce` after the last change.
    private func settingsChanged() {
        generation += 1
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        debounceTask?.cancel()
        debounceTask = nil
        let address = currentAddress
        if address != keptAddress {
            keptAddress = address
            cache.discardAll(except: address)
        }
        status = idleStatus()
        guard settings.vocabularySource == .url,
              case .success = RemoteVocabulary.validateAddress(settings.remoteVocabularyURL)
        else { return }
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.beginCheck()
        }
    }

    private func beginCheck() {
        guard !isChecking, settings.vocabularySource == .url,
              case let .success(url) = RemoteVocabulary.validateAddress(settings.remoteVocabularyURL)
        else { return }
        debounceTask?.cancel()
        debounceTask = nil
        let checkGeneration = generation
        let address = currentAddress
        let token = settings.remoteVocabularyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read again for every check: the load is what drops validators that
        // no longer describe the text on disk.
        let copy = cache.load(for: address)
        isChecking = true
        status = .checking
        checkTask = Task { [weak self, fetcher] in
            let result = await fetcher.fetch(url: url, token: token.isEmpty ? nil : token, validators: copy?.validators)
            guard let self, !Task.isCancelled, self.generation == checkGeneration else { return }
            self.finish(result, address: address, copy: copy, host: url.host(percentEncoded: false) ?? "")
        }
    }

    private func finish(_ result: RemoteVocabularyFetchResult, address: String, copy: RemoteVocabularyCopy?, host: String) {
        checkTask = nil
        isChecking = false
        let outcome = adopt(result, address: address, copy: copy)
        switch outcome {
        case let .updated(termCount, at):
            status = .current(termCount: termCount, updatedAt: at, checkedAt: at)

        case let .unchanged(termCount, updatedAt, checkedAt):
            status = .current(termCount: termCount, updatedAt: updatedAt, checkedAt: checkedAt)

        case let .failed(failure):
            let lastGood = cache.load(for: address).map { copy in
                RemoteVocabularyCopyInfo(termCount: copy.termCount, updatedAt: copy.updatedAt)
            }
            status = .failed(failure, lastGood: lastGood)
        }
        logger.notice(
            "Remote vocabulary check: \(Self.logDescription(of: outcome, result: result), privacy: .public), host \(host, privacy: .private)",
        )
    }

    private func adopt(_ result: RemoteVocabularyFetchResult, address: String, copy: RemoteVocabularyCopy?) -> CheckOutcome {
        let checkedAt = now()
        switch result {
        case let .failed(failure):
            return .failed(failure)

        case .notModified:
            // A 304 can only confirm a copy whose validators were sent.
            guard let copy, let validators = copy.validators else { return .failed(.unexpectedNotModified) }
            return confirm(copy, validators: validators, address: address, checkedAt: checkedAt)

        case let .modified(body, validators):
            let validation = CustomVocabularyValidation.validate(data: body)
            guard case let .ready(termCount) = validation else { return .failed(.invalidContent(validation)) }
            if let copy, copy.data == body {
                return confirm(copy, validators: validators, address: address, checkedAt: checkedAt)
            }
            let metadata = RemoteVocabularyMetadata(
                url: address,
                etag: validators?.etag,
                lastModified: validators?.lastModified,
                updatedAt: checkedAt,
                checkedAt: checkedAt,
            )
            do {
                try cache.store(body, metadata: metadata)
            } catch {
                return .failed(.couldNotSave)
            }
            return .updated(termCount: termCount, at: checkedAt)
        }
    }

    /// Records that the server confirmed `copy`; only the sidecar is written,
    /// and the content's update time is kept.
    private func confirm(
        _ copy: RemoteVocabularyCopy, validators: RemoteVocabularyValidators?, address: String, checkedAt: Date,
    ) -> CheckOutcome {
        let metadata = RemoteVocabularyMetadata(
            url: address,
            etag: validators?.etag,
            lastModified: validators?.lastModified,
            updatedAt: copy.updatedAt,
            checkedAt: checkedAt,
        )
        do {
            try cache.updateMetadata(metadata, describing: copy.data)
        } catch {
            return .failed(.couldNotSave)
        }
        return .unchanged(termCount: copy.termCount, updatedAt: copy.updatedAt, checkedAt: checkedAt)
    }
}
