@testable import MeetingTranscriber
import XCTest

/// A catalog that answers from a script and records what it was asked. An answer
/// with a gate waits for the test to open it, and the wait ignores cancellation,
/// which is how a test delivers an answer late and in a known order.
@MainActor
final class FakeHuggingFaceCatalog: HuggingFaceModelCataloging {
    struct Call: Equatable {
        let argument: String
        let token: String?
    }

    /// Unscripted searches answer with no results.
    var searchAnswers: [String: Result<[HuggingFaceModelSummary], any Error>] = [:]
    /// Unscripted listings fail with `.notFound`.
    var listingAnswers: [String: Result<HuggingFaceRepositoryListing, any Error>] = [:]
    var searchGates: [String: MainActorGate] = [:]
    var listingGates: [String: MainActorGate] = [:]
    private(set) var searches: [Call] = []
    private(set) var listings: [Call] = []

    func searchWhisperKitModels(matching query: String, token: String?) async throws -> [HuggingFaceModelSummary] {
        searches.append(Call(argument: query, token: token))
        await searchGates[query]?.wait()
        return try (searchAnswers[query] ?? .success([])).get()
    }

    func repository(_ repoID: String, token: String?) async throws -> HuggingFaceRepositoryListing {
        listings.append(Call(argument: repoID, token: token))
        await listingGates[repoID]?.wait()
        return try (listingAnswers[repoID] ?? .failure(HuggingFaceCatalogError.notFound)).get()
    }
}

/// Search hits and listings shared by the search-model and browser-view tests.
enum HuggingFaceSearchSample {
    static let spert = HuggingFaceModelSummary(id: "spert/flix-swissgerman-whisperkit", downloads: 56)
    static let gcoli = HuggingFaceModelSummary(id: "gcoli/whisper-large-v3-swiss-german-coreml", downloads: nil)
    static let spertVariant = HuggingFaceModelVariant(name: "flix-swissgerman-large-v3_8bit", sizeBytes: 1_627_283_096)

    static func listing(
        _ summary: HuggingFaceModelSummary,
        variants: [HuggingFaceModelVariant] = [spertVariant],
        license: HuggingFaceLicense? = HuggingFaceLicense(identifier: "apache-2.0"),
        isGated: Bool = false,
    ) -> HuggingFaceRepositoryListing {
        HuggingFaceRepositoryListing(
            id: summary.id,
            variants: variants,
            license: license,
            isGated: isGated,
            // swiftlint:disable:next force_unwrapping
            modelCardURL: URL(string: "https://huggingface.co/\(summary.id)")!,
        )
    }
}

/// The token setting as the browser reads it, changeable between calls.
@MainActor
final class HuggingFaceTokenSource {
    var value: String?
}

/// The browser's search model against a fake catalog with no pause before
/// searching, unless a test is about the pause. Tests await the model's own
/// tasks instead of sleeping.
@MainActor
final class HuggingFaceModelSearchTests: XCTestCase {
    private typealias Sample = HuggingFaceSearchSample

    private func makeSearch(
        _ catalog: FakeHuggingFaceCatalog,
        token: HuggingFaceTokenSource = HuggingFaceTokenSource(),
        debounce: Duration = .zero,
    ) -> HuggingFaceModelSearch {
        HuggingFaceModelSearch(catalog: catalog, token: { token.value }, debounce: debounce)
    }

    // MARK: - Searching

    func testAQueryUnderTwoCharactersSendsNothingAndClearsResultsAndMessage() async {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["sw"] = .success([Sample.spert])
        let search = makeSearch(catalog)
        search.query = "sw"
        await search.searchTask?.value
        XCTAssertEqual(search.results, [Sample.spert], "precondition: results to clear")

        search.query = " s "
        await search.searchTask?.value
        XCTAssertEqual(search.results, [])
        XCTAssertNil(search.message)

        search.query = "zz"
        await search.searchTask?.value
        XCTAssertNotNil(search.message, "precondition: a message to clear")

        search.query = ""
        await search.searchTask?.value
        XCTAssertEqual(search.results, [])
        XCTAssertNil(search.message)
        XCTAssertFalse(search.isSearching)
        XCTAssertEqual(catalog.searches.map(\.argument), ["sw", "zz"])
    }

    func testASearchWaitsForThePauseInTyping() async {
        let catalog = FakeHuggingFaceCatalog()
        let search = makeSearch(catalog, debounce: .seconds(30))

        search.query = "swiss"
        XCTAssertTrue(search.isSearching, "a search is pending while the pause runs")
        await waitFor(!catalog.searches.isEmpty, timeout: .milliseconds(100))

        XCTAssertEqual(catalog.searches, [])
        search.cancel()
    }

