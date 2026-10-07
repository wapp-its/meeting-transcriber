#if !APPSTORE

    import AppKit
    @testable import MeetingTranscriber
    import SwiftUI
    import ViewInspector
    import XCTest

    /// Settings → Output for the Codex CLI and custom command providers: one
    /// wiring test per control, found by its `A11yID`, and what each provider
    /// shows.
    @MainActor
    final class CommandProviderSettingsViewTests: XCTestCase {
        // swiftlint:disable implicitly_unwrapped_optional
        private var defaults: UserDefaults!
        private var suiteName: String!
        // swiftlint:enable implicitly_unwrapped_optional

        override func setUp() async throws {
            try await super.setUp()
            suiteName = "CommandProviderSettingsViewTests-\(getpid())-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }

        override func tearDown() async throws {
            DefaultsSuite.remove(suiteName)
            defaults = nil
            suiteName = nil
            try await super.tearDown()
        }

        private func makeSettings(_ provider: ProtocolProvider) -> AppSettings {
            let settings = AppSettings(defaults: defaults)
            settings.protocolProvider = provider
            return settings
        }

        func testProviderPickerSelectsCustomCommand() throws {
            let settings = makeSettings(.openAICompatible)
            let picker = try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.protocolProviderPicker)
                .find(ViewType.Picker.self)

            try picker.select(value: ProtocolProvider.customCommand)

            XCTAssertEqual(settings.protocolProvider, .customCommand)
        }

        func testCommandEditorWritesOneArgumentPerLine() throws {
            let settings = makeSettings(.customCommand)
            let editor = try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.customCommandEditor)
                .find(CommandArgumentsEditor.self)
                .actualView()

            editor.text = "ollama\nrun\nqwen3:32b"

            XCTAssertEqual(settings.customCommandArguments, ["ollama", "run", "qwen3:32b"])
        }

        func testModelFieldWritesTheModel() throws {
            let settings = makeSettings(.customCommand)
            let field = try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.customCommandModelField)
                .find(ViewType.TextField.self)

            try field.setInput("qwen3:32b")

            XCTAssertEqual(settings.customCommandModel, "qwen3:32b")
        }

        func testCustomCommandShowsTheResponsibilityLineAndNoCodexNote() throws {
            let view = try OutputSettingsView(settings: makeSettings(.customCommand)).inspect()

            XCTAssertNoThrow(try view.find(text: "What the command does with the transcript is up to the command."))
            XCTAssertThrowsError(try view.find(viewWithAccessibilityIdentifier: A11yID.codexProviderNote))
        }

        func testCodexShowsItsNoteAndNoCommandControls() throws {
            let view = try OutputSettingsView(settings: makeSettings(.codexCLI)).inspect()

            XCTAssertNoThrow(try view.find(viewWithAccessibilityIdentifier: A11yID.codexProviderNote))
            XCTAssertThrowsError(try view.find(viewWithAccessibilityIdentifier: A11yID.customCommandEditor))
            XCTAssertThrowsError(try view.find(viewWithAccessibilityIdentifier: A11yID.customCommandModelField))
        }

        /// Typing into the hosted editor, which ViewInspector never builds:
        /// `--` and straight quotes reach the command as typed, where the
        /// system's smart substitutions would turn them into `—` and curly
        /// quotes.
        func testTypedDashesAndQuotesReachTheCommandUnchanged() throws {
            let settings = makeSettings(.customCommand)
            let hosting = NSHostingView(rootView: VStack { CustomCommandSettingsView(settings: settings) })
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            addTeardownBlock { @MainActor in window.orderOut(nil) }
            pump { !hosting.descendants(of: NSTextView.self).isEmpty }
            let editor = try XCTUnwrap(hosting.descendants(of: NSTextView.self).first, "the command editor must be on screen")

            window.makeFirstResponder(editor)
            editor.insertText("mlx_lm.generate\n--model\n{model}\n--system\n\"short\"", replacementRange: editor.selectedRange())
            // AppKit substitutes after the insertion, on a later turn of the run loop.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))

            XCTAssertEqual(settings.customCommandArguments, ["mlx_lm.generate", "--model", "{model}", "--system", "\"short\""])
        }
    }

#endif
