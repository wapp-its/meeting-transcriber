#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The placeholder rules of the command providers, without starting a
    /// process.
    final class CommandTemplateTests: XCTestCase {
        func testEffectiveArgumentsTrimEntriesAndDropEmptyOnes() {
            let stored = ["  ollama ", "", "run", " \t ", "\tqwen3:32b\n", ""]

            XCTAssertEqual(CommandTemplate.effectiveArguments(stored), ["ollama", "run", "qwen3:32b"])
        }

        func testUsesLooksAtTheArgumentsAfterTheProgramOnly() {
            XCTAssertFalse(CommandTemplate.uses(.model, in: ["{model}", "run"]))
            XCTAssertTrue(CommandTemplate.uses(.model, in: ["ollama", "run", "{model}"]))
            XCTAssertTrue(CommandTemplate.uses(.promptFile, in: ["tool", "--prompt-file={prompt_file}"]))
            XCTAssertFalse(CommandTemplate.uses(.outputFile, in: ["tool", "{prompt_file}"]))
        }

        func testSubstitute() {
            let values: [CommandTemplate.Placeholder: String] = [
                .model: "qwen3", .promptFile: "/run/prompt.txt", .transcriptFile: "/run/transcript.txt", .outputFile: "/run/protocol.md",
            ]
            let cases: [(name: String, arguments: [String], expected: [String])] = [
                ("program untouched", ["{model}", "{model}"], ["{model}", "qwen3"]),
                ("inside an argument", ["tool", "--prompt-file={prompt_file}"], ["tool", "--prompt-file=/run/prompt.txt"]),
                ("repeated", ["tool", "{model}-{model}", "{output_file}"], ["tool", "qwen3-qwen3", "/run/protocol.md"]),
                ("unknown name kept", ["tool", "{name}", "{model", "{}", "{{model}}"], ["tool", "{name}", "{model", "{}", "{qwen3}"]),
                ("transcript file", ["tool", "{transcript_file};touch x"], ["tool", "/run/transcript.txt;touch x"]),
                ("empty template", [], []),
            ]
            for (name, arguments, expected) in cases {
                XCTAssertEqual(CommandTemplate.substitute(arguments, values: values), expected, name)
            }
        }

        /// One left-to-right scan: a value that itself reads like a
        /// placeholder stays as it is.
        func testSubstitutedValueIsNeverExpandedAgain() {
            let values: [CommandTemplate.Placeholder: String] = [
                .model: "{prompt_file}", .promptFile: "/run/prompt.txt",
            ]

            XCTAssertEqual(
                CommandTemplate.substitute(["tool", "{model}", "{prompt_file}"], values: values),
                ["tool", "{prompt_file}", "/run/prompt.txt"],
            )
        }

        func testInputAndOutputModes() {
            let cases: [(arguments: [String], input: CommandTemplate.InputMode, output: CommandTemplate.OutputMode)] = [
                (["ollama", "run", "{model}"], .stdin, .stdout),
                (["tool", "--prompt-file={prompt_file}"], .files, .stdout),
                (["tool", "{transcript_file}", "{output_file}"], .files, .file),
                (["tool", "-o", "{output_file}"], .stdin, .file),
                (["{prompt_file}"], .stdin, .stdout),
            ]
            for (arguments, input, output) in cases {
                XCTAssertEqual(CommandTemplate.inputMode(of: arguments), input, "\(arguments)")
                XCTAssertEqual(CommandTemplate.outputMode(of: arguments), output, "\(arguments)")
            }
        }

        func testValidation() {
            let cases: [(arguments: [String], model: String, error: String?)] = [
                ([], "", "No custom command is set"),
                (["ollama", "run", "{model}"], " ", "The custom command uses {model}, but no model is set"),
                (["ollama", "run", "{model}"], "qwen3", nil),
                (["ollama", "run", "qwen3"], "", nil),
            ]
            for (arguments, model, expected) in cases {
                do {
                    try CommandTemplate.validate(arguments, model: model)
                    XCTAssertNil(expected, "\(arguments) passed validation")
                } catch {
                    guard case let .commandNotConfigured(message) = error else {
                        XCTFail("\(arguments): expected .commandNotConfigured, got \(error)")
                        continue
                    }
                    XCTAssertEqual(message, expected, "\(arguments)")
                    XCTAssertEqual(error.errorDescription, expected, "\(arguments)")
                }
            }
        }
    }
#endif
