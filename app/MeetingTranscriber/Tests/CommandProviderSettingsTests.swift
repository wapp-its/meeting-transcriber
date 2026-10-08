@testable import MeetingTranscriber
import XCTest

/// Settings of the Codex CLI and custom command providers. In a file of its
/// own because `AppSettingsTests` sits at the 600-line cap; same per-test
/// defaults suite convention, so `--parallel` runs never share state.
final class CommandProviderSettingsTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CommandProviderSettingsTests-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    #if APPSTORE
        /// The App Store build has neither provider: a value stored by the
        /// Homebrew build falls back to the default provider.
        func testStoredCommandProviderFallsBackToOpenAICompatible() {
            for stored in ["codexCLI", "customCommand"] {
                defaults.set(stored, forKey: "protocolProvider")

                XCTAssertEqual(AppSettings(defaults: defaults).protocolProvider, .openAICompatible, stored)
            }
        }
    #else
        func testDefaults() {
            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.customCommandArguments, [])
            XCTAssertEqual(settings.customCommandModel, "")
            XCTAssertEqual(settings.customCommandText, "")
        }

        func testProvidersAndCommandPersist() {
            let settings = AppSettings(defaults: defaults)
            settings.protocolProvider = .customCommand
            settings.customCommandArguments = ["  ollama", "run", "", "{model} "]
            settings.customCommandModel = "qwen3:32b"

            let fresh = AppSettings(defaults: defaults)
            XCTAssertEqual(fresh.protocolProvider, .customCommand)
            XCTAssertEqual(fresh.customCommandArguments, ["  ollama", "run", "", "{model} "])
            XCTAssertEqual(fresh.customCommandModel, "qwen3:32b")

            settings.protocolProvider = .codexCLI
            XCTAssertEqual(AppSettings(defaults: defaults).protocolProvider, .codexCLI)
        }

        func testCustomCommandTextRoundTripsLosslessly() {
            let settings = AppSettings(defaults: defaults)

            settings.customCommandText = "ollama\nrun\n"
            XCTAssertEqual(settings.customCommandArguments, ["ollama", "run", ""])
            XCTAssertEqual(settings.customCommandText, "ollama\nrun\n")

            settings.customCommandArguments = ["mlx_lm.generate", " --prompt-file ", "{prompt_file}"]
            XCTAssertEqual(settings.customCommandText, "mlx_lm.generate\n --prompt-file \n{prompt_file}")
        }

        func testProviderOrderAndLabels() {
            XCTAssertEqual(ProtocolProvider.allCases, [.claudeCLI, .codexCLI, .customCommand, .openAICompatible, .none])
            XCTAssertEqual(ProtocolProvider.codexCLI.label, "Codex CLI")
            XCTAssertEqual(ProtocolProvider.customCommand.label, "Custom Command")
        }
    #endif
}
