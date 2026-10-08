#if !APPSTORE

    import Foundation

    /// The placeholder rules of a command-line protocol provider (the custom
    /// command, and the Codex CLI preset for its output file). A template is
    /// an argument vector whose first entry is the program; placeholders are
    /// replaced inside the arguments after it.
    enum CommandTemplate {
        enum Placeholder: String, CaseIterable {
            case model = "{model}"
            case promptFile = "{prompt_file}"
            case transcriptFile = "{transcript_file}"
            case outputFile = "{output_file}"
        }

        /// Where the program gets its input: the full prompt on stdin, or the
        /// files a placeholder names (then nothing is sent on stdin).
        enum InputMode: String {
            case stdin, files
        }

        /// Where the protocol comes from: the program's stdout, or the file
        /// `{output_file}` names (then stdout is ignored).
        enum OutputMode: String {
            case stdout, file
        }

        /// The stored entries as they run: each one trimmed of surrounding
        /// whitespace, empty ones dropped. The first is the program.
        static func effectiveArguments(_ stored: [String]) -> [String] {
            stored.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        /// Whether an argument after the program contains `placeholder`.
        static func uses(_ placeholder: Placeholder, in arguments: [String]) -> Bool {
            arguments.dropFirst().contains { $0.contains(placeholder.rawValue) }
        }

        static func inputMode(of arguments: [String]) -> InputMode {
            uses(.promptFile, in: arguments) || uses(.transcriptFile, in: arguments) ? .files : .stdin
        }

        static func outputMode(of arguments: [String]) -> OutputMode {
            uses(.outputFile, in: arguments) ? .file : .stdout
        }

        /// Throws when `arguments` (effective ones) cannot run: there is no
        /// program, or `{model}` is used while `model` is blank.
        static func validate(_ arguments: [String], model: String) throws(ProtocolError) {
            guard !arguments.isEmpty else { throw .commandNotConfigured("No custom command is set") }
            if uses(.model, in: arguments), model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw .commandNotConfigured("The custom command uses {model}, but no model is set")
            }
        }

        /// `arguments` with every placeholder after the program replaced by
        /// its value. Each argument is scanned once from left to right, so a
        /// substituted value is never scanned again; a `{name}` that is no
        /// placeholder, or has no value, stays as typed.
        static func substitute(_ arguments: [String], values: [Placeholder: String]) -> [String] {
            guard let program = arguments.first else { return [] }
            return [program] + arguments.dropFirst().map { substitute(in: $0, values: values) }
        }

        private static func substitute(in argument: String, values: [Placeholder: String]) -> String {
            var result = ""
            var rest = argument[...]
            while let open = rest.firstIndex(of: "{") {
                result += rest[..<open]
                rest = rest[open...]
                if let placeholder = Placeholder.allCases.first(where: { rest.hasPrefix($0.rawValue) }),
                   let value = values[placeholder] {
                    result += value
                    rest = rest.dropFirst(placeholder.rawValue.count)
                } else {
                    result += "{"
                    rest = rest.dropFirst()
                }
            }
            return result + rest
        }
    }

#endif
