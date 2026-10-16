import MLXLMCommon

enum Prompt {
    /// Passed to every chat template render. A template that knows the switch
    /// (Qwen3 and later) then ends the prompt with an empty thinking block, so
    /// the model writes the protocol directly. Explicit `false`, because those
    /// templates think when the value is undefined.
    static let templateContext: [String: any Sendable] = ["enable_thinking": false]

    /// The token ids of `[system, user]` rendered through the model's own chat
    /// template, ending with the assistant's turn.
    static func render(tokenizer: any MLXLMCommon.Tokenizer, system: String, user: String) throws -> [Int] {
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        return try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: templateContext)
    }

    /// Whether the whole output limit still fits beside the prompt. The KV
    /// cache is bounded to the context limit, and a cache that fills up drops
    /// the oldest tokens instead of failing, which would silently cut the start
    /// of the transcript; so a prompt that does not leave room for the full
    /// output is refused instead.
    static func fits(promptTokens: Int, outputLimit: Int, contextLimit: Int) -> Bool {
        promptTokens + outputLimit <= contextLimit
    }
}
