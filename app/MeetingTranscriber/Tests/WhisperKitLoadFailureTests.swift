@testable import ArgmaxCore
@testable import MeetingTranscriber
import XCTest

/// Which failed Hub requests get a message of their own, and the exact words. The
/// refusal is matched by the Hub error's reflected name, so these tests also pin
/// that name against WhisperKit's own type.
final class WhisperKitLoadFailureTests: XCTestCase {
    /// Stand-in for any failure that has nothing to do with the Hub.
    private struct Unrelated: Error {}

    func testARefusedRequestIsNamedByWhetherATokenWasSent() {
        XCTAssertEqual(WhisperKitLoadFailure.classify(Hub.HubClientError.authorizationRequired, tokenSent: true), .tokenRejected)
        XCTAssertEqual(WhisperKitLoadFailure.classify(Hub.HubClientError.authorizationRequired, tokenSent: false), .tokenRequired)
    }

    /// `httpStatusCode(401)` included: the Hub client turns a 401 or 403 into
    /// `authorizationRequired` itself, so a status code reaching the app is some
    /// other failure.
    func testAnyOtherFailureIsNotClassified() {
        let others: [any Error] = [
            Hub.HubClientError.httpStatusCode(401),
            Hub.HubClientError.httpStatusCode(500),
            Hub.HubClientError.fileNotFound("x"),
            URLError(.notConnectedToInternet),
            Unrelated(),
        ]
        for error in others {
            for tokenSent in [true, false] {
                XCTAssertNil(
                    WhisperKitLoadFailure.classify(error, tokenSent: tokenSent),
                    "\(String(reflecting: error)), tokenSent: \(tokenSent)",
                )
            }
        }
    }

    /// The message is what a failed job carries as its error text, which is the
    /// error's `localizedDescription`.
    func testEachFailureCarriesTheExactMessage() {
        let expected: [(WhisperKitLoadFailure, String)] = [
            (
                .tokenRejected,
                "Hugging Face rejected the saved token. Check that it is valid and has access to this model, "
                    + "or remove it to download anonymously.",
            ),
            (
                .tokenRequired,
                "Hugging Face refused access without a token. The model may be private or gated "
                    + "(save a token under Hugging Face token), or its name may be wrong.",
            ),
        ]
        for (failure, message) in expected {
            XCTAssertEqual(failure.errorDescription, message)
            XCTAssertEqual((failure as any Error).localizedDescription, message)
        }
    }
}
