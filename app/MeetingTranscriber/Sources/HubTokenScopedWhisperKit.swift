import Foundation
import os.log
import WhisperKit

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WhisperTokenizerCache")

/// A WhisperKit pipe whose tokenizer is fetched with the app's Hugging Face token, or
/// with none, and never with a token found elsewhere on the Mac.
///
/// It exists because WhisperKit 1.1.0 gives the tokenizer no way to receive a token.
/// `loadTokenizerIfNeeded` goes through `ModelUtilities.loadTokenizer`, which builds its
/// Hub client without one, and ArgmaxCore then looks one up on the machine (`HF_TOKEN`,
/// `~/.cache/huggingface/token` and four more places). `WhisperKitConfig(modelToken:)`
/// does not help: WhisperKit reads it only when no `modelFolder` is passed, and this
/// app always passes one. A stale token there, an old `hf` CLI OAuth token for one,
/// fails the tokenizer fetch with 401 even for a public model (`WhisperKitHubTokenLiveTests`
/// reproduces it), and a valid one would be sent where the user asked for none.
///
/// So the override makes sure WhisperKit's own fetch is never reached: before it hands
/// over to `super`, a tokenizer that loads sits in the folder WhisperKit will pick
/// (`WhisperTokenizerCache.ensureLoadable`). A mere existence check would not do,
/// because WhisperKit's local branch catches any load error, a malformed
/// `tokenizer.json` or a missing `tokenizer_config.json` alike, and falls back to its
/// own fetch.
///
/// The override runs inside `super.init`: WhisperKit's `init` calls `loadModels()` when
/// a model folder is set, and that calls `loadTokenizerIfNeeded()` last. That is why
/// both settings are stored before `super.init`.
///
/// **When to delete this type:** once a WhisperKit release lets the tokenizer load take
/// a token (`ModelUtilities.loadTokenizer` or `WhisperKitConfig`). Pass the token there
/// and build plain `WhisperKit` pipes again.
final class HubTokenScopedWhisperKit: WhisperKit {
    private let hubToken: String
    private let mayFetchTokenizer: Bool

    /// `hubToken` is sent with a tokenizer fetch, `""` for none. `mayFetchTokenizer` is
    /// false for a picked model folder, which must carry its own tokenizer.
    init(_ config: WhisperKitConfig, hubToken: String, mayFetchTokenizer: Bool) async throws {
        self.hubToken = hubToken
        self.mayFetchTokenizer = mayFetchTokenizer
        try await super.init(config)
    }

    override func loadTokenizerIfNeeded() async throws {
        // Without a tokenizer to find, `super` fetches nothing: it returns for a loaded
        // one and throws "tokenizer unavailable" for unknown dimensions.
        if tokenizer == nil, let logitsDim = textDecoder.logitsSize, let encoderDim = audioEncoder.embedSize {
            let cache = WhisperTokenizerCache(
                logitsDim: logitsDim,
                encoderDim: encoderDim,
                modelFolder: modelFolder,
                tokenizerFolder: tokenizerFolder,
            )
            try await cache.ensureLoadable(token: hubToken, mayFetch: mayFetchTokenizer)
        }
        try await super.loadTokenizerIfNeeded()
    }
}

/// Where WhisperKit looks for a model's tokenizer, and how to put a loadable one there
/// with the app's token. Each mirror of WhisperKit-internal knowledge is pinned against
/// the real internals by `WhisperTokenizerCacheTests`.
struct WhisperTokenizerCache {
    /// What `LanguageModelConfigurationFromHub` reads from a tokenizer folder.
    static let files = ["config.json", "tokenizer_config.json", "tokenizer.json"]

    /// The Hub repository holding the tokenizer, `openai/whisper-<size>`.
    let repository: String
    /// Where WhisperKit downloads a tokenizer to, nil for its default
    /// (`Documents/huggingface`). The pipe's tokenizer folder.
    let downloadBase: URL?
    /// The folders WhisperKit searches for `tokenizer.json`, in its order.
    let searchPaths: [URL]

    init(logitsDim: Int, encoderDim: Int, modelFolder: URL?, tokenizerFolder: URL?) {
        repository = Self.repository(logitsDim: logitsDim, encoderDim: encoderDim)
        downloadBase = tokenizerFolder
        searchPaths = Self.searchPaths(repository: repository, modelFolder: modelFolder, tokenizerFolder: tokenizerFolder)
    }

