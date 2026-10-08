#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The Transcriptions window lists meeting titles and participants, so no
    /// debug RPC endpoint may capture it, walk its accessibility tree, press its
    /// buttons or type into it. Adding its id to any of these allowlists is the
    /// change this test exists to stop.
    final class TranscriptionsWindowPrivacyTests: XCTestCase {
        func testTheWindowIsOnNoDebugRPCWindowAllowlist() {
            let allowlists: [(endpoint: String, windowIDs: Set<String>)] = [
                ("/screenshot", DebugRPCServer.screenshotAllowedWindowIDs),
                ("/ui/tree", DebugRPCServer.uiTreeAllowedWindowIDs),
                ("/ui/press", DebugRPCServer.uiPressAllowedWindowIDs),
                ("/ui/type", DebugRPCServer.uiTypeAllowedWindowIDs),
            ]
            for allowlist in allowlists {
                XCTAssertFalse(
                    allowlist.windowIDs.contains(TranscriptionsView.windowID),
                    "\(allowlist.endpoint) admits the Transcriptions window",
                )
            }
        }
    }
#endif
