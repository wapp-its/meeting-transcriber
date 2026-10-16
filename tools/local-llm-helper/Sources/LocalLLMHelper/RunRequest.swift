import Foundation

/// What the app sends for one protocol, as one JSON object on standard input,
/// which it then closes. Prompts travel only this way, never as command-line
/// text, where any process on the Mac could read them.
struct RunRequest: Decodable, Equatable, Sendable {
    /// Absolute path of the model folder.
    let modelFolder: String
    let systemPrompt: String
    let userPrompt: String
    /// The most tokens prompt plus output may take; also the KV cache size.
    let contextLimit: Int
    /// The most tokens the model may write.
    let outputLimit: Int
    /// Absolute path of the file the protocol is written to, inside the app's
    /// private run directory. The helper creates it owner-only.
    let outputPath: String

    enum Parsed: Equatable {
        case request(RunRequest)
        /// Standard input ended without a byte: the parent went away before
        /// writing a request.
        case empty
        /// Not a JSON object with every field above.
        case malformed
        /// Well-formed, but a limit is not positive or a path is not absolute.
        case invalid
    }

    static func parse(_ data: Data) -> Parsed {
        if data.isEmpty { return .empty }
        guard let request = try? JSONDecoder().decode(Self.self, from: data) else { return .malformed }
        let valid = request.contextLimit > 0 && request.outputLimit > 0
            && request.modelFolder.hasPrefix("/") && request.outputPath.hasPrefix("/")
        return valid ? .request(request) : .invalid
    }
}
