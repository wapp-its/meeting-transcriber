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

    /// What the engine reported, and the offer made, while a load was in flight.
    private final class InFlightProbe {
        var engineState: EngineModelState?
        var offer: WhisperKitModelLoadOffer?
    }

    /// Install a source that loads every model from a temporary folder into a
    /// WhisperKit instance that loads nothing (`WhisperKitEngineModelOriginTests`).
    /// `onPipe` runs while a model is being built, so with the engine `.loading`.
    private func installRecordingSource(
        on engine: WhisperKitEngine,
        onPipe: (@MainActor (WhisperKitModelSelection) async -> Void)? = nil,
    ) async throws -> LoadRecorder {
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
                makePipe: { variant, _ in
                    await onPipe?(WhisperKitModelSelection(variant: variant, origin: origin))
                    return pipe
                },
            )
        }
        return recorder
    }

    // MARK: - When to offer

    func testShouldOfferOnlyWhenTheChosenModelIsNotAlreadyLoadedOrLoading() {
        let smallFromAnotherRepository = WhisperKitModelSelection(variant: small.variant, origin: swissGerman.origin)
        let cases: [(engine: WhisperKitModelSelection, state: EngineModelState, expected: Bool, why: String)] = [
            (turbo, .loaded, true, "another variant is loaded"),
            (turbo, .unloaded, true, "another variant is requested but not loaded"),
            (turbo, .downloading, true, "another variant is downloading"),
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

    /// A load already running when the pick lands (the launch preload, say) would go
    /// on to the picked model once it finishes. "Later" stops it there. The picker's
    /// order is kept: the offer is made first, the settings observer applies the pick
    /// to the engine a main-actor turn later, and the user answers after that.
    func testLaterDuringALoadStopsItBeforeThePickedModel() async throws {
        let engine = WhisperKitEngine()
        let choice = WhisperKitModelChoice()
        let probe = InFlightProbe()
        let small = small
        let recorder = try await installRecordingSource(on: engine) { [turbo] loading in
            guard loading == turbo else { return }
            probe.engineState = engine.modelState
            choice.offerLoad(for: small, sizeBytes: 486_487_465, engine: engine) { _ in false }
            engine.applyModelVariant(small.variant, origin: small.origin)
            probe.offer = choice.loadOffer
            if let offer = choice.loadOffer { choice.loadLater(offer, engine: engine) }
        }

        await engine.loadModel(for: turbo)

        XCTAssertEqual(probe.engineState, .loading, "Precondition: the pick landed while a load was in flight")
        XCTAssertEqual(probe.offer?.selection, small, "A pick during a load still asks")
        XCTAssertNil(choice.loadOffer)
        XCTAssertEqual(recorder.loads, [turbo], "The picked model must wait for its first use")
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertEqual(WhisperKitModelSelection(variant: engine.modelVariant, origin: engine.modelOrigin), small)
    }

    /// The running load can finish while the question is still open, here the second
    /// of two picks made during one long load. Until the user answers, the pick must
    /// not start loading, or "Later" would come too late to stop it.
    func testAPickStaysUnloadedWhileItsQuestionIsOpen() async throws {
        let engine = WhisperKitEngine()
        let choice = WhisperKitModelChoice()
        let probe = InFlightProbe()
        let small = small
        let swissGerman = swissGerman
        let recorder = try await installRecordingSource(on: engine) { [turbo] loading in
            guard loading == turbo else { return }
            choice.offerLoad(for: small, sizeBytes: 486_487_465, engine: engine) { _ in false }
            engine.applyModelVariant(small.variant, origin: small.origin)
            if let offer = choice.loadOffer { choice.loadLater(offer, engine: engine) }
            choice.offerLoad(for: swissGerman, sizeBytes: nil, engine: engine) { _ in false }
            engine.applyModelVariant(swissGerman.variant, origin: swissGerman.origin)
            probe.offer = choice.loadOffer
        }

        await engine.loadModel(for: turbo)
        XCTAssertEqual(recorder.loads, [turbo], "Nothing may load while the second question is open")
        let offer = try XCTUnwrap(probe.offer)
        XCTAssertEqual(offer.selection, swissGerman)
        choice.loadLater(offer, engine: engine)

        XCTAssertEqual(recorder.loads, [turbo])
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    /// "Later" never holds up a transcription: the first use loads the deferred model.
    /// The audio does not exist, so the decode fails after the load; only the load is
    /// under test.
    func testATranscriptionLoadsADeferredModel() async throws {
        let engine = WhisperKitEngine()
        let recorder = try await installRecordingSource(on: engine)
        engine.applyModelVariant(small.variant, origin: small.origin)
        engine.deferredSelection = small

        _ = try? await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/nonexistent/wk-choice-audio.wav"))

        XCTAssertEqual(recorder.loads, [small])
        XCTAssertEqual(engine.modelState, .loaded)
    }

    /// "Load Model" after "Later" loads the model the user just deferred.
    func testAnExplicitLoadOverrulesLater() async throws {
        let engine = WhisperKitEngine()
        let recorder = try await installRecordingSource(on: engine)
        let choice = WhisperKitModelChoice()
        choice.offerLoad(for: small, sizeBytes: 486_487_465, engine: engine) { _ in false }
        engine.applyModelVariant(small.variant, origin: small.origin)
        let offer = try XCTUnwrap(choice.loadOffer)
        choice.loadLater(offer, engine: engine)
        await engine.loadModel()
        XCTAssertEqual(recorder.loads, [], "Precondition: a preload leaves the deferred model alone")

        await engine.loadModel(for: small)

        XCTAssertEqual(recorder.loads, [small])
        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertNil(engine.deferredSelection)
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
