import Darwin
import Foundation
import MLXLLM
import MLXLMCommon

/// What `check` prints, as one JSON line on stdout. `run` uses the same check
/// before it touches the prompt.
struct ModelFolderReport: Encodable, Equatable {
    struct Quantization: Encodable, Equatable {
        let bits: Int
        let groupSize: Int
    }

    struct Problem: Encodable, Equatable {
        enum Kind: String, Encodable {
            /// Absent, or not a regular file.
            case missing
            /// Present, but this user may not read it.
            case unreadable
            /// Present, but it does not parse or lacks what it must declare.
            case invalid
            /// config.json names a model type the pinned mlx-swift-lm cannot run.
            case unsupported
        }

        /// A name inside the model folder, or "." for the folder itself.
        let file: String
        let problem: Kind
    }

    var usable: Bool {
        problems.isEmpty
    }

    /// The folder's own name, which for a Hugging Face download is the model's.
    let name: String
    /// config.json's `model_type`, when it could be read.
    let modelType: String?
    /// nil for a model whose weights are not quantised.
    let quantization: Quantization?
    /// Bytes of the weight files on disk: what loading the model maps into memory.
    let sizeBytes: Int64?
    let problems: [Problem]

    private enum CodingKeys: String, CodingKey {
        case usable, name, modelType, quantization, sizeBytes, problems
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usable, forKey: .usable)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(modelType, forKey: .modelType)
        try container.encodeIfPresent(quantization, forKey: .quantization)
        try container.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try container.encode(problems, forKey: .problems)
    }

    func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return #"{"usable":false}"# }
        return String(bytes: data, encoding: .utf8) ?? #"{"usable":false}"#
    }
}

/// Validates a model folder without loading weights: the weight files are
/// checked with stat(2) and access(2) only, never opened. Every problem found
/// is reported, not only the first.
enum ModelFolderCheck {
    typealias Problem = ModelFolderReport.Problem

    static let configFile = "config.json"
    static let tokenizerFile = "tokenizer.json"
    static let tokenizerConfigFile = "tokenizer_config.json"
    static let templateFiles = ["chat_template.jinja", "chat_template.json"]
    static let weightIndexFile = "model.safetensors.index.json"
    static let singleWeightFile = "model.safetensors"

    /// The report, and the loaded tokenizer when the folder is usable.
    static func inspect(_ folder: URL) async -> (ModelFolderReport, TokenizerBridge?) {
        let name = folder.lastPathComponent
        guard isDirectory(folder.path) else {
            return (ModelFolderReport(
                name: name,
                modelType: nil,
                quantization: nil,
                sizeBytes: nil,
                problems: [Problem(file: ".", problem: .missing)],
            ), nil)
        }
        var problems: [Problem] = []

        let config = readConfig(folder, problems: &problems)
        if let modelType = config?.modelType {
            let supported = await LLMTypeRegistry.shared.contains(modelType)
            if !supported { problems.append(Problem(file: configFile, problem: .unsupported)) }
        }
        // swift-transformers reads config.json too when it is there, so a
        // broken one would fail the tokenizer load and be blamed on it.
        let configParses = config != nil || !fileExists(folder, configFile)
        let tokenizerFilesPresent = checkTokenizerFiles(folder, problems: &problems) && configParses
        let template = templateSource(folder, problems: &problems)
        let weightBytes = weightFileBytes(folder, problems: &problems)

        var tokenizer: TokenizerBridge?
        if tokenizerFilesPresent {
            tokenizer = try? await TokenizerBridge.load(from: folder)
            if tokenizer == nil {
                problems.append(Problem(file: tokenizerFile, problem: .invalid))
            }
        }
        if let tokenizer, let template, (try? Prompt.render(tokenizer: tokenizer, system: "s", user: "u")) == nil {
            problems.append(Problem(file: template, problem: .invalid))
        }

        let quantization = config?.perLayerQuantization?.quantization.map { ModelFolderReport.Quantization(bits: $0.bits, groupSize: $0.groupSize) }
        let report = ModelFolderReport(
            name: name, modelType: config?.modelType, quantization: quantization,
            sizeBytes: weightBytes, problems: problems,
        )
        return (report, report.usable ? tokenizer : nil)
    }

