@testable import MeetingTranscriber
import XCTest

/// What the load offer says, per case. The size is compared against
/// `ByteCountFormatter` itself, never a literal, since its output follows the locale.
final class WhisperKitModelLoadOfferTests: XCTestCase {
    private let small = WhisperKitModelSelection(variant: "openai_whisper-small", origin: .stock)

    func testAModelOnThisMacSaysLoadingTakesUpToAMinute() {
        let offer = WhisperKitModelLoadOffer(selection: small, sizeBytes: 486_487_465, isOnDisk: true)

        XCTAssertEqual(offer.message, "The model is already on this Mac; loading takes up to a minute.")
    }

    func testAModelToDownloadNamesItsSize() {
        let offer = WhisperKitModelLoadOffer(selection: small, sizeBytes: 486_487_465, isOnDisk: false)
        let size = ByteCountFormatter.string(fromByteCount: 486_487_465, countStyle: .file)

        XCTAssertEqual(
            offer.message,
            "About \(size), downloaded once. This takes a few minutes; afterwards the model loads offline.",
        )
    }

    func testAModelToDownloadWithoutAKnownSizeNamesNone() {
        let offer = WhisperKitModelLoadOffer(selection: small, sizeBytes: nil, isOnDisk: false)

        XCTAssertEqual(offer.message, "It is downloaded once and takes a few minutes; afterwards it loads offline.")
    }
}
