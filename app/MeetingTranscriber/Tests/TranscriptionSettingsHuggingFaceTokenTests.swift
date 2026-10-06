@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the Hugging Face token row. What saving and removing do is pinned in
/// `AppSettingsHuggingFaceTokenTests`; every view here is built with
/// `HuggingFaceTokenStoreFake`, so no test touches the token saved in the app.
@MainActor
final class TranscriptionSettingsHuggingFaceTokenTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var fake: HuggingFaceTokenStoreFake!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsHuggingFaceTokenTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        fake = HuggingFaceTokenStoreFake()
        settings = AppSettings(defaults: defaults, huggingFaceTokenStore: fake.store)
        settings.transcriptionEngine = .whisperKit
    }

    override func tearDown() async throws {
        settings = nil
        fake = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeView() -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
    }

    private func button(_ identifier: String) throws -> InspectableView<ViewType.Button> {
        try makeView().inspect()
            .find(viewWithAccessibilityIdentifier: identifier)
            .find(ViewType.Button.self)
    }

    func testTypingWritesTheDraftAndSavesNothing() throws {
        try makeView().inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.huggingFaceTokenField)
            .find(ViewType.SecureField.self)
            .setInput("hf_typed")

        XCTAssertEqual(settings.huggingFaceTokenDraft, "hf_typed")
        XCTAssertNil(fake.token)
    }

    func testSaveStoresTheDraft() throws {
        settings.huggingFaceTokenDraft = "hf_typed"

        try button(A11yID.huggingFaceTokenSaveButton).tap()

        XCTAssertEqual(fake.token, "hf_typed")
    }

    func testSaveIsUnavailableForAWhitespaceOnlyDraft() throws {
        settings.huggingFaceTokenDraft = "  \n"

        XCTAssertTrue(try button(A11yID.huggingFaceTokenSaveButton).isDisabled())
    }

    func testRemoveDeletesTheSavedToken() throws {
        fake.token = "hf_old"
        settings.refreshHuggingFaceTokenSaved()

        try button(A11yID.huggingFaceTokenRemoveButton).tap()

        XCTAssertNil(fake.token)
    }

    func testRemoveIsAbsentWithoutASavedToken() {
        XCTAssertThrowsError(try button(A11yID.huggingFaceTokenRemoveButton))
    }

    /// The caption asks the store on appear, which is what makes a token saved in
    /// an earlier session show as saved (and Remove appear) when Settings opens.
    func testCaptionFollowsTheStoreOnAppear() throws {
        fake.token = "hf_old"

        try makeView().inspect()
            .find(text: "Optional, for private or gated models. Without a token, models download anonymously; "
                + "tokens elsewhere on this Mac are not used.")
            .callOnAppear()

        XCTAssertTrue(settings.huggingFaceTokenSaved)
        XCTAssertNoThrow(try makeView().inspect().find(text: "A token is saved. WhisperKit models download with it."))
    }

    func testAFailingStoreShowsTheProblemAfterSave() throws {
        fake.saveSucceeds = false
        settings.huggingFaceTokenDraft = "hf_typed"
        XCTAssertThrowsError(try makeView().inspect().find(viewWithAccessibilityIdentifier: A11yID.huggingFaceTokenProblem))

        try button(A11yID.huggingFaceTokenSaveButton).tap()

        let problem = try makeView().inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.huggingFaceTokenProblem)
            .find(ViewType.Text.self)
            .string()
        XCTAssertEqual(problem, "The token could not be saved to the Keychain.")
    }

    func testRowShowsForStockAndCustomWhisperKitModelsOnly() {
        XCTAssertNoThrow(try makeView().inspect().find(viewWithAccessibilityIdentifier: A11yID.huggingFaceTokenField), "stock")

        settings.whisperKitCustomModelEnabled = true
        XCTAssertNoThrow(try makeView().inspect().find(viewWithAccessibilityIdentifier: A11yID.huggingFaceTokenField), "custom")

        settings.transcriptionEngine = .parakeet
        XCTAssertThrowsError(try makeView().inspect().find(viewWithAccessibilityIdentifier: A11yID.huggingFaceTokenField), "Parakeet")
    }
}
