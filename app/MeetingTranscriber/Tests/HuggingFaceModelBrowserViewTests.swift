@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the Hugging Face browser window, one test per control, located by
/// `A11yID`. The behaviour behind the controls is pinned on the search model in
/// `HuggingFaceModelSearchTests`; state is prepared by driving that model
/// against a fake catalog.
@MainActor
final class HuggingFaceModelBrowserViewTests: XCTestCase {
    private typealias Sample = HuggingFaceSearchSample

    private func makeSearch(_ catalog: FakeHuggingFaceCatalog, debounce: Duration = .zero) -> HuggingFaceModelSearch {
        HuggingFaceModelSearch(catalog: catalog, token: { nil }, debounce: debounce)
    }

    private func makeView(
        _ search: HuggingFaceModelSearch,
        onUse: @escaping (HuggingFaceModelVariant, HuggingFaceRepositoryListing) -> Void = { _, _ in },
        onCancel: @escaping () -> Void = {},
    ) -> HuggingFaceModelBrowserView {
        HuggingFaceModelBrowserView(search: search, onUse: onUse, onCancel: onCancel)
    }

    /// A search showing `listing`, reached the way a person reaches it: a query,
    /// then choosing its one result.
    private func searchShowing(_ listing: HuggingFaceRepositoryListing) async -> HuggingFaceModelSearch {
        let catalog = FakeHuggingFaceCatalog()
        let summary = HuggingFaceModelSummary(id: listing.id, downloads: 56)
        catalog.searchAnswers["swiss"] = .success([summary])
        catalog.listingAnswers[listing.id] = .success(listing)
        let search = makeSearch(catalog)
        search.query = "swiss"
        await search.searchTask?.value
        search.choose(summary)
        await search.listingTask?.value
        XCTAssertEqual(search.listing, listing, "precondition: the listing is shown")
        return search
    }