    func testQuickChangesSendOneSearchForTheLastQueryOnly() async {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["swiss"] = .success([Sample.spert])
        let search = makeSearch(catalog)

        search.query = "sw"
        let first = search.searchTask
        search.query = "swi"
        let second = search.searchTask
        search.query = " swiss "
        await first?.value
        await second?.value
        await search.searchTask?.value

        XCTAssertEqual(catalog.searches.map(\.argument), ["swiss"])
        XCTAssertEqual(search.results, [Sample.spert])
        XCTAssertNil(search.message)
        XCTAssertFalse(search.isSearching)
    }

    func testAnOlderAnswerNeverReplacesTheResultsOfTheCurrentQuery() async {
        let catalog = FakeHuggingFaceCatalog()
        let gate = MainActorGate()
        catalog.searchGates["sw"] = gate
        catalog.searchAnswers["sw"] = .success([Sample.gcoli])
        catalog.searchAnswers["swiss"] = .success([Sample.spert])
        let search = makeSearch(catalog)

        search.query = "sw"
        let older = search.searchTask
        await waitFor(catalog.searches.count == 1)
        search.query = "swiss"
        await search.searchTask?.value
        XCTAssertEqual(search.results, [Sample.spert], "precondition: the current query's results")

        gate.open()
        await older?.value

        XCTAssertEqual(catalog.searches.map(\.argument), ["sw", "swiss"])
        XCTAssertEqual(search.results, [Sample.spert])
        XCTAssertNil(search.message)
        XCTAssertFalse(search.isSearching)
    }

    func testNoResultsShowTheNoMatchLine() async {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["zzz"] = .success([])
        let search = makeSearch(catalog)

        search.query = "  zzz "
        await search.searchTask?.value

        XCTAssertEqual(search.results, [])
        XCTAssertEqual(search.message, "No WhisperKit models match \"zzz\".")
    }

    func testEachCatalogErrorShowsItsMessageAndClearsTheResults() async {
        let errors: [HuggingFaceCatalogError] = [
            .unreachable, .refused, .notFound, .rateLimited, .unexpectedStatus(500), .malformedResponse, .invalidRepository,
        ]
        let catalog = FakeHuggingFaceCatalog()
        let search = makeSearch(catalog)
        for (index, error) in errors.enumerated() {
            catalog.searchAnswers["ok\(index)"] = .success([Sample.spert])
            catalog.searchAnswers["failing\(index)"] = .failure(error)
            search.query = "ok\(index)"
            await search.searchTask?.value
            XCTAssertEqual(search.results, [Sample.spert], "precondition: results to clear, \(error)")

            search.query = "failing\(index)"
            await search.searchTask?.value

            XCTAssertEqual(search.results, [], "\(error)")
            XCTAssertEqual(search.message, error.message, "\(error)")
            XCTAssertFalse(search.isSearching, "\(error)")
        }
    }

    func testTheTokenIsReadForEachCall() async {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["swiss"] = .success([Sample.spert])
        catalog.listingAnswers[Sample.spert.id] = .success(Sample.listing(Sample.spert))
        let token = HuggingFaceTokenSource()
        let search = makeSearch(catalog, token: token)

        search.query = "sw"
        await search.searchTask?.value
        token.value = "abc"
        search.query = "swiss"
        await search.searchTask?.value
        token.value = "xyz"
        search.choose(Sample.spert)
        await search.listingTask?.value

        XCTAssertEqual(catalog.searches.map(\.token), [nil, "abc"])
        XCTAssertEqual(catalog.listings.map(\.token), ["xyz"])
    }

    // MARK: - Listing

    func testChoosingARepositoryListsItAndEditingTheQueryLeavesIt() async {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["swiss"] = .success([Sample.spert, Sample.gcoli])
        let listing = Sample.listing(Sample.spert)
        catalog.listingAnswers[Sample.spert.id] = .success(listing)
        let search = makeSearch(catalog)
        search.query = "swiss"
        await search.searchTask?.value

        search.choose(Sample.spert)
        XCTAssertTrue(search.isListing)
        await search.listingTask?.value

        XCTAssertEqual(catalog.listings.map(\.argument), [Sample.spert.id])
        XCTAssertEqual(search.listing, listing)
        XCTAssertFalse(search.isListing)
        XCTAssertEqual(search.results, [Sample.spert, Sample.gcoli], "the results stay for Back")

        search.query = "swiss g"
        XCTAssertNil(search.listing, "editing the query returns to the results")
    }

