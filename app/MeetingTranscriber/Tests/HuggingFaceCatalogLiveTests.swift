import Foundation
@testable import MeetingTranscriber
import XCTest

/// Opt-in check of the catalog against the live Hugging Face API: searching "swiss"
/// finds `spert/flix-swissgerman-whisperkit`, and its listing shows
/// `flix-swissgerman-large-v3_8bit` with a size and a license.
/// Skipped unless `MEETINGTRANSCRIBER_HF_LIVE_TESTS=1`; anonymous, one request each.
final class HuggingFaceCatalogLiveTests: XCTestCase {
    private static let repoID = "spert/flix-swissgerman-whisperkit"

    private func skipUnlessLive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEETINGTRANSCRIBER_HF_LIVE_TESTS"] == "1",
            "Set MEETINGTRANSCRIBER_HF_LIVE_TESTS=1 to query huggingface.co",
        )
    }

    func testLiveSearchForSwissFindsTheSwissGermanModel() async throws {
        try skipUnlessLive()
        let results = try await HuggingFaceModelCatalog().searchWhisperKitModels(matching: "swiss", token: nil)

        XCTAssertTrue(results.contains { $0.id == Self.repoID }, "\(results.map(\.id))")
    }

    func testLiveListingHasTheLargeVariantWithItsSizeUnderApache() async throws {
        try skipUnlessLive()
        let listing = try await HuggingFaceModelCatalog().repository(Self.repoID, token: nil)

        let variant = try XCTUnwrap(listing.variants.first { $0.name == "flix-swissgerman-large-v3_8bit" }, "\(listing.variants)")
        XCTAssertGreaterThan(try XCTUnwrap(variant.sizeBytes), 1_000_000_000)
        XCTAssertEqual(listing.license?.label, "Apache 2.0")
    }
}