    private func button(_ identifier: String, in view: HuggingFaceModelBrowserView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: identifier).find(ViewType.Button.self)
    }

    // MARK: - Search

    func testTheSearchFieldWritesTheQuery() throws {
        let search = makeSearch(FakeHuggingFaceCatalog(), debounce: .seconds(30))

        try makeView(search).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.huggingFaceSearchField)
            .find(ViewType.TextField.self)
            .setInput("swiss")

        XCTAssertEqual(search.query, "swiss")
        search.cancel()
    }

    func testAResultRowShowsItsDownloadsAndListsThatRepository() async throws {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["swiss"] = .success([Sample.spert, Sample.gcoli])
        catalog.listingAnswers[Sample.spert.id] = .success(Sample.listing(Sample.spert))
        let search = makeSearch(catalog)
        search.query = "swiss"
        await search.searchTask?.value
        let view = makeView(search)
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.huggingFaceResult(Sample.spert.id))
                .find(text: "56 downloads"),
        )

        try button(A11yID.huggingFaceResult(Sample.spert.id), in: view).tap()
        await search.listingTask?.value

        XCTAssertEqual(catalog.listings.map(\.argument), [Sample.spert.id])
        XCTAssertEqual(search.listing?.id, Sample.spert.id)
    }

    func testTheMessageShowsInTheWindow() async throws {
        let catalog = FakeHuggingFaceCatalog()
        catalog.searchAnswers["swiss"] = .failure(HuggingFaceCatalogError.rateLimited)
        let search = makeSearch(catalog)
        search.query = "swiss"
        await search.searchTask?.value

        XCTAssertNoThrow(try makeView(search).inspect().find(text: HuggingFaceCatalogError.rateLimited.message))
    }

    // MARK: - Listing

    func testAListingShowsSizesLicenseGatedNoticeAndModelCard() async throws {
        let unsized = HuggingFaceModelVariant(name: "flix-swissgerman-large-v3_unsized", sizeBytes: nil)
        let listing = Sample.listing(Sample.spert, variants: [Sample.spertVariant, unsized], isGated: true)
        let view = await makeView(searchShowing(listing))
        let sized = ByteCountFormatter.string(fromByteCount: 1_627_283_096, countStyle: .file)

        XCTAssertNoThrow(try view.inspect().find(text: Sample.spertVariant.name))
        XCTAssertNoThrow(try view.inspect().find(text: sized))
        XCTAssertNoThrow(try view.inspect().find(text: unsized.name))
        XCTAssertNoThrow(try view.inspect().find(text: "size unknown"))
        XCTAssertNoThrow(try view.inspect().find(text: "Apache 2.0"))
        XCTAssertNoThrow(
            try view.inspect().find(text: "Gated: accept the terms on huggingface.co and add your Hugging Face token in Settings."),
        )
        let link = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.huggingFaceModelCardLink)
            .find(ViewType.Link.self)
        XCTAssertEqual(try link.url(), listing.modelCardURL)
    }

    func testANonCommercialLicenseIsMarked() async throws {
        let listing = Sample.listing(Sample.gcoli, license: HuggingFaceLicense(identifier: "swissdial-cc-by-nc-4.0-no-reidentification"))
        let view = await makeView(searchShowing(listing))

        XCTAssertNoThrow(try view.inspect().find(text: "swissdial-cc-by-nc-4.0-no-reidentification — non-commercial"))
        XCTAssertThrowsError(try view.inspect().find(text: "Gated: accept the terms on huggingface.co and add your Hugging Face token in Settings."))
    }

    func testAListingWithoutVariantsSaysSoAndOffersNoUse() async throws {
        let listing = Sample.listing(Sample.gcoli, variants: [], license: nil)
        let view = await makeView(searchShowing(listing))

        XCTAssertNoThrow(
            try view.inspect().find(text: "No variant this app can load. The model files have to sit in one folder per variant."),
        )
        XCTAssertNoThrow(try view.inspect().find(text: "License not stated — check the model card"))
        XCTAssertThrowsError(try view.inspect().find(button: "Use"))
    }

    func testUseReportsTheVariantAndTheListing() async throws {
        let listing = Sample.listing(Sample.spert)
        var used: (variant: HuggingFaceModelVariant, listing: HuggingFaceRepositoryListing)?
        let onUse: (HuggingFaceModelVariant, HuggingFaceRepositoryListing) -> Void = { used = ($0, $1) }
        let view = await makeView(searchShowing(listing), onUse: onUse)

        try button(A11yID.huggingFaceUseVariant(Sample.spertVariant.name), in: view).tap()

        XCTAssertEqual(used?.variant, Sample.spertVariant)
        XCTAssertEqual(used?.listing, listing)
    }

    func testBackToResultsClearsTheListing() async throws {
        let search = await searchShowing(Sample.listing(Sample.spert))

        try button(A11yID.huggingFaceBackButton, in: makeView(search)).tap()

        XCTAssertNil(search.listing)
        XCTAssertEqual(search.results.map(\.id), [Sample.spert.id])
    }

    // MARK: - Closing

    func testCancelReportsThroughItsClosure() throws {
        var cancelled = false
        let onCancel = { cancelled = true }

        try button(A11yID.huggingFaceCancelButton, in: makeView(makeSearch(FakeHuggingFaceCatalog()), onCancel: onCancel)).tap()

        XCTAssertTrue(cancelled)
    }

    func testClosingTheWindowCancelsPendingWork() async throws {
        let catalog = FakeHuggingFaceCatalog()
        let search = makeSearch(catalog, debounce: .seconds(30))
        search.query = "swiss"
        let pending = search.searchTask

        try makeView(search).inspect().find(ViewType.VStack.self).callOnDisappear()
        await pending?.value

        XCTAssertEqual(catalog.searches, [])
        XCTAssertFalse(search.isSearching)
    }

    #if !APPSTORE
        /// "Use" starts a model download through the caller and the window is a
        /// sheet, so none of these may join the live `/ui/press` list.
        func testNoBrowserIdentifierIsOnTheUIPressAllowlist() {
            let identifiers = [
                A11yID.huggingFaceSearchField, A11yID.huggingFaceResult(Sample.spert.id), A11yID.huggingFaceBackButton,
                A11yID.huggingFaceModelCardLink, A11yID.huggingFaceUseVariant(Sample.spertVariant.name),
                A11yID.huggingFaceCancelButton,
            ]
            for identifier in identifiers {
                XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIPress(identifier), identifier)
            }
        }
    #endif
}
