@testable import ArgmaxCore
@testable import MeetingTranscriber
import XCTest

/// How the app's Hugging Face token reaches the Hub client, and how a refused one is
/// recognised. Nothing here touches the network.
@MainActor
final class WhisperKitHubTokenTests: XCTestCase {
    /// Stand-in for any failure that is not a refused token.
    private struct Unreachable: Error {}

    func testRejectedTokenMatchesWhisperKitsOwnError() {
        XCTAssertTrue(WhisperKitModelSource.isRejectedToken(Hub.HubClientError.authorizationRequired))
    }

    func testOtherHubErrorsAreNotARejectedToken() {
        XCTAssertFalse(WhisperKitModelSource.isRejectedToken(Hub.HubClientError.httpStatusCode(401)))
        XCTAssertFalse(WhisperKitModelSource.isRejectedToken(Hub.HubClientError.fileNotFound("x")))
        XCTAssertFalse(WhisperKitModelSource.isRejectedToken(Unreachable()))
    }

    /// "Empty means anonymous" rests on this: the Hub client looks the machine's token
    /// up only for `nil`, and an empty string keeps it out. The first assertion proves
    /// the lookup is live in this process, so the second one is not vacuous.
    func testAnEmptyTokenKeepsTheMachinesTokenOut() {
        let previous = ProcessInfo.processInfo.environment["HF_TOKEN"]
        addTeardownBlock {
            if let previous { setenv("HF_TOKEN", previous, 1) } else { unsetenv("HF_TOKEN") }
        }
        let planted = "hf_plantedByWhisperKitHubTokenTests"
        setenv("HF_TOKEN", planted, 1)

        XCTAssertEqual(HubApiWrapper(hfToken: nil).hubApi.hfToken, planted)
        XCTAssertEqual(HubApiWrapper(hfToken: "").hubApi.hfToken, "")
    }
}
