import Foundation
import WhisperKit

/// The steps `WhisperKitEngine.loadModel()` takes to reach a usable pipe,
/// named so a test can observe which of them ran. Production resolves every step
/// against WhisperKit itself. Why the local step comes first is written down once,
/// on `WhisperKitLocalSnapshot`.
@MainActor
struct WhisperKitModelSource {
    /// The folder holding a complete local copy of the variant, or nil when it has
    /// to be fetched. Never touches the network.
    let locateLocal: (String) -> URL?
    /// WhisperKit's own downloader, which reaches the Hub before it inspects any
    /// local file.
    let download: (String, @escaping ProgressCallback) async throws -> URL
    /// Build the WhisperKit pipe from an on-disk model folder. It is also the
    /// completeness judge: `loadModels` checks its three CoreML bundles here, so a
    /// copy the locator waved through but CoreML cannot use still fails into the
    /// download.
    let makePipe: (String, URL) async throws -> WhisperKit
    /// Awaited before `locateLocal`, for one-time work on the model's files that
    /// must not run on the main actor: the Hub origin moves a copy earlier builds
    /// left in Documents (`WhisperKitModelMigration`). Nothing by default.
    var prepare: (String) async -> Void = { _ in }

    /// `prepare`, then `locateLocal`: the lookup waits for the one-time work, so it
    /// never sees a model folder halfway through being moved.
    func prepareAndLocate(_ variant: String) async -> URL? {
        await prepare(variant)
        return locateLocal(variant)
    }

    /// The folder as WhisperKit needs it. Named and separate because the conversion
    /// is load-bearing and wrong by default. `WhisperKitConfig` takes a `String` and
    /// WhisperKit turns it straight back into `URL(fileURLWithPath:)`, while
    /// `URL.path()` percent-encodes: an account name with a space or a non-ASCII
    /// character would make the model this locator just found look absent, and
    /// offline that ends in a failed download instead of a loaded model.
    nonisolated static func modelFolderArgument(_ folder: URL) -> String {
        folder.path(percentEncoded: false)
    }

    /// The configuration both origins build their pipe from. `downloadBase` is
    /// passed although the model folder is already resolved, because WhisperKit
    /// also takes the tokenizer cache from it (`tokenizerFolder ?? downloadBase`):
    /// left out, the tokenizer would be looked up, and fetched, in
    /// `Documents/huggingface` after all. `HubTokenScopedWhisperKit` reads the same
    /// `tokenizerFolder`, so its own fetch with the app's token lands there too. A
    /// parameter only so a test can check the wiring without creating the real
    /// folder.
    nonisolated static func pipeConfig(
        variant: String,
        folder: URL,
        downloadBase: URL = WhisperKitLocalSnapshot.downloadBase,
    ) -> WhisperKitConfig {
        WhisperKitConfig(
            model: variant,
            downloadBase: downloadBase,
            modelFolder: modelFolderArgument(folder),
        )
    }

    /// Whether `error` is the Hub refusing the request's credentials:
    /// `authorizationRequired(statusCode:)`, which WhisperKit throws for a 401 or
    /// 403 answer and, with nil, when it has no token where one is required.
    /// WhisperKit keeps its Hub error type internal, so it is matched by its fully
    /// qualified case name, whatever the status code, which
    /// `testRejectedTokenMatchesWhisperKitsOwnError` pins against the real type.
    nonisolated static func isRejectedToken(_ error: any Error) -> Bool {
        String(reflecting: error).hasPrefix("ArgmaxCore.Hub.HubClientError.authorizationRequired(")
    }

    /// Run one Hub-facing step with `token`, and name a refusal: a request Hugging
    /// Face refused is rethrown as the `WhisperKitLoadFailure` for whether a token was
    /// sent, any other error as it is. `step` receives the token, so the token sent
    /// and the token judged are one read.
    private static func classifyingHubFailure<T>(
        token: String,
        _ step: (_ token: String) async throws -> T,
    ) async throws -> T {
        do {
            return try await step(token)
        } catch {
            throw WhisperKitLoadFailure.classify(error, tokenSent: !token.isEmpty) ?? error
        }
    }

    /// Run a Hub download for `variant` and accept only a folder of exactly that
    /// name.
    ///
    /// `WhisperKit.download` matches the variant as the glob `*<variant>/*` and
    /// returns the folder that matched, so a variant typed as the tail of the real
    /// folder name downloads fine: `large-v3_8bit` fetches
    /// `flix-swissgerman-large-v3_8bit`. The engine would load it once and then
    /// never again offline, because the locator looks for a folder of the typed
    /// name, finds none, and every later load goes back to the Hub (issue #736 for
    /// one model). A neighbour that merely ends in the variant could be picked the
    /// same way. Refusing the mismatch here turns that into one error that names
    /// the exact folder. The files the refused download left in the cache sit under
    /// the real name, where the locator never serves them for the typed one.
    ///
    /// There is no retry without a token: the download is always handed the app's
    /// own token or `""`, never nil, so WhisperKit never sends a token it found in
    /// the environment (see `production(for:hubToken:)`), and a refusal of the app's
    /// token is reported as such (`WhisperKitLoadFailure`).
    static func downloadExactly(
        _ variant: String,
        _ attempt: () async throws -> URL,
    ) async throws -> URL {
        let folder = try await attempt()
        guard folder.lastPathComponent == variant else {
            throw WhisperKitModelError.variantNameMismatch(requested: variant, repositoryFolder: folder.lastPathComponent)
        }
        return folder
    }

