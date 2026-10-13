import Foundation

/// One of the WhisperKit variants the model picker offers from the stock repository
/// (`WhisperKitModelOrigin.stock`).
struct WhisperKitStockModel: Equatable {
    let variant: String
    let label: String
    /// The variant folder's total size on the Hub, measured on 2026-10-06. Shown as
    /// approximate, since argmax can republish a variant at another size.
    let approximateBytes: Int64

    /// In picker order.
    static let all: [Self] = [
        Self(variant: "openai_whisper-large-v3-v20240930_turbo", label: "Large V3 Turbo (recommended)", approximateBytes: 1_638_464_446),
        Self(variant: "openai_whisper-large-v3-v20240930", label: "Large V3", approximateBytes: 1_619_531_263),
        Self(variant: "openai_whisper-large-v2", label: "Large V2", approximateBytes: 3_090_028_051),
        Self(variant: "openai_whisper-small", label: "Small", approximateBytes: 486_487_465),
        Self(variant: "openai_whisper-base", label: "Base", approximateBytes: 146_719_453),
        Self(variant: "openai_whisper-tiny", label: "Tiny", approximateBytes: 76_635_397),
    ]

    /// The stock entry for `variant`, or nil when it is not one of them.
    static func model(for variant: String) -> Self? {
        all.first { $0.variant == variant }
    }
}
