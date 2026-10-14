import Foundation
@testable import MeetingTranscriber
import XCTest

/// What "Use" in the Hugging Face browser writes: the existing custom-model settings,
/// or the matching stock entry, and never a custom model folder, which would take
/// precedence over the pick.
final class AppSettingsUseHubModelTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    private let spertRepo = "spert/flix-swissgerman-whisperkit"
    private let spertVariant = "flix-swissgerman-large-v3_8bit"

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsUseHubModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        settings = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A custom model folder, the setting that wins over any repository.
    private func chooseAFolder() {
        settings.whisperKitCustomModelEnabled = true
        settings.updateWhisperKitCustomModelFolder(path: "/nonexistent/old-model", bookmark: Data("bookmark".utf8))
        guard case .localFolder = settings.whisperKitModelSelection.origin else {
            XCTFail("precondition: the folder is the selected model")
            return
        }
    }

    func testAnotherRepositoryBecomesTheCustomModelAndClearsTheFolder() {
        chooseAFolder()

        settings.useHubModel(repoID: spertRepo, variant: spertVariant)

        let expected = WhisperKitModelSelection(variant: spertVariant, origin: .hub(repoID: spertRepo))
        XCTAssertEqual(settings.whisperKitModelSelection, expected)
        XCTAssertTrue(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(settings.whisperKitCustomRepo, spertRepo)
        XCTAssertEqual(settings.whisperKitCustomVariant, spertVariant)
        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "")
        XCTAssertNil(settings.whisperKitCustomModelFolderBookmark)
        XCTAssertEqual(
            AppSettings(defaults: defaults).whisperKitModelSelection,
            expected,
            "the folder must not come back after a relaunch",
        )
    }

    func testAStockVariantOfTheStockRepositorySelectsThatEntryAndClearsTheFolder() {
        settings.whisperKitModel = "openai_whisper-large-v3-v20240930_turbo"
        settings.whisperKitCustomRepo = spertRepo
        settings.whisperKitCustomVariant = spertVariant
        chooseAFolder()

        settings.useHubModel(repoID: WhisperKitLocalSnapshot.repoID, variant: "openai_whisper-small")

        XCTAssertEqual(settings.whisperKitModelSelection, WhisperKitModelSelection(variant: "openai_whisper-small", origin: .stock))
        XCTAssertFalse(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(settings.whisperKitModel, "openai_whisper-small")
        XCTAssertEqual(settings.whisperKitCustomModelFolderPath, "")
        XCTAssertNil(settings.whisperKitCustomModelFolderBookmark)
    }

    /// The stock repository holds more variants than the picker lists; one of those has
    /// no stock entry to select, so it is used like any other repository's.
    func testAnotherVariantOfTheStockRepositoryBecomesTheCustomModel() {
        let variant = "distil-whisper_distil-large-v3"

        settings.useHubModel(repoID: WhisperKitLocalSnapshot.repoID, variant: variant)

        XCTAssertEqual(settings.whisperKitModelSelection, WhisperKitModelSelection(variant: variant, origin: .stock))
        XCTAssertTrue(settings.whisperKitCustomModelEnabled)
        XCTAssertEqual(settings.whisperKitCustomRepo, WhisperKitLocalSnapshot.repoID)
        XCTAssertEqual(settings.whisperKitCustomVariant, variant)
    }
}
