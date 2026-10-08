@testable import MeetingTranscriber
import XCTest

/// The `POST /v1/record` body. `scope: "any"` widens a `stop` to whatever is
/// recording, and nothing else may carry it: every body that fails to decode
/// here is a 400 at the route, so a misspelt or misplaced scope is never read
/// as `any`.
final class RecordActionPayloadTests: XCTestCase {
    func testScopeAnyDecodesOnAStop() throws {
        let payload = try decode(#"{"action":"stop","scope":"any"}"#)

        XCTAssertEqual(payload.action, .stop)
        XCTAssertEqual(payload.scope, .any)
    }

    func testAPlainStopCarriesNoScope() throws {
        let payload = try decode(#"{"action":"stop"}"#)

        XCTAssertEqual(payload.action, .stop)
        XCTAssertNil(payload.scope)
    }

    func testAnUnknownScopeOrAScopeOnAnotherVerbFailsToDecode() {
        for body in [
            #"{"action":"stop","scope":"all"}"#,
            #"{"action":"start","scope":"any"}"#,
            #"{"action":"toggle","scope":"any"}"#,
        ] {
            XCTAssertThrowsError(try decode(body), body)
        }
    }

    private func decode(_ json: String) throws -> RecordActionPayload {
        try JSONDecoder().decode(RecordActionPayload.self, from: Data(json.utf8))
    }
}