    /// The repository for a model with these dimensions. Mirrors
    /// `ModelUtilities.detectVariant` followed by `tokenizerNameForVariant`, both
    /// internal to WhisperKit, including their fallbacks for unknown sizes.
    static func repository(logitsDim: Int, encoderDim: Int) -> String {
        let size = switch logitsDim {
        case 51865:
            switch encoderDim {
            case 384: "tiny"
            case 512: "base"
            case 768: "small"
            case 1024: "medium"
            case 1280: "large-v2"
            default: "base"
            }

        case 51864:
            switch encoderDim {
            case 384: "tiny.en"
            case 512: "base.en"
            case 768: "small.en"
            case 1024: "medium.en"
            default: "base.en"
            }

        case 51866: "large-v3"

        default: "base"
        }
        return "openai/whisper-\(size)"
    }

    /// The folders WhisperKit searches for `tokenizer.json`, in its order: the
    /// download base's cache location, the tokenizer folder itself, the model folder,
    /// and the cache location under the model folder. It loads the first one holding
    /// the file. Paths only: the clients are built with an empty token, so not even
    /// the machine's token is looked up.
    static func searchPaths(repository: String, modelFolder: URL?, tokenizerFolder: URL?) -> [URL] {
        let repo = HubApiWrapper.Repo(id: repository)
        var paths = [HubApiWrapper(downloadBase: tokenizerFolder, hfToken: "").localRepoLocation(repo)]
        if let tokenizerFolder {
            paths.append(tokenizerFolder)
        }
        if let modelFolder {
            paths += [modelFolder, HubApiWrapper(downloadBase: modelFolder, hfToken: "").localRepoLocation(repo)]
        }
        return paths
    }

    /// Make sure the folder WhisperKit will load its tokenizer from loads, so WhisperKit
    /// never reaches its own fetch.
    ///
    /// The first search path holding `tokenizer.json` is tried as WhisperKit would load
    /// it. When none holds one, or that one does not load, the tokenizer is fetched
    /// with `token` into the first search path, where WhisperKit looks first, and tried
    /// again. Without `mayFetch` that is a `folderNotLoadable` failure instead. Any
    /// fetch or trial error after that fails the load.
    ///
    /// The fetch writes a fresh copy: whatever of the three files already sits in the
    /// first search path is removed first, with its download records, because the Hub
    /// client keeps a file whose record still names the current commit without reading
    /// it, and a fetch over a damaged copy would hand the same bytes back.
    func ensureLoadable(
        token: String,
        mayFetch: Bool,
        fetch: (_ repository: String, _ downloadBase: URL?, _ token: String) async throws -> Void =
            Self.fetch(repository:downloadBase:token:),
        trialLoad: (_ folder: URL, _ downloadBase: URL?, _ token: String) async throws -> Void =
            Self.trialLoad(_:downloadBase:token:),
    ) async throws {
        // The same existence test WhisperKit applies when it picks the folder.
        if let found = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path) }) {
            do {
                try await trialLoad(found, downloadBase, token)
                return
            } catch {
                // A fetch replaces the copy. Without one the error is replaced by
                // `folderNotLoadable` below, so this is the only place its reason is
                // recorded. Message private: it can carry the folder's path.
                if !mayFetch {
                    logger.warning(
                        "Tokenizer in the model folder did not load (\(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private))",
                    )
                }
            }
        }
        guard mayFetch else { throw WhisperKitModelError.folderNotLoadable }

        try Self.removeCachedTokenizer(in: searchPaths[0])
        try await fetch(repository, downloadBase, token)
        try await trialLoad(searchPaths[0], downloadBase, token)
    }

    /// Where the Hub client keeps a downloaded file's record (commit hash, etag,
    /// timestamp), relative to the repository folder: `HubApi.snapshot` in ArgmaxCore
    /// builds `<repository folder>/.cache/huggingface/download/<file>.metadata`.
    static let downloadRecordsFolder = ".cache/huggingface/download"

    /// Remove the tokenizer files in `folder`, and their download records, so the next
    /// fetch downloads them again instead of keeping a copy whose record still matches.
    /// Only the three files are touched; a missing one is not an error.
    static func removeCachedTokenizer(in folder: URL) throws {
        let records = folder.appendingPathComponent(downloadRecordsFolder)
        for name in files {
            let urls = [folder.appendingPathComponent(name), records.appendingPathComponent("\(name).metadata")]
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Fetch the tokenizer files with exactly `token` (`""` for none).
    static func fetch(repository: String, downloadBase: URL?, token: String) async throws {
        _ = try await HubApiWrapper(downloadBase: downloadBase, hfToken: token)
            .snapshot(from: HubApiWrapper.Repo(id: repository), matching: files)
    }

    /// Load the tokenizer in `folder` the way WhisperKit's local branch does, from the
    /// files alone. WhisperKit's wrapping of the result cannot fail, so this is all
    /// that can.
    static func trialLoad(_ folder: URL, downloadBase: URL?, token: String) async throws {
        _ = try await AutoTokenizerWrapper.from(
            modelFolder: folder,
            hubApi: HubApiWrapper(downloadBase: downloadBase, hfToken: token),
        )
    }
}
