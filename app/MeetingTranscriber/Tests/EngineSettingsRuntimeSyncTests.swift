@testable import MeetingTranscriber
import XCTest

/// Verifies that `AppSettings` changes propagate to the engine instances at
/// runtime, not just on app restart. The settings ↔ engine sync used to run
/// only once when the pipeline queue was first built; later UI changes
/// silently dropped on the floor until the next launch.
///
/// Exercises `EngineController` directly — the concern was extracted out of
/// `AppState`, so these tests now construct the bare controller (no full
/// `AppState`, no log-streamer subprocess) and assert on its engine instances.
@MainActor
final class EngineSettingsRuntimeSyncTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "EngineSettingsRuntimeSyncTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = DefaultsSuite.open(testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        settings = nil
        DefaultsSuite.remove(testSuiteName)
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    // MARK: - Initial sync at EngineController init

    func test_initialSync_propagatesWhisperLanguageToEngine() {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.language, "de")
    }

    func test_initialSync_propagatesCustomVocabularyPathToParakeet() {
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyEnabled = true
        settings.setCustomVocabularyPath("/tmp/init-vocab.txt")
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/init-vocab.txt")
    }

    func test_vocabularySwitchOff_keepsTheFileFromParakeet() async {
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyEnabled = false
        settings.setCustomVocabularyPath("/tmp/off-vocab.txt")
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "")

        settings.customVocabularyEnabled = true

        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/off-vocab.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/off-vocab.txt")
    }

    func test_vocabularySwitchOff_keepsTheBookmarkFromParakeet() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-switch-\(UUID().uuidString).txt")
        try "Northstar\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyEnabled = false
        settings.setCustomVocabularyFile(file)
        let bookmark = try XCTUnwrap(settings.customVocabularyBookmark)
        let engines = EngineController(settings: settings)
        XCTAssertNil(engines.parakeetEngine.customVocabularyBookmark)

        settings.customVocabularyEnabled = true

        await waitFor(engines.parakeetEngine.customVocabularyBookmark == bookmark)
        XCTAssertEqual(engines.parakeetEngine.customVocabularyBookmark, bookmark)
    }

    func test_initialSync_propagatesCustomVocabularyPathToWhisperKit() {
        settings.transcriptionEngine = .whisperKit
        settings.setCustomVocabularyPath("/tmp/init-vocab.txt")
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.customVocabularyPath, "/tmp/init-vocab.txt")
    }

    func test_initialSync_propagatesWhisperKitVocabularyPromptChoice() {
        settings.transcriptionEngine = .whisperKit
        settings.customVocabularyEnabled = true

        XCTAssertTrue(EngineController(settings: settings).whisperKit.vocabularyPromptEnabled)
    }

    func test_initialSync_propagatesWhisperKitModelToEngine() {
        settings.transcriptionEngine = .whisperKit
        settings.whisperKitModel = "openai_whisper-small"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.modelVariant, "openai_whisper-small")
    }

    /// The engine asks for the token saved in Settings each time it makes a Hub
    /// request, so a removed token is no longer sent. The store is in memory, so
    /// nothing here touches the token saved in the app.
    func test_whisperKitHubToken_isTheSavedToken() {
        let fake = HuggingFaceTokenStoreFake()
        let tokenSettings = AppSettings(defaults: defaults, huggingFaceTokenStore: fake.store)
        tokenSettings.huggingFaceTokenDraft = "hf_saved"
        tokenSettings.saveHuggingFaceTokenDraft()
        let engines = EngineController(settings: tokenSettings)
        XCTAssertEqual(engines.whisperKit.hubToken(), "hf_saved")

        tokenSettings.removeHuggingFaceToken()

        XCTAssertEqual(engines.whisperKit.hubToken(), "")
    }

    // MARK: - Runtime propagation

    func test_runtimeChange_whisperLanguage_propagatesToEngine() async {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.language, "de")

        settings.whisperLanguage = "en"

        await waitFor(engines.whisperKit.language == "en")
        XCTAssertEqual(engines.whisperKit.language, "en")
    }

    /// The model variant was the one engine-config key missing from the
    /// reactive observer: changing it in Settings only reached the engine via
    /// the explicit "Load Model" button or a relaunch, so a user who picked a
    /// new model and started a meeting silently transcribed with the old one.
    func test_runtimeChange_whisperKitModel_propagatesToEngine() async {
        settings.transcriptionEngine = .whisperKit
        let engines = EngineController(settings: settings)
        let original = engines.whisperKit.modelVariant

        settings.whisperKitModel = "openai_whisper-small"

        await waitFor(engines.whisperKit.modelVariant == "openai_whisper-small")
        XCTAssertEqual(engines.whisperKit.modelVariant, "openai_whisper-small")
        XCTAssertNotEqual(engines.whisperKit.modelVariant, original)
    }

    /// A custom model reaches the engine with its repository, and turning it off
    /// hands the engine back the stock variant from the stock repository.
    func test_runtimeChange_customWhisperKitModel_propagatesToEngine() async {
        settings.transcriptionEngine = .whisperKit
        settings.whisperKitModel = "openai_whisper-small"
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.modelOrigin, .stock, "Filled-in fields alone must not switch the model")

        settings.whisperKitCustomModelEnabled = true

        let swissGerman = WhisperKitModelOrigin.hub(repoID: "spert/flix-swissgerman-whisperkit")
        // `waitFor` only waits; the origin is asserted explicitly because a timeout
        // would otherwise pass straight through to the variant check.
        await waitFor(engines.whisperKit.modelOrigin == swissGerman)
        XCTAssertEqual(engines.whisperKit.modelOrigin, swissGerman)
        XCTAssertEqual(engines.whisperKit.modelVariant, "flix-swissgerman-large-v3_8bit")

        settings.whisperKitCustomModelEnabled = false

        await waitFor(engines.whisperKit.modelOrigin == .stock)
        XCTAssertEqual(engines.whisperKit.modelOrigin, .stock)
        XCTAssertEqual(engines.whisperKit.modelVariant, "openai_whisper-small")
    }

    /// With the custom model on, each of its fields is a key the observer has to
    /// track on its own: a changed repository, variant or folder is a different
    /// model, and one that is not observed would reach the engine only at relaunch.
    func test_runtimeChange_customModelFields_propagateToEngine() async throws {
        settings.transcriptionEngine = .whisperKit
        settings.whisperKitCustomModelEnabled = true
        settings.whisperKitCustomRepo = "spert/flix-swissgerman-whisperkit"
        settings.whisperKitCustomVariant = "flix-swissgerman-large-v3_8bit"
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.modelOrigin, .hub(repoID: "spert/flix-swissgerman-whisperkit"))

        settings.whisperKitCustomRepo = "someone/else"
        await waitFor(engines.whisperKit.modelOrigin == .hub(repoID: "someone/else"))
        XCTAssertEqual(engines.whisperKit.modelOrigin, .hub(repoID: "someone/else"))

        settings.whisperKitCustomVariant = "other-large-v3"
        await waitFor(engines.whisperKit.modelVariant == "other-large-v3")
        XCTAssertEqual(engines.whisperKit.modelVariant, "other-large-v3")

        let folder = try makeTempDirectory(prefix: "wk-folder")
        settings.setWhisperKitCustomModelFolderPath(folder.path)
        let picked = WhisperKitModelOrigin.localFolder(path: folder.path, bookmark: nil)
        await waitFor(engines.whisperKit.modelOrigin == picked)
        XCTAssertEqual(engines.whisperKit.modelOrigin, picked)
        XCTAssertEqual(engines.whisperKit.modelVariant, folder.lastPathComponent)
    }

    func test_runtimeChange_customVocabularyPath_propagatesToParakeet() async {
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyEnabled = true
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "")

        settings.setCustomVocabularyPath("/tmp/runtime-vocab.txt")

        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/runtime-vocab.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/runtime-vocab.txt")
    }

    func test_runtimeChange_customVocabularyPath_propagatesToWhisperKit() async {
        settings.transcriptionEngine = .whisperKit
        let engines = EngineController(settings: settings)
        XCTAssertEqual(engines.whisperKit.customVocabularyPath, "")

        settings.setCustomVocabularyPath("/tmp/runtime-vocab.txt")

        await waitFor(engines.whisperKit.customVocabularyPath == "/tmp/runtime-vocab.txt")
        XCTAssertEqual(engines.whisperKit.customVocabularyPath, "/tmp/runtime-vocab.txt")
    }

    func test_runtimeChange_whisperKitVocabularyPromptChoice_propagatesToEngine() async {
        settings.transcriptionEngine = .whisperKit
        let engines = EngineController(settings: settings)
        XCTAssertFalse(engines.whisperKit.vocabularyPromptEnabled)

        settings.customVocabularyEnabled = true

        await waitFor(engines.whisperKit.vocabularyPromptEnabled)
        XCTAssertTrue(engines.whisperKit.vocabularyPromptEnabled)
    }

    // MARK: - Re-arming

    /// `withObservationTracking` is one-shot per registration; the re-arm in
    /// `onChange` is what makes consecutive changes fire. Without it, only
    /// the first change would propagate and subsequent ones silently no-op.
    func test_observation_rearmsForMultipleChanges() async {
        settings.transcriptionEngine = .parakeet
        settings.customVocabularyEnabled = true
        let engines = EngineController(settings: settings)

        settings.setCustomVocabularyPath("/tmp/v1.txt")
        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/v1.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/v1.txt")

        settings.setCustomVocabularyPath("/tmp/v2.txt")
        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/v2.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/v2.txt")

        settings.setCustomVocabularyPath("/tmp/v3.txt")
        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/v3.txt")
        XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "/tmp/v3.txt")
    }

    // MARK: - Engine switch

    /// Switching `transcriptionEngine` must re-sync the now-active engine
    /// with the existing settings — otherwise the user gets a stale engine
    /// state until they touch any other setting.
    func test_engineSwitch_syncsNewlyActiveEngine() async {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        settings.customVocabularyEnabled = true
        settings.setCustomVocabularyPath("/tmp/parakeet-vocab.txt")
        let engines = EngineController(settings: settings)

        XCTAssertEqual(engines.whisperKit.language, "de")
        XCTAssertEqual(
            engines.parakeetEngine.customVocabularyPath, "",
            "Parakeet inactive at init — no sync expected",
        )

        settings.transcriptionEngine = .parakeet

        await waitFor(engines.parakeetEngine.customVocabularyPath == "/tmp/parakeet-vocab.txt")
        XCTAssertEqual(
            engines.parakeetEngine.customVocabularyPath, "/tmp/parakeet-vocab.txt",
        )
    }

    // MARK: - Vocabulary source

    private static let addressA = "https://lists.example.org/team/vocabulary.txt"
    private static let addressB = "https://lists.example.org/other/vocabulary.txt"

    /// With the URL source both engines read the copy kept for the configured
    /// address, never the local file and never with its bookmark; an address
    /// that is not fetched leaves them without vocabulary.
    func test_urlSource_givesBothEnginesTheAddressCopy_orNothingForAnInvalidAddress() throws {
        for engine in TranscriptionEngineSetting.allCases {
            let source = try makeSourceSettings(engine: engine)
            source.vocabularySource = .url
            source.remoteVocabularyURL = "  \(Self.addressA)\n"

            let valid = vocabulary(of: EngineController(settings: source), engine)
            XCTAssertEqual(valid.path, cacheFile(source, address: Self.addressA), "\(engine)")
            XCTAssertNil(valid.bookmark, "\(engine)")

            source.remoteVocabularyURL = "http://lists.example.org/team/vocabulary.txt"

            let invalid = vocabulary(of: EngineController(settings: source), engine)
            XCTAssertEqual(invalid.path, "", "\(engine)")
            XCTAssertNil(invalid.bookmark, "\(engine)")
        }
    }

    func test_runtimeSwitch_ofSourceAndAddress_propagatesToBothEngines() async throws {
        for engine in TranscriptionEngineSetting.allCases {
            let source = try makeSourceSettings(engine: engine)
            source.remoteVocabularyURL = Self.addressA
            let local = (path: source.customVocabularyPath, bookmark: source.customVocabularyBookmark)
            let engines = EngineController(settings: source)
            XCTAssertEqual(vocabulary(of: engines, engine).path, local.path, "\(engine)")
            XCTAssertEqual(vocabulary(of: engines, engine).bookmark, local.bookmark, "\(engine)")

            source.vocabularySource = .url

            await waitFor(vocabulary(of: engines, engine).path == cacheFile(source, address: Self.addressA))
            XCTAssertEqual(vocabulary(of: engines, engine).path, cacheFile(source, address: Self.addressA), "\(engine)")
            XCTAssertNil(vocabulary(of: engines, engine).bookmark, "\(engine)")

            source.remoteVocabularyURL = Self.addressB

            await waitFor(vocabulary(of: engines, engine).path == cacheFile(source, address: Self.addressB))
            XCTAssertEqual(vocabulary(of: engines, engine).path, cacheFile(source, address: Self.addressB), "\(engine)")

            source.vocabularySource = .file

            await waitFor(vocabulary(of: engines, engine).path == local.path)
            XCTAssertEqual(vocabulary(of: engines, engine).path, local.path, "\(engine)")
            XCTAssertEqual(vocabulary(of: engines, engine).bookmark, local.bookmark, "\(engine)")
        }
    }

    /// The switch covers the URL source as well: off, Parakeet reads no
    /// vocabulary at all, and WhisperKit gets no prompt.
    func test_vocabularySwitchOff_alsoTurnsOffTheURLSource() async throws {
        for engine in TranscriptionEngineSetting.allCases {
            let source = try makeSourceSettings(engine: engine)
            source.vocabularySource = .url
            source.remoteVocabularyURL = Self.addressA
            source.customVocabularyEnabled = false
            let engines = EngineController(settings: source)

            switch engine {
            case .parakeet:
                XCTAssertEqual(engines.parakeetEngine.customVocabularyPath, "")
                XCTAssertNil(engines.parakeetEngine.customVocabularyBookmark)

            case .whisperKit:
                XCTAssertFalse(engines.whisperKit.vocabularyPromptEnabled)
            }

            source.customVocabularyEnabled = true

            await waitFor(vocabulary(of: engines, engine).path == cacheFile(source, address: Self.addressA))
            XCTAssertEqual(vocabulary(of: engines, engine).path, cacheFile(source, address: Self.addressA), "\(engine)")
        }
    }

    /// Settings with their own cache directory (never created: only paths are
    /// derived here), the vocabulary switched on, and a local file selected
    /// through its bookmark.
    private func makeSourceSettings(engine: TranscriptionEngineSetting) throws -> AppSettings {
        let source = AppSettings(
            defaults: defaults,
            remoteVocabularyCacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("EngineSettingsRuntimeSyncTests-\(UUID().uuidString)", isDirectory: true),
        )
        source.transcriptionEngine = engine
        source.customVocabularyEnabled = true
        source.vocabularySource = .file
        let file = makeTempFile(suffix: ".txt")
        try Data("Northstar\n".utf8).write(to: file)
        source.setCustomVocabularyFile(file)
        XCTAssertNotNil(source.customVocabularyBookmark, "precondition: the local file carries a bookmark")
        return source
    }

    private func cacheFile(_ settings: AppSettings, address: String) -> String {
        RemoteVocabularyCache.textFile(
            in: settings.remoteVocabularyCacheDirectory, bundleID: settings.remoteVocabularyCache.bundleID, address: address,
        ).path
    }

    private func vocabulary(of engines: EngineController, _ engine: TranscriptionEngineSetting) -> (path: String, bookmark: Data?) {
        switch engine {
        case .whisperKit: (engines.whisperKit.customVocabularyPath, engines.whisperKit.customVocabularyBookmark)
        case .parakeet: (engines.parakeetEngine.customVocabularyPath, engines.parakeetEngine.customVocabularyBookmark)
        }
    }
}
