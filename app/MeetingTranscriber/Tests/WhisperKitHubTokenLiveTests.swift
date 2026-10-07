import Foundation
@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// Opt-in check, against the real Hugging Face Hub, that every request the WhisperKit
/// path makes carries the app's token and never the one the machine holds. Skipped
/// unless `MEETINGTRANSCRIBER_HF_LIVE=1`. Downloads `openai_whisper-tiny` (about
/// 70 MB) into WhisperKit's cache on first use; run it under a scratch
/// `CFFIXED_USER_HOME` with an empty Documents folder, so the tokenizer is not cached
/// yet and has to be fetched.
@MainActor
final class WhisperKitHubTokenLiveTests: XCTestCase {
    private let variant = "openai_whisper-tiny"

    /// Made-up tokens the Hub refuses. Measured: it ignores an unrecognised token on a
    /// public repository and answers 200, but refuses anything shaped like the OAuth
    /// token the `hf` CLI leaves behind with 401, on the API and on file downloads
    /// alike. Only that shape lets these tests fail.
    private let staleMachineToken = "hf_oauth_madeUpMachineToken000"
    private let madeUpAppToken = "hf_oauth_madeUpAppToken000"

    private func requireOptIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEETINGTRANSCRIBER_HF_LIVE"] == "1",
            "Set MEETINGTRANSCRIBER_HF_LIVE=1 to run the Hugging Face live tests",
        )
    }

    /// Where WhisperKit caches the tiny model's tokenizer when no tokenizer folder is
    /// configured, which is how the app builds its pipes.
    private var tokenizerFile: URL {
        WhisperTokenizerCache.searchPaths(repository: "openai/whisper-tiny", modelFolder: nil, tokenizerFolder: nil)[0]
            .appendingPathComponent("tokenizer.json")
    }

    /// The made-up token in `HF_TOKEN` is refused by the Hub (see the next test), so the
    /// load only succeeds if neither the download nor the tokenizer fetch sends it.
    func testAnEmptyTokenLoadsAnonymouslyWhileTheMachineHoldsAStaleOne() async throws {
        try requireOptIn()
        let previous = ProcessInfo.processInfo.environment["HF_TOKEN"]
        addTeardownBlock {
            if let previous { setenv("HF_TOKEN", previous, 1) } else { unsetenv("HF_TOKEN") }
        }
        setenv("HF_TOKEN", staleMachineToken, 1)
        let tokenizerCachedBefore = FileManager.default.fileExists(atPath: tokenizerFile.path)
        let source = WhisperKitModelSource.production(for: .stock) { "" }

        let folder = try await source.download(variant) { _ in }
        let pipe = try await source.makePipe(variant, folder)

        XCTAssertNotNil(pipe.tokenizer, "The pipe must come with its tokenizer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenizerFile.path), "The tokenizer must be cached now")
        print("[HFLive] anonymous: variant=\(variant) downloaded, tokenizerCachedBefore=\(tokenizerCachedBefore) "
            + "tokenizerLoaded=\(pipe.tokenizer != nil) with HF_TOKEN set to a made-up OAuth-shaped token")
    }

    func testAMadeUpTokenIsRefused() async throws {
        try requireOptIn()
        let token = madeUpAppToken
        let source = WhisperKitModelSource.production(for: .stock) { token }

        do {
            _ = try await source.download(variant) { _ in }
            XCTFail("The Hub must refuse a made-up token")
        } catch {
            XCTAssertEqual(error as? WhisperKitLoadFailure, .tokenRejected, "got \(String(reflecting: error))")
            print("[HFLive] made-up token: error=\(String(reflecting: error)) message=\(error.localizedDescription)")
        }
    }

    /// The tokenizer fetch inside the pipe construction is the other Hub request, and
    /// its refusal is named the same way. The cached tokenizer is removed first, so
    /// the fetch has to run.
    func testAMadeUpTokenIsRefusedAtTheTokenizerFetch() async throws {
        try requireOptIn()
        let folder = try await WhisperKitModelSource.production(for: .stock).download(variant) { _ in }
        try WhisperTokenizerCache.removeCachedTokenizer(in: tokenizerFile.deletingLastPathComponent())
        let token = madeUpAppToken
        let source = WhisperKitModelSource.production(for: .stock) { token }

        do {
            _ = try await source.makePipe(variant, folder)
            XCTFail("The Hub must refuse a made-up token for the tokenizer")
        } catch {
            XCTAssertEqual(error as? WhisperKitLoadFailure, .tokenRejected, "got \(String(reflecting: error))")
            print("[HFLive] tokenizer fetch, made-up token: error=\(String(reflecting: error))")
        }
    }
}
