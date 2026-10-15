import Foundation
import Observation

/// State of the Hugging Face model browser: the query, its results, the chosen
/// repository's listing and a one-line message. All of it lives here rather than
/// in the view, so a test holding this object reads what the view's actions wrote.
///
/// - **Searching.** A query change cancels the pending search and listing and
///   returns to the results. A trimmed query under `minimumQueryLength`
///   characters clears the results without a request; otherwise the search
///   runs after `debounce`, so typing sends one request per pause rather than
///   one per keystroke (anonymous Hub calls are limited to 500 per 5 minutes).
/// - **Stale answers.** A search's answer is applied only while the query it
///   ran for is still the current one, and a listing's only while its
///   repository is still the chosen one. Both are re-checked when the answer
///   arrives, together with the task's own cancellation, so an answer to work
///   that `cancel()` stopped is dropped as well.
/// - **The token** is read from `token` on every call, so a token saved in
///   Settings while the window is open applies to the next request.
/// - **Identifiable** with a fresh id per instance, so the presenter can open
///   each browser through `sheet(item:)` with a model of its own.
@MainActor
@Observable
final class HuggingFaceModelSearch: Identifiable {
    static let minimumQueryLength = 2

    let id = UUID()

    var query = "" {
        didSet { queryDidChange() }
    }

    private(set) var results: [HuggingFaceModelSummary] = []
    /// The chosen repository's variants, license and gated flag; nil while the
    /// results are shown.
    private(set) var listing: HuggingFaceRepositoryListing?
    /// A search is pending or running for the current query.
    private(set) var isSearching = false
    /// A listing is running for the chosen repository.
    private(set) var isListing = false
    /// No match, or why the last search or listing failed.
    private(set) var message: String?

    /// The pending or running search. Read by tests, which await it instead of sleeping.
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    /// The running listing. Read by tests, like `searchTask`.
    @ObservationIgnored private(set) var listingTask: Task<Void, Never>?

    @ObservationIgnored private let catalog: any HuggingFaceModelCataloging
    @ObservationIgnored private let token: @MainActor () -> String?
    @ObservationIgnored private let debounce: Duration
    /// The repository whose listing is awaited or shown.
    @ObservationIgnored private var chosenRepository: String?

    init(
        catalog: any HuggingFaceModelCataloging,
        token: @escaping @MainActor () -> String?,
        debounce: Duration = .milliseconds(350),
    ) {
        self.catalog = catalog
        self.token = token
        self.debounce = debounce
    }

    /// Lists `summary`'s repository, replacing any listing still awaited.
    func choose(_ summary: HuggingFaceModelSummary) {
        listingTask?.cancel()
        chosenRepository = summary.id
        listing = nil
        message = nil
        isListing = true
        let repoID = summary.id
        listingTask = Task { [weak self] in
            await self?.performListing(repoID)
        }
    }

    /// Returns from a repository to the results; an answer still awaited for it is dropped.
    func backToResults() {
        dropListing()
    }

    /// Stops the pending search and listing; the view calls it when the window closes.
    func cancel() {
        searchTask?.cancel()
        listingTask?.cancel()
        isSearching = false
        isListing = false
    }

    // MARK: - Searching

    private var currentSearchText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func queryDidChange() {
        searchTask?.cancel()
        searchTask = nil
        dropListing()
        let text = currentSearchText
        guard text.count >= Self.minimumQueryLength else {
            results = []
            message = nil
            isSearching = false
            return
        }
        isSearching = true
        let debounce = debounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.performSearch(text)
        }
    }

    private func performSearch(_ text: String) async {
        let outcome: Result<[HuggingFaceModelSummary], HuggingFaceCatalogError>
        do {
            outcome = try await .success(catalog.searchWhisperKitModels(matching: text, token: token()))
        } catch is CancellationError {
            // The query changed or the window closed, and whoever did that has
            // already set the state.
            return
        } catch {
            outcome = .failure(Self.catalogError(error))
        }
        guard !Task.isCancelled, text == currentSearchText else { return }
        isSearching = false
        switch outcome {
        case let .success(found):
            results = found
            message = found.isEmpty ? "No WhisperKit models match \"\(text)\"." : nil

        case let .failure(error):
            results = []
            message = error.message
        }
    }

    // MARK: - Listing

    private func dropListing() {
        listingTask?.cancel()
        listingTask = nil
        chosenRepository = nil
        listing = nil
        isListing = false
    }

    private func performListing(_ repoID: String) async {
        let outcome: Result<HuggingFaceRepositoryListing, HuggingFaceCatalogError>
        do {
            outcome = try await .success(catalog.repository(repoID, token: token()))
        } catch is CancellationError {
            return
        } catch {
            outcome = .failure(Self.catalogError(error))
        }
        guard !Task.isCancelled, repoID == chosenRepository else { return }
        isListing = false
        switch outcome {
        case let .success(found):
            listing = found

        case let .failure(error):
            chosenRepository = nil
            message = error.message
        }
    }

    /// The catalog throws only its own errors besides cancellation; anything
    /// else still ends the wait, as a failure to reach the Hub.
    private static func catalogError(_ error: any Error) -> HuggingFaceCatalogError {
        error as? HuggingFaceCatalogError ?? .unreachable
    }
}
