import Foundation

/// A model folder built in a temporary directory: real config, tokenizer and
/// chat template files, and two weight shards that are only placeholders.
/// Enough for everything that loads no weights (`check`, the prompt, the
/// context refusal); an attempt to load the model fails, as the config lacks
/// the architecture's fields. Built per test and then broken on purpose, so
/// no fake model files are committed.
///
/// The tokenizer has no merges: every character of printable ASCII and the
/// newline is its own token, which makes a prompt's token count predictable.
/// The template renders like Qwen3's and ends with an empty thinking block
/// only when `enable_thinking` is passed as false.
struct ModelFolderFixture {
    static let shards = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
    static let shardBytes = Data("placeholder, not a weight file".utf8)
    static let template = """
    {% for message in messages %}<|im_start|>{{ message.role }}
    {{ message.content }}<|im_end|>
    {% endfor %}{% if add_generation_prompt %}<|im_start|>assistant
    {% if enable_thinking is defined and enable_thinking is false %}<think>

    </think>

    {% endif %}{% endif %}
    """

    let url: URL

    init(name: String = "Fixture-4bit") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-llm-helper-tests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try writeJSON("config.json", ["model_type": "qwen3", "quantization": ["group_size": 64, "bits": 4]])
        try writeJSON("tokenizer_config.json", ["tokenizer_class": "Qwen2Tokenizer", "eos_token": "<|im_end|>"])
        try writeJSON("tokenizer.json", Self.tokenizer())
        try write("chat_template.jinja", Self.template)
        try writeJSON("model.safetensors.index.json", [
            "metadata": [:] as [String: Any],
            "weight_map": ["a.weight": Self.shards[0], "b.weight": Self.shards[1]],
        ])
        for shard in Self.shards {
            try Self.shardBytes.write(to: url.appendingPathComponent(shard))
        }
    }

    func remove(_ name: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(name))
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }

    func writeJSON(_ name: String, _ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url.appendingPathComponent(name))
    }

    func setPermissions(_ name: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.appendingPathComponent(name).path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func tokenizer() -> [String: Any] {
        let special = ["<|im_start|>", "<|im_end|>"]
        let characters = ["\n"] + (32 ... 126).compactMap { UnicodeScalar($0).map { String(Character($0)) } }
        var vocab: [String: Int] = [:]
        for (id, token) in (special + characters).enumerated() {
            vocab[token] = id
        }
        return [
            "version": "1.0",
            "added_tokens": special.enumerated().map { id, content in
                ["id": id, "content": content, "special": true, "single_word": false, "lstrip": false, "rstrip": false, "normalized": false]
            },
            "model": ["type": "BPE", "vocab": vocab, "merges": [] as [String]],
        ]
    }
}
