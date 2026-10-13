import Foundation
@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// "Use" and "Cancel" in the Hugging Face browser, on the state object the picker
/// presents it from. The load offer a "Use" makes waits for the browser to close,
/// because an alert presented while a sheet is still dismissing can be dropped on
/// macOS. What the offer's own buttons do is pinned in `WhisperKitModelChoiceTests`.
@MainActor
final class WhisperKitModelChoiceHubTests: XCTestCase {
    private typealias Sample = HuggingFaceSearchSample

    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    private let spertSelection = WhisperKitModelSelection(
        variant: Sample.spertVariant.name,
        origin: .hub(repoID: Sample.spert.id),
    )

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "WhisperKitModelChoiceHubTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults, huggingFaceTokenStore: HuggingFaceTokenStoreFake().store)
    }

    override func tearDown() async throws {
        settings = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// What the picker's "From Hugging Face…" entry does.
    private func openBrowser(on choice: WhisperKitModelChoice) {
        choice.hubBrowser = HuggingFaceModelSearch(catalog: FakeHuggingFaceCatalog(), token: { nil }, debounce: .zero)
    }

    private func useSpert(on choice: WhisperKitModelChoice, engine: WhisperKitEngine) {
        choice.use(Sample.spertVariant, in: Sample.listing(Sample.spert), settings: settings, engine: engine) { _ in false }
    }

    func testUseWritesTheSettingsClosesTheBrowserAndHoldsTheOfferBack() {
        let choice = WhisperKitModelChoice()
        let engine = WhisperKitEngine()
        openBrowser(on: choice)

        useSpert(on: choice, engine: engine)

        XCTAssertEqual(settings.whisperKitModelSelection, spertSelection)
        XCTAssertNil(choice.hubBrowser)
        XCTAssertNil(choice.loadOffer, "No question while the browser is still closing")
        XCTAssertEqual(
            choice.pendingLoadOffer,
            WhisperKitModelLoadOffer(selection: spertSelection, sizeBytes: Sample.spertVariant.sizeBytes, isOnDisk: false),
        )
        XCTAssertEqual(engine.deferredSelection, spertSelection, "A load in flight must not go on to the pick before the answer")
    }

    func testClosingTheBrowserAfterUseAsksTheQuestion() throws {
        let choice = WhisperKitModelChoice()
        openBrowser(on: choice)
        useSpert(on: choice, engine: WhisperKitEngine())
        let pending = try XCTUnwrap(choice.pendingLoadOffer)

        choice.browserDidDismiss()

        XCTAssertEqual(choice.loadOffer, pending)
        XCTAssertNil(choice.pendingLoadOffer)
    }

    func testClosingTheBrowserWithoutUseAsksNothing() {
        let choice = WhisperKitModelChoice()
        let before = settings.whisperKitModelSelection
        openBrowser(on: choice)

        choice.hubBrowser = nil
        choice.browserDidDismiss()

        XCTAssertNil(choice.loadOffer)
        XCTAssertNil(choice.pendingLoadOffer)
        XCTAssertEqual(settings.whisperKitModelSelection, before)
    }

    func testAStockVariantOffersToLoadTheStockEntry() {
        let choice = WhisperKitModelChoice()
        let small = HuggingFaceModelVariant(name: "openai_whisper-small", sizeBytes: 486_487_465)
        let stockRepository = HuggingFaceModelSummary(id: WhisperKitLocalSnapshot.repoID, downloads: nil)
        openBrowser(on: choice)

        choice.use(small, in: Sample.listing(stockRepository, variants: [small]), settings: settings, engine: WhisperKitEngine()) { _ in true }

        XCTAssertFalse(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(
            choice.pendingLoadOffer,
            WhisperKitModelLoadOffer(
                selection: WhisperKitModelSelection(variant: "openai_whisper-small", origin: .stock),
                sizeBytes: 486_487_465,
                isOnDisk: true,
            ),
        )
    }

    /// Picking the model the engine already holds changes nothing to load.
    func testUsingTheLoadedModelAsksNothing() async throws {
        let engine = WhisperKitEngine()
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        let folder = try makeTempDirectory(prefix: "wk-choice-hub")
        engine.installModelSourceForTesting { _ in
            WhisperKitModelSource(
                locateLocal: { _ in folder },
                download: { _, _ in throw URLError(.networkConnectionLost) },
                makePipe: { _, _ in pipe },
            )
        }
        await engine.loadModel(for: spertSelection)
        XCTAssertEqual(engine.modelState, .loaded, "Precondition: the picked model is loaded")
        let choice = WhisperKitModelChoice()
        openBrowser(on: choice)

        useSpert(on: choice, engine: engine)
        choice.browserDidDismiss()

        XCTAssertNil(choice.pendingLoadOffer)
        XCTAssertNil(choice.loadOffer)
        XCTAssertNil(choice.hubBrowser)
    }
}