    func testAFailedListingShowsItsMessage() async {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["swiss"] = .success([Sample.spert])
        catalog.listingAnswers[Sample.spert.id] = .failure(HuggingFaceCatalogError.refused)
        let search = makeSearch(catalog)
        search.query = "swiss"
        await search.searchTask?.value

        search.choose(Sample.spert)
        await search.listingTask?.value

        XCTAssertNil(search.listing)
        XCTAssertEqual(search.message, HuggingFaceCatalogError.refused.message)
        XCTAssertEqual(search.results, [Sample.spert])
        XCTAssertFalse(search.isListing)
    }

    private enum Interruption: CaseIterable {
        case back, chooseAnother, editQuery, clearQuery
    }

    /// Whatever ends the wait for a listing, a success or failure arriving after
    /// it changes nothing: neither the results nor the message nor which listing
    /// is shown.
    func testALateListingChangesNothingAfterBackChooseAgainOrAQueryEdit() async {
        let outcomes: [Result<HuggingFaceRepositoryListing, any Error>] = [
            .success(Sample.listing(Sample.spert)), .failure(HuggingFaceCatalogError.unreachable),
        ]
        for interruption in Interruption.allCases {
            for outcome in outcomes {
                let label = "\(interruption), \(outcome)"
                let catalog = FakeHuggingFaceCatalog()
                catalog.searchAnswers["swiss"] = .success([Sample.spert, Sample.gcoli])
                catalog.searchAnswers["swiss g"] = .success([Sample.gcoli])
                catalog.listingAnswers[Sample.spert.id] = outcome
                catalog.listingAnswers[Sample.gcoli.id] = .success(Sample.listing(Sample.gcoli, variants: []))
                let gate = MainActorGate()
                catalog.listingGates[Sample.spert.id] = gate
                let search = makeSearch(catalog)
                search.query = "swiss"
                await search.searchTask?.value
                search.choose(Sample.spert)
                let late = search.listingTask
                await waitFor(catalog.listings.count == 1)

                let expectedResults: [HuggingFaceModelSummary]
                var expectedListing: HuggingFaceRepositoryListing?
                switch interruption {
                case .back:
                    search.backToResults()
                    expectedResults = [Sample.spert, Sample.gcoli]

                case .chooseAnother:
                    search.choose(Sample.gcoli)
                    await search.listingTask?.value
                    expectedResults = [Sample.spert, Sample.gcoli]
                    expectedListing = Sample.listing(Sample.gcoli, variants: [])

                case .editQuery:
                    search.query = "swiss g"
                    await search.searchTask?.value
                    expectedResults = [Sample.gcoli]

                case .clearQuery:
                    search.query = ""
                    expectedResults = []
                }
                gate.open()
                await late?.value

                XCTAssertEqual(search.listing, expectedListing, label)
                XCTAssertEqual(search.results, expectedResults, label)
                XCTAssertNil(search.message, label)
                XCTAssertFalse(search.isListing, label)
            }
        }
    }

    // MARK: - Cancel

    /// The view calls `cancel()` when the window closes: a search still in its
    /// pause is never sent, and an answer to a search or listing already in
    /// flight is dropped.
    func testCancelStopsPendingAndInFlightWork() async {
        let pausedCatalog = FakeHuggingFaceCatalog()
        let paused = makeSearch(pausedCatalog)
        paused.query = "swiss"
        paused.cancel()
        await paused.searchTask?.value
        XCTAssertEqual(pausedCatalog.searches, [])
        XCTAssertFalse(paused.isSearching)

        let searchCatalog = FakeHuggingFaceCatalog()
        let searchGate = MainActorGate()
        searchCatalog.searchGates["swiss"] = searchGate
        searchCatalog.searchAnswers["swiss"] = .success([Sample.spert])
        let searching = makeSearch(searchCatalog)
        searching.query = "swiss"
        let search = searching.searchTask
        await waitFor(searchCatalog.searches.count == 1)
        searching.cancel()
        searchGate.open()
        await search?.value
        XCTAssertEqual(searching.results, [])
        XCTAssertFalse(searching.isSearching)

        let listingCatalog = FakeHuggingFaceCatalog()
        let listingGate = MainActorGate()
        listingCatalog.searchAnswers["swiss"] = .success([Sample.spert])
        listingCatalog.listingAnswers[Sample.spert.id] = .success(Sample.listing(Sample.spert))
        listingCatalog.listingGates[Sample.spert.id] = listingGate
        let listing = makeSearch(listingCatalog)
        listing.query = "swiss"
        await listing.searchTask?.value
        listing.choose(Sample.spert)
        let pendingListing = listing.listingTask
        await waitFor(listingCatalog.listings.count == 1)
        listing.cancel()
        listingGate.open()
        await pendingListing?.value
        XCTAssertNil(listing.listing)
        XCTAssertFalse(listing.isListing)
    }
}
