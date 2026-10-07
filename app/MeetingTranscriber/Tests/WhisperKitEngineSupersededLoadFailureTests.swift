@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// `WhisperKitEngine.lastLoadFailure` describes the current selection only. A load
/// that was superseded while it ran must not record its refusal under the model
/// the user has since chosen. Its own file because `WhisperKitEngineModelSourceTests`
/// is at the file-length cap.
@MainActor
final class WhisperKitEngineSupersededLoadFailureTests: XCTestCase {
    /// Model A's load is parked in its download when the user selects model B, which
    /// clears the failure line, and the load's owner is cancelled. A's download then
    /// comes back refused. The cancelled chain never tries B, so a failure recorded
    /// here would sit under B's "Load Model" and describe a model that is no longer
    /// selected.
    func testASupersededLoadDoesNotRecordItsRefusalUnderTheNewModel() async {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let parked = expectation(description: "load parked in download")
        let gate = MainActorGate()
        engine.installModelSourceForTesting(
            WhisperKitModelSource(
                locateLocal: { _ in nil },
                download: { _, _ in
                    parked.fulfill()
                    await gate.wait()
                    throw WhisperKitLoadFailure.tokenRejected
                },
                makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
            ),
        )

        let loader = Task { @MainActor in await engine.loadModel() }
        await fulfillment(of: [parked], timeout: 2)
        engine.applyModelVariant("openai_whisper-tiny")
        XCTAssertNil(engine.lastLoadFailure, "Precondition: the model change cleared it")
        loader.cancel()
        gate.open()
        await loader.value

        XCTAssertNil(
            engine.lastLoadFailure,
            "A refusal for the superseded model must not be shown under the one selected since",
        )
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    /// The guard compares the selection, not the time: a load whose model is still the
    /// selected one records its refusal as before.
    func testALoadForTheCurrentModelStillRecordsItsRefusal() async {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.installModelSourceForTesting(
            WhisperKitModelSource(
                locateLocal: { _ in nil },
                download: { _, _ in throw WhisperKitLoadFailure.tokenRejected },
                makePipe: { _, _ in throw WhisperError.modelsUnavailable() },
            ),
        )

        await engine.loadModel()

        XCTAssertEqual(engine.lastLoadFailure, .tokenRejected)
    }
}
