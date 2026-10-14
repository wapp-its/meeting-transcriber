@testable import MeetingTranscriber
import ViewInspector
import WhisperKit
import XCTest

/// Wiring of the load offer into the model picker, and of "Load Model" into the shared
/// load helper. What the offer's buttons do is pinned on `WhisperKitModelChoice` in
/// `WhisperKitModelChoiceTests`; the alert itself is manual QA.
@MainActor
final class TranscriptionSettingsLoadOfferTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsLoadOfferTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeView(
        settings: AppSettings,
        choice: WhisperKitModelChoice,
        engine: WhisperKitEngine = WhisperKitEngine(),
    ) -> TranscriptionSettingsView {
        var view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: engine,
            parakeetEngine: ParakeetEngine(),
            modelChoice: choice,
        )
        view.isModelOnDisk = { _ in false }
        return view
    }

    private func modelPicker(in view: TranscriptionSettingsView) throws -> InspectableView<ViewType.Picker> {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.whisperKitModelPicker)
            .find(ViewType.Picker.self)
    }

    func testPickingAStockModelOffersToLoadItWithItsTableSize() throws {
        let choice = WhisperKitModelChoice()

        try modelPicker(in: makeView(settings: AppSettings(defaults: defaults), choice: choice))
            .select(value: "openai_whisper-small")

        XCTAssertEqual(
            choice.loadOffer,
            WhisperKitModelLoadOffer(
                selection: WhisperKitModelSelection(variant: "openai_whisper-small", origin: .stock),
                sizeBytes: WhisperKitStockModel.model(for: "openai_whisper-small")?.approximateBytes,
                isOnDisk: false,
            ),
        )
    }

    func testPickingTheCustomEntryOffersNothing() throws {
        let choice = WhisperKitModelChoice()

        try modelPicker(in: makeView(settings: AppSettings(defaults: defaults), choice: choice))
            .select(value: TranscriptionSettingsView.customModelTag)

        XCTAssertNil(choice.loadOffer)
    }

    /// "Load Model" applies the selection before loading, since the settings observer
    /// may not have reached the engine yet.
    func testLoadModelLoadsTheSelectedModelThroughTheSharedHelper() async throws {
        let settings = AppSettings(defaults: defaults)
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        let engine = WhisperKitEngine()
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        let folder = try makeTempDirectory(prefix: "wk-load-button")
        let loaded = expectation(description: "the model is located")
        var located: [WhisperKitModelSelection] = []
        engine.installModelSourceForTesting { origin in
            WhisperKitModelSource(
                locateLocal: { variant in
                    located.append(WhisperKitModelSelection(variant: variant, origin: origin))
                    loaded.fulfill()
                    return folder
                },
                download: { _, _ in throw URLError(.networkConnectionLost) },
                makePipe: { _, _ in pipe },
            )
        }

        try makeView(settings: settings, choice: WhisperKitModelChoice(), engine: engine).inspect()
            .find(button: "Load Model").tap()
        await fulfillment(of: [loaded], timeout: 5)

        XCTAssertEqual(located, [settings.whisperKitModelSelection])
        XCTAssertEqual(settings.whisperKitModelSelection.origin, .hub(repoID: "spert/flix-swissgerman-whisperkit"))
    }
}
