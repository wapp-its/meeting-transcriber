@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// When a model pick makes a load offer, and what "Load now" and "Later" load. The
/// engine's model-source seam observes the loads; nothing touches the network or
/// CoreML.
@MainActor
final class WhisperKitModelChoiceTests: XCTestCase {
    private let turbo = WhisperKitModelSelection(variant: "openai_whisper-large-v3-v20240930_turbo", origin: .stock)
    private let small = WhisperKitModelSelection(variant: "openai_whisper-small", origin: .stock)
    private let swissGerman = WhisperKitModelSelection(
        variant: "flix-swissgerman-large-v3_8bit",
        origin: .hub(repoID: "spert/flix-swissgerman-whisperkit"),
    )

    /// What each load resolved: the origin its source was made for and the variant it
    /// looked up on disk.
    private final class LoadRecorder {
        var loads: [WhisperKitModelSelection] = []
    }

    /// Install a source that loads every model from a temporary folder into a
    /// WhisperKit instance that loads nothing (`WhisperKitEngineModelOriginTests`).
    private func installRecordingSource(on engine: WhisperKitEngine) async throws -> LoadRecorder {
        let pipe = try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        let folder = try makeTempDirectory(prefix: "wk-choice")
        let recorder = LoadRecorder()
        engine.installModelSourceForTesting { origin in
            WhisperKitModelSource(
                locateLocal: { variant in
                    recorder.loads.append(WhisperKitModelSelection(variant: variant, origin: origin))
                    return folder
                },
                download: { _, _ in throw URLError(.networkConnectionLost) },
                makePipe: { _, _ in pipe },
            )
        }
        return recorder
    }

    // MARK: - When to offer

    func testShouldOfferOnlyWhenTheChosenModelIsNotAlreadyLoadedOrLoading() {
        let smallFromAnotherRepository = WhisperKitModelSelection(variant: small.variant, origin: swissGerman.origin)
        let cases: [(engine: WhisperKitModelSelection, state: EngineModelState, expected: Bool, why: String)] = [
            (turbo, .loaded, true, "another variant is loaded"),
            (turbo, .loading, true, "another variant is loading"),
            (smallFromAnotherRepository, .loaded, true, "the same folder name from another repository is another model"),
            (small, .unloaded, true, "the chosen model is requested but not loaded"),
            (small, .loaded, false, "the chosen model is loaded"),
            (small, .downloading, false, "the chosen model is downloading"),
            (small, .loading, false, "the chosen model is loading"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                WhisperKitModelChoice.shouldOffer(
                    chosen: small,
                    engineVariant: testCase.engine.variant,
                    engineOrigin: testCase.engine.origin,
                    engineState: testCase.state,
                ),
                testCase.expected,
                testCase.why,
            )
        }
    }

    func testOfferLoadRecordsTheModelItsSizeAndWhetherItIsOnDisk() {
        let choice = WhisperKitModelChoice()
        var asked: [WhisperKitModelSelection] = []

        choice.offerLoad(for: small, sizeBytes: 486_487_465, engine: WhisperKitEngine()) { selection in
            asked.append(selection)
            return true
        }

        XCTAssertEqual(choice.loadOffer, WhisperKitModelLoadOffer(selection: small, sizeBytes: 486_487_465, isOnDisk: true))
        XCTAssertEqual(asked, [small])
    }

    func testRepickingTheLoadedModelOffersNothing() async throws {
        let engine = WhisperKitEngine()
        _ = try await installRecordingSource(on: engine)
        await engine.loadModel(for: small)
        XCTAssertEqual(engine.modelState, .loaded, "Precondition: the model is loaded")
        let choice = WhisperKitModelChoice()

        choice.offerLoad(for: small, sizeBytes: 486_487_465, engine: engine) { _ in true }

        XCTAssertNil(choice.loadOffer)
    }

    // MARK: - Load now / Later

    /// The settings observer applies a pick a main-actor turn later, so the engine
    /// can still request the previous model when "Load now" runs.
    func testAcceptLoadsExactlyTheOfferedModelWhileTheEngineHeldAnother() async throws {
        let engine = WhisperKitEngine()
        let recorder = try await installRecordingSource(on: engine)
        await engine.loadModel(for: turbo)
        XCTAssertEqual(engine.modelState, .loaded, "Precondition: another model is loaded")
        let choice = WhisperKitModelChoice()
        choice.offerLoad(for: swissGerman, sizeBytes: nil, engine: engine) { _ in false }
        let offer = try XCTUnwrap(choice.loadOffer)

        await choice.accept(offer, engine: engine).value

        XCTAssertNil(choice.loadOffer)
        XCTAssertEqual(recorder.loads, [turbo, swissGerman])
        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(WhisperKitModelSelection(variant: engine.modelVariant, origin: engine.modelOrigin), swissGerman)
    }

    func testDeclineClearsTheOfferAndLoadsNothing() async throws {
        let engine = WhisperKitEngine()
        let recorder = try await installRecordingSource(on: engine)
        let choice = WhisperKitModelChoice()
        choice.offerLoad(for: small, sizeBytes: 486_487_465, engine: engine) { _ in false }

        choice.decline()

        XCTAssertNil(choice.loadOffer)
        XCTAssertEqual(recorder.loads, [])
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    // MARK: - Production lookup and the stock table

    func testOnlyAPickedFolderOrACompleteDownloadCountsAsOnDisk() {
        let folder = WhisperKitModelSelection(variant: "model", origin: .localFolder(path: "/nonexistent/model", bookmark: nil))
        let absent = WhisperKitModelSelection(variant: "no-such-variant", origin: .hub(repoID: "test-owner/no-such-repo-\(UUID().uuidString)"))

        XCTAssertTrue(WhisperKitModelChoice.isOnDiskInProduction(folder))
        XCTAssertFalse(WhisperKitModelChoice.isOnDiskInProduction(absent))
    }

    func testTheStockTableListsThePickerEntriesInOrderWithASize() {
        XCTAssertEqual(
            WhisperKitStockModel.all.map(\.variant),
            [
                "openai_whisper-large-v3-v20240930_turbo",
                "openai_whisper-large-v3-v20240930",
                "openai_whisper-large-v2",
                "openai_whisper-small",
                "openai_whisper-base",
                "openai_whisper-tiny",
            ],
        )
        XCTAssertTrue(WhisperKitStockModel.all.allSatisfy { $0.approximateBytes > 0 })
        XCTAssertEqual(WhisperKitStockModel.model(for: "openai_whisper-small")?.approximateBytes, 486_487_465)
        XCTAssertNil(WhisperKitStockModel.model(for: "flix-swissgerman-large-v3_8bit"))
    }
}
