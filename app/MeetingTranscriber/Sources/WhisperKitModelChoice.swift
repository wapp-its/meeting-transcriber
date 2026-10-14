import Foundation
import Observation

/// The question asked right after a new WhisperKit model was chosen in Settings:
/// load it now, or leave it to the first transcription.
struct WhisperKitModelLoadOffer: Equatable {
    static let title = "Load the new model now?"

    let selection: WhisperKitModelSelection
    /// The model's approximate download size, nil when it is not known.
    let sizeBytes: Int64?
    /// Whether a complete copy is already on this Mac, so loading downloads nothing.
    let isOnDisk: Bool

    var message: String {
        if isOnDisk {
            return "The model is already on this Mac; loading takes up to a minute."
        }
        guard let sizeBytes else {
            return "It is downloaded once and takes a few minutes; afterwards it loads offline."
        }
        let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return "About \(size), downloaded once. This takes a few minutes; afterwards the model loads offline."
    }
}

/// State of the WhisperKit model choice in Settings: the open Hugging Face browser and
/// the pending load offer.
///
/// A reference type owned by `SettingsView`, so the offer survives the body
/// re-evaluations that a settings write causes, and so a test holds the same object
/// the picker writes to (CLAUDE.md, GUI Testing, rung 2).
@Observable
@MainActor
final class WhisperKitModelChoice {
    private(set) var loadOffer: WhisperKitModelLoadOffer?

    /// The Hugging Face browser the picker presents as a sheet; nil while none is open.
    /// "From Hugging Face…" opens it, "Use" and "Cancel" close it.
    var hubBrowser: HuggingFaceModelSearch?

    /// The offer a "Use" made, held back until the browser has closed: an alert
    /// presented while a sheet is still being dismissed can be dropped on macOS.
    private(set) var pendingLoadOffer: WhisperKitModelLoadOffer?

    /// Offer to load `selection`, unless the engine already loads or holds exactly it.
    /// `isOnDisk` is asked only when an offer is made. An offered model is deferred on
    /// the engine until the answer, so a load still running for the previous model
    /// cannot go on to it while the question is open; "Load now" lifts that.
    func offerLoad(
        for selection: WhisperKitModelSelection,
        sizeBytes: Int64?,
        engine: WhisperKitEngine,
        isOnDisk: (WhisperKitModelSelection) -> Bool,
    ) {
        if let offer = makeOffer(for: selection, sizeBytes: sizeBytes, engine: engine, isOnDisk: isOnDisk) {
            loadOffer = offer
        }
    }

    /// "Use" in the Hugging Face browser: writes `variant` of `listing` to `settings`,
    /// closes the browser and holds the offer for the resulting model back until
    /// `browserDidDismiss()`. The offer names the listed variant's size.
    func use(
        _ variant: HuggingFaceModelVariant,
        in listing: HuggingFaceRepositoryListing,
        settings: AppSettings,
        engine: WhisperKitEngine,
        isOnDisk: (WhisperKitModelSelection) -> Bool,
    ) {
        settings.useHubModel(repoID: listing.id, variant: variant.name)
        pendingLoadOffer = makeOffer(
            for: settings.whisperKitModelSelection,
            sizeBytes: variant.sizeBytes,
            engine: engine,
            isOnDisk: isOnDisk,
        )
        hubBrowser = nil
    }

    /// The browser sheet has closed: asks the question a "Use" held back, if any.
    func browserDidDismiss() {
        guard let offer = pendingLoadOffer else { return }
        pendingLoadOffer = nil
        loadOffer = offer
    }

    /// The offer for `selection`, deferring it on the engine, or nil when `shouldOffer`
    /// says no.
    private func makeOffer(
        for selection: WhisperKitModelSelection,
        sizeBytes: Int64?,
        engine: WhisperKitEngine,
        isOnDisk: (WhisperKitModelSelection) -> Bool,
    ) -> WhisperKitModelLoadOffer? {
        guard Self.shouldOffer(
            chosen: selection,
            engineVariant: engine.modelVariant,
            engineOrigin: engine.modelOrigin,
            engineState: engine.modelState,
        ) else { return nil }
        engine.deferredSelection = selection
        return WhisperKitModelLoadOffer(selection: selection, sizeBytes: sizeBytes, isOnDisk: isOnDisk(selection))
    }

    /// False only when the engine already requests exactly `chosen` and has it loaded
    /// or is loading it. The engine's request may still be the previous model when
    /// this runs, because the settings observer applies a change a main-actor turn
    /// later, so a different model always reads as a change.
    static func shouldOffer(
        chosen: WhisperKitModelSelection,
        engineVariant: String,
        engineOrigin: WhisperKitModelOrigin,
        engineState: EngineModelState,
    ) -> Bool {
        let engineRequestsChosen = chosen.variant == engineVariant && chosen.origin == engineOrigin
        return !engineRequestsChosen || engineState == .unloaded
    }

    /// "Load now". Loads the offer it is given, not whatever `loadOffer` holds by the
    /// time the alert's button runs, since dismissing the alert declines it first.
    @discardableResult
    func accept(_ offer: WhisperKitModelLoadOffer, engine: WhisperKitEngine) -> Task<Void, Never> {
        loadOffer = nil
        return Task { await engine.loadModel(for: offer.selection) }
    }

    /// "Later": the model loads on first use, as without the offer. A load still
    /// running for the previous model stops when it finishes instead of going on to
    /// this one. The offer already deferred it; this keeps it deferred.
    func loadLater(_ offer: WhisperKitModelLoadOffer, engine: WhisperKitEngine) {
        loadOffer = nil
        engine.deferredSelection = offer.selection
    }

    /// The alert was dismissed, which SwiftUI also does around either button's action.
    func decline() {
        loadOffer = nil
    }

    /// Whether a complete copy of `selection` is on this Mac. A picked folder is on
    /// disk by definition; a Hub model is looked up where its download would put it.
    nonisolated static func isOnDiskInProduction(_ selection: WhisperKitModelSelection) -> Bool {
        switch selection.origin {
        case let .hub(repoID):
            WhisperKitLocalSnapshot.locate(
                variant: selection.variant,
                in: WhisperKitLocalSnapshot.repoRoot(for: repoID),
            ) != nil

        case .localFolder:
            true
        }
    }
}

extension WhisperKitEngine {
    /// Load `selection`, applying it to the engine first. The settings observer
    /// reaches the engine a main-actor turn after a settings write, so a load started
    /// right after one would otherwise load the previous model. Shared by "Load now"
    /// and the "Load Model" button, which also overrule an earlier "Later".
    func loadModel(for selection: WhisperKitModelSelection) async {
        deferredSelection = nil
        applyModelVariant(selection.variant, origin: selection.origin)
        await loadModel()
    }
}