    // MARK: - Steps

    /// config.json, decoded the way mlx-swift-lm decodes it when loading.
    private static func readConfig(_ folder: URL, problems: inout [Problem]) -> BaseConfiguration? {
        guard let data = readFile(folder, configFile, problems: &problems) else { return nil }
        guard let config = try? JSONDecoder.json5().decode(BaseConfiguration.self, from: data) else {
            problems.append(Problem(file: configFile, problem: .invalid))
            return nil
        }
        return config
    }

    /// tokenizer.json must exist and be readable; tokenizer_config.json is
    /// optional to swift-transformers but must parse when present. Whether
    /// tokenizer.json parses is answered by loading the tokenizer, which is the
    /// one parse that matters. Returns whether that load is worth attempting.
    private static func checkTokenizerFiles(_ folder: URL, problems: inout [Problem]) -> Bool {
        let before = problems.count
        _ = regularFile(folder, tokenizerFile, problems: &problems)
        if fileExists(folder, tokenizerConfigFile),
           let data = readFile(folder, tokenizerConfigFile, problems: &problems),
           !isJSONObject(data) {
            problems.append(Problem(file: tokenizerConfigFile, problem: .invalid))
        }
        return problems.count == before
    }

    /// Where the chat template comes from, in swift-transformers' order:
    /// chat_template.jinja, chat_template.json, then tokenizer_config.json.
    private static func templateSource(_ folder: URL, problems: inout [Problem]) -> String? {
        for file in templateFiles where fileExists(folder, file) {
            return readFile(folder, file, problems: &problems) == nil ? nil : file
        }
        if fileExists(folder, tokenizerConfigFile),
           let data = try? Data(contentsOf: folder.appendingPathComponent(tokenizerConfigFile)),
           let template = jsonObject(data)["chat_template"], template is String || template is [Any] {
            return tokenizerConfigFile
        }
        problems.append(Problem(file: templateFiles[0], problem: .missing))
        return nil
    }

    /// The total size of the weight files: the shards the index names, or every
    /// `*.safetensors` file when there is no index. nil when any is missing.
    private static func weightFileBytes(_ folder: URL, problems: inout [Problem]) -> Int64? {
        let names: [String]
        if fileExists(folder, weightIndexFile) {
            guard let data = readFile(folder, weightIndexFile, problems: &problems) else { return nil }
            guard let map = jsonObject(data)["weight_map"] as? [String: String], !map.isEmpty else {
                problems.append(Problem(file: weightIndexFile, problem: .invalid))
                return nil
            }
            names = Set(map.values).sorted()
        } else {
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            names = listed.filter { $0.hasSuffix(".safetensors") }.sorted()
            if names.isEmpty {
                problems.append(Problem(file: singleWeightFile, problem: .missing))
                return nil
            }
        }
        let sizes = names.compactMap { regularFile(folder, $0, problems: &problems) }
        return sizes.count == names.count ? sizes.reduce(0, +) : nil
    }

    // MARK: - File primitives

    /// The file's size when it is a readable regular file (symlinks followed,
    /// as in a Hugging Face cache snapshot); otherwise records why not. Uses
    /// stat(2) and access(2) only: the file is never opened.
    private static func regularFile(_ folder: URL, _ name: String, problems: inout [Problem]) -> Int64? {
        let path = folder.appendingPathComponent(name).path
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            problems.append(Problem(file: name, problem: .missing))
            return nil
        }
        guard access(path, R_OK) == 0 else {
            problems.append(Problem(file: name, problem: .unreadable))
            return nil
        }
        return Int64(info.st_size)
    }

    private static func readFile(_ folder: URL, _ name: String, problems: inout [Problem]) -> Data? {
        guard regularFile(folder, name, problems: &problems) != nil else { return nil }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else {
            problems.append(Problem(file: name, problem: .unreadable))
            return nil
        }
        return data
    }

    private static func fileExists(_ folder: URL, _ name: String) -> Bool {
        var info = stat()
        return stat(folder.appendingPathComponent(name).path, &info) == 0
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// The top-level JSON object, empty when the data is not one.
    private static func jsonObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
}
