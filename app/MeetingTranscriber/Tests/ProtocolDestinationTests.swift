@testable import MeetingTranscriber
import XCTest

/// Where background info goes, per provider and endpoint, and the sentence each
/// options window shows for it (spec R6, A9).
final class ProtocolDestinationTests: XCTestCase {
    func testOpenAICompatibleEndpointIsLocalOnlyForALoopbackHost() {
        let cases: [(String, ProtocolDestination)] = [
            ("http://localhost:11434/v1", .local(host: "localhost")),
            ("http://127.0.0.1:1234/v1", .local(host: "127.0.0.1")),
            ("http://[::1]:8080/v1", .local(host: "::1")),
            ("https://api.example.com/v1", .remote(name: "api.example.com")),
            ("http://127.example.com/v1", .remote(name: "127.example.com")),
            ("localhost:11434/v1", .remote(name: "the configured endpoint")),
            ("not a url", .remote(name: "the configured endpoint")),
        ]
        for (endpoint, expected) in cases {
            XCTAssertEqual(
                ProtocolDestination.resolve(provider: .openAICompatible, openAIEndpoint: endpoint), expected, endpoint,
            )
        }
    }

    func testNoProviderIsOff() {
        XCTAssertEqual(ProtocolDestination.resolve(provider: .none, openAIEndpoint: "http://localhost:11434/v1"), .off)
    }

    #if !APPSTORE
        func testCommandLineProvidersAreRemote() {
            let cases: [(ProtocolProvider, String)] = [
                (.claudeCLI, "Anthropic (Claude)"),
                (.codexCLI, "OpenAI (Codex)"),
                (.customCommand, "the custom command set in Settings → Output"),
            ]
            for (provider, name) in cases {
                XCTAssertEqual(
                    ProtocolDestination.resolve(provider: provider, openAIEndpoint: "http://localhost:11434/v1"),
                    .remote(name: name),
                )
            }
        }
    #endif

    func testNoticeSentences() {
        XCTAssertEqual(
            ProtocolDestination.remote(name: "Anthropic (Claude)").notice,
            "Background info is sent with the transcript to Anthropic (Claude) to write the protocol.",
        )
        XCTAssertEqual(
            ProtocolDestination.local(host: "localhost").notice,
            "Background info stays on this Mac: it goes with the transcript to the local model at localhost.",
        )
        XCTAssertEqual(
            ProtocolDestination.off.notice,
            "Protocol generation is off (Settings → Output), so the template and background info are not used.",
        )
    }
}
