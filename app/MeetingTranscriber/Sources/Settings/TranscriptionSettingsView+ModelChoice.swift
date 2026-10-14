import SwiftUI

/// The load offer after a model pick, the Hugging Face browser, and the "Load Model"
/// button's action. Kept out of `TranscriptionSettingsView.swift`, whose body is close
/// to the 300 ms type-check limit CI enforces and whose type body is close to
/// SwiftLint's length limit.
extension TranscriptionSettingsView {
    /// Picker tag of the "From Hugging Face…" entry. Never stored: picking it opens
    /// the browser and writes nothing, so the picker keeps showing the current model.
    static let huggingFaceTag = "huggingface"

    /// "From Hugging Face…". The token is read for each request, not here, so the
    /// Keychain is read only when a search runs and a token saved while the browser is
    /// open applies to its next request.
    func openHuggingFaceBrowser() {
        let settings = settings
        modelChoice.hubBrowser = HuggingFaceModelSearch(catalog: makeHubCatalog()) { settings.huggingFaceToken }
    }

    /// "Use" on a variant in the Hugging Face browser.
    func useHubVariant(_ variant: HuggingFaceModelVariant, in listing: HuggingFaceRepositoryListing) {
        modelChoice.use(variant, in: listing, settings: settings, engine: whisperKitEngine, isOnDisk: isModelOnDisk)
    }

    /// Called by the model picker after it wrote the stock `variant`.
    func offerLoad(afterPicking variant: String) {
        modelChoice.offerLoad(
            for: settings.whisperKitModelSelection,
            sizeBytes: WhisperKitStockModel.model(for: variant)?.approximateBytes,
            engine: whisperKitEngine,
            isOnDisk: isModelOnDisk,
        )
    }

    /// "Load Model". WhisperKit loads through the same helper as "Load now", which
    /// applies the current selection before loading.
    func loadSelectedModel() {
        switch settings.transcriptionEngine {
        case .whisperKit:
            let selection = settings.whisperKitModelSelection
            Task { await whisperKitEngine.loadModel(for: selection) }

        case .parakeet:
            Task { await parakeetEngine.loadModel() }
        }
    }
}

extension View {
    /// Presents `choice`'s Hugging Face browser. "Use" goes to `onUse` and "Cancel" only
    /// closes it; once it has closed, `choice` asks the question a "Use" held back.
    func huggingFaceBrowserSheet(
        _ choice: WhisperKitModelChoice,
        onUse: @escaping (HuggingFaceModelVariant, HuggingFaceRepositoryListing) -> Void,
    ) -> some View {
        sheet(
            item: Bindable(choice).hubBrowser,
            onDismiss: { choice.browserDidDismiss() },
            content: { search in
                HuggingFaceModelBrowserView(search: search, onUse: onUse) { choice.hubBrowser = nil }
            },
        )
    }

    /// Presents `choice`'s pending load offer. Its buttons act through
    /// `WhisperKitModelChoice`, where they are tested; the alert itself is manual QA.
    func whisperKitLoadOfferAlert(_ choice: WhisperKitModelChoice, engine: WhisperKitEngine) -> some View {
        alert(
            WhisperKitModelLoadOffer.title,
            isPresented: Binding(
                get: { choice.loadOffer != nil },
                set: { isPresented in
                    if !isPresented { choice.decline() }
                },
            ),
            presenting: choice.loadOffer,
        ) { offer in
            Button("Load now") { choice.accept(offer, engine: engine) }
            Button("Later", role: .cancel) { choice.loadLater(offer, engine: engine) }
        } message: { offer in
            Text(offer.message)
        }
    }
}
