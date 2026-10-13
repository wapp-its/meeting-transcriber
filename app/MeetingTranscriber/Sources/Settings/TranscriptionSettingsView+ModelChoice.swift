import SwiftUI

/// The load offer after a model pick, and the "Load Model" button's action. Kept out
/// of `TranscriptionSettingsView.swift`, whose body is close to the 300 ms type-check
/// limit CI enforces and whose type body is close to SwiftLint's length limit.
extension TranscriptionSettingsView {
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