    /// Resolve every step against WhisperKit itself, for the model's origin.
    ///
    /// `hubToken` is the Hugging Face token every Hub request carries, `""` for none,
    /// read as the download or the pipe construction starts. Never nil: WhisperKit
    /// sends the machine's own token (`HF_TOKEN` or `HUGGING_FACE_HUB_TOKEN`) when it
    /// is handed nil, and the Hub refuses a stale one with 401 even for a public
    /// model.
    static func production(
        for origin: WhisperKitModelOrigin,
        hubToken: @escaping @MainActor () -> String = { "" },
    ) -> Self {
        switch origin {
        case let .hub(repoID):
            hub(repoID: repoID, hubToken: hubToken)

        case let .localFolder(path, bookmark):
            localFolder(path: path, bookmark: bookmark, hubToken: hubToken)
        }
    }

    private static func hub(repoID: String, hubToken: @escaping @MainActor () -> String) -> Self {
        Self(
            locateLocal: { variant in
                WhisperKitLocalSnapshot.locate(variant: variant, in: WhisperKitLocalSnapshot.repoRoot(for: repoID))
            },
            download: { variant, progress in
                // `from:` passed explicitly although it matches the library default
                // for the stock models: the locator derives its root from the same
                // id, and a changed default would otherwise have the two point at
                // different repositories, which shows up as "the model is never found".
                try await classifyingHubFailure(token: hubToken()) { token in
                    try await downloadExactly(variant) {
                        try await WhisperKit.download(
                            variant: variant,
                            downloadBase: WhisperKitLocalSnapshot.downloadBase,
                            from: repoID,
                            token: token,
                            progressCallback: progress,
                        )
                    }
                }
            },
            makePipe: { variant, folder in
                // The tokenizer is fetched inside the init when none is cached.
                try await classifyingHubFailure(token: hubToken()) { token in
                    try await HubTokenScopedWhisperKit(
                        pipeConfig(variant: variant, folder: folder),
                        hubToken: token,
                        mayFetchTokenizer: true,
                    )
                }
            },
            prepare: { variant in
                await WhisperKitModelMigration.migrateIfNeeded(repoID: repoID, variant: variant)
            },
        )
    }

    /// A picked folder is loaded where it is. There is nothing to download it from,
    /// so the locator is the only way in, and the download step reports what the
    /// folder lacks instead: that is the error the engine logs when the load fails.
    ///
    /// The folder is checked for the tokenizer too, unlike a Hub variant, because its
    /// pipe never fetches one (`mayFetchTokenizer: false`): a picked folder is expected
    /// to load offline. No `tokenizerFolder` is passed, so the pipe uses
    /// `downloadBase` in its place (see `pipeConfig`) and searches, in order: the
    /// app's stock tokenizer cache `<downloadBase>/models/openai/whisper-<detected
    /// size>`, the top of `downloadBase` itself, the picked folder, and that folder's
    /// own `models/openai/whisper-<size>` (`WhisperTokenizerCache.searchPaths`). When
    /// none of them holds a tokenizer that loads, the load fails rather than going to
    /// the Hub. Sandbox access goes through `VocabularyFileAccess`, whose two helpers
    /// are not specific to vocabulary.
    private static func localFolder(path: String, bookmark: Data?, hubToken: @escaping @MainActor () -> String) -> Self {
        Self(
            locateLocal: { _ in
                guard let folder = VocabularyFileAccess.resolve(path: path, bookmark: bookmark) else { return nil }
                let problem = VocabularyFileAccess.withAccess(to: folder, WhisperKitLocalSnapshot.checkModelFolder)
                return problem == nil ? folder : nil
            },
            download: { _, _ in
                guard let folder = VocabularyFileAccess.resolve(path: path, bookmark: bookmark) else {
                    throw WhisperKitModelError.folderUnavailable
                }
                // A folder that checks out and still arrives here was refused by
                // WhisperKit itself, whose error the local branch has already logged.
                throw VocabularyFileAccess.withAccess(to: folder, WhisperKitLocalSnapshot.checkModelFolder)
                    ?? WhisperKitModelError.folderNotLoadable
            },
            makePipe: { variant, folder in
                // Held for the whole init: WhisperKit reads the CoreML bundles and
                // the tokenizer inside it. `folder` is the URL the locator resolved
                // from the bookmark, which is the one that carries the grant.
                let accessing = folder.startAccessingSecurityScopedResource()
                defer {
                    if accessing { folder.stopAccessingSecurityScopedResource() }
                }
                return try await classifyingHubFailure(token: hubToken()) { token in
                    try await HubTokenScopedWhisperKit(
                        pipeConfig(variant: variant, folder: folder),
                        hubToken: token,
                        mayFetchTokenizer: false,
                    )
                }
            },
        )
    }
}
