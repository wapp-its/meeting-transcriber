@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the model picker's "From Hugging Face…" entry and of the browser sheet it
/// opens. What "Use" writes and when the load offer appears is pinned on the state
/// object in `WhisperKitModelChoiceHubTests`; the browser's own controls in
/// `HuggingFaceModelBrowserViewTests`. Every view here searches a fake catalog and
/// reads its token from `HuggingFaceTokenStoreFake`, so no test reaches the network
/// or the token saved in the app.
@MainActor
final class TranscriptionSettingsHuggingFaceEntryTests: XCTestCase {
    private typealias Sample = HuggingFaceSearchSample

    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tokenStore: HuggingFaceTokenStoreFake!
    private var settings: AppSettings!
    private var catalog: FakeHuggingFaceCatalog!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsHuggingFaceEntryTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        tokenStore = HuggingFaceTokenStoreFake()
        settings = AppSettings(defaults: defaults, huggingFaceTokenStore: tokenStore.store)
        settings.transcriptionEngine = .whisperKit
        catalog = FakeHuggingFaceCatalog()
    }

    override func tearDown() async throws {
        catalog = nil
        settings = nil
        tokenStore = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeView(choice: WhisperKitModelChoice) -> TranscriptionSettingsView {
        var view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            modelChoice: choice,
        )
        view.isModelOnDisk = { _ in false }
        let catalog: FakeHuggingFaceCatalog = catalog
        view.makeHubCatalog = { catalog }
        return view
    }

    private func pickFromHuggingFace(in view: TranscriptionSettingsView) throws {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.whisperKitModelPicker)
            .find(ViewType.Picker.self)
            .select(value: TranscriptionSettingsView.huggingFaceTag)
    }

    /// The open browser sheet, showing the spert listing.
    private func browserShowingSpert(in view: TranscriptionSettingsView, choice: WhisperKitModelChoice) async throws
        -> InspectableView<ViewType.Sheet> {
        try pickFromHuggingFace(in: view)
        let search = try XCTUnwrap(choice.hubBrowser)
        catalog.listingAnswers[Sample.spert.id] = .success(Sample.listing(Sample.spert))
        search.choose(Sample.spert)
        await search.listingTask?.value
        return try view.inspect().find(ViewType.Sheet.self)
    }

    private func customField(_ identifier: String, in view: TranscriptionSettingsView) throws -> String {
        try view.inspect().find(ViewType.TextField.self) { try $0.accessibilityIdentifier() == identifier }.input()
    }

    func testFromHuggingFaceOpensTheBrowserAndChangesNoSetting() throws {
        settings.whisperKitModel = "openai_whisper-small"
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "owner/typed"
        settings.whisperKitCustomVariant = "typed-variant"
        let choice = WhisperKitModelChoice()

        try pickFromHuggingFace(in: makeView(choice: choice))

        XCTAssertNotNil(choice.hubBrowser)
        XCTAssertEqual(settings.whisperKitModel, "openai_whisper-small")
        XCTAssertTrue(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(settings.whisperKitCustomRepo, "owner/typed")
        XCTAssertEqual(settings.whisperKitCustomVariant, "typed-variant")
        XCTAssertNil(choice.loadOffer)
    }

    /// The token is read when a request is made, so one saved while the browser is
    /// open is sent with its next search.
    func testTheBrowserSearchesWithTheSavedHuggingFaceToken() async throws {
        let choice = WhisperKitModelChoice()
        try pickFromHuggingFace(in: makeView(choice: choice))
        let search = try XCTUnwrap(choice.hubBrowser)
        tokenStore.token = "hf_saved_while_open"

        search.query = "swiss"
        await search.searchTask?.value

        XCTAssertEqual(catalog.searches, [FakeHuggingFaceCatalog.Call(argument: "swiss", token: "hf_saved_while_open")])
    }

    func testUseFillsTheCustomFieldsAndAsksOnceTheBrowserHasClosed() async throws {
        let choice = WhisperKitModelChoice()
        let view = makeView(choice: choice)
        let sheet = try await browserShowingSpert(in: view, choice: choice)

        try sheet.find(viewWithAccessibilityIdentifier: A11yID.huggingFaceUseVariant(Sample.spertVariant.name))
            .find(ViewType.Button.self)
            .tap()

        XCTAssertNil(choice.hubBrowser)
        XCTAssertNil(choice.loadOffer, "No question while the sheet is closing")
        try sheet.dismiss()
        XCTAssertEqual(
            choice.loadOffer?.selection,
            WhisperKitModelSelection(variant: Sample.spertVariant.name, origin: .hub(repoID: Sample.spert.id)),
        )
        XCTAssertEqual(try customField(A11yID.whisperKitCustomRepoField, in: view), Sample.spert.id)
        XCTAssertEqual(try customField(A11yID.whisperKitCustomVariantField, in: view), Sample.spertVariant.name)
    }

    func testCancelClosesTheBrowserAndAsksNothing() async throws {
        let before = settings.whisperKitModelSelection
        let choice = WhisperKitModelChoice()
        let sheet = try await browserShowingSpert(in: makeView(choice: choice), choice: choice)

        try sheet.find(viewWithAccessibilityIdentifier: A11yID.huggingFaceCancelButton)
            .find(ViewType.Button.self)
            .tap()
        try sheet.dismiss()

        XCTAssertNil(choice.hubBrowser)
        XCTAssertNil(choice.loadOffer)
        XCTAssertEqual(settings.whisperKitModelSelection, before)
    }
}
