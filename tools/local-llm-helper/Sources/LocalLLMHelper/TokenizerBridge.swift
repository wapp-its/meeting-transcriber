import Foundation
import MLXLMCommon
import Tokenizers

/// Adapts swift-transformers' tokenizer to mlx-swift-lm's `Tokenizer`
/// protocol. mlx-swift-lm's own adapter lives in its MLXHuggingFace product,
/// which also brings a Hugging Face downloader; this helper only ever reads a
/// local folder and must not be able to reach the network.
struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    /// Loads the tokenizer from the folder's tokenizer.json,
    /// tokenizer_config.json, config.json and chat template. Never opens a
    /// weight file.
    static func load(from folder: URL) async throws -> Self {
        try await Self(upstream: AutoTokenizer.from(modelFolder: folder))
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? {
        upstream.bosToken
    }

    var eosToken: String? {
        upstream.eosToken
    }

    var unknownToken: String? {
        upstream.unknownToken
    }

    // The optional collections are the shape of mlx-swift-lm's protocol.
    // swiftlint:disable discouraged_optional_collection
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
    // swiftlint:enable discouraged_optional_collection
}

/// Hands mlx-swift-lm the tokenizer the helper already loaded for the prompt,
/// so loading the model does not read the tokenizer files a second time.
struct PreloadedTokenizerLoader: TokenizerLoader {
    let tokenizer: TokenizerBridge

    func load(from _: URL) -> any MLXLMCommon.Tokenizer {
        tokenizer
    }
}
