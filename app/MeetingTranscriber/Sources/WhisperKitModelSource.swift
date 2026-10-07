import Foundation
import WhisperKit

/// The three steps `WhisperKitEngine.loadModel()` takes to reach a usable pipe,
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

    /// The folder as WhisperKit needs it. Named and separate because the conversion
    /// is load-bearing and wrong by default. `WhisperKitConfig` takes a `String` and
    /// WhisperKit turns it straight back into `URL(fileURLWithPath:)`, while
    /// `URL.path()` percent-encodes: an account name with a space or a non-ASCII
    /// character would make the model this locator just found look absent, and
    /// offline that ends in a failed download instead of a loaded model.
    nonisolated static func modelFolderArgument(_ folder: URL) -> String {
        folder.path(percentEncoded: false)
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

    /// Resolve every step against WhisperKit itself, for the model's origin.
    ///
    /// `hubToken` is the Hugging Face token every Hub request carries, `""` for none,
    /// read as the download or the pipe construction starts. Never nil: WhisperKit
    /// sends the machine's own token (`HF_TOKEN`, `~/.cache/huggingface/token` and four
    /// more places) when it is handed nil, and the Hub refuses some stale ones, an old
    /// `hf` CLI OAuth token for one, with 401 even for a public model.
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
                    try await WhisperKit.download(
                        variant: variant,
                        from: repoID,
                        token: token,
                        progressCallback: progress,
                    )
                }
            },
            makePipe: { variant, folder in
                // The tokenizer is fetched inside the init when none is cached.
                try await classifyingHubFailure(token: hubToken()) { token in
                    try await HubTokenScopedWhisperKit(
                        WhisperKitConfig(model: variant, modelFolder: modelFolderArgument(folder)),
                        hubToken: token,
                        mayFetchTokenizer: true,
                    )
                }
            },
        )
    }

    /// A picked folder is loaded where it is. There is nothing to download it from,
    /// so the locator is the only way in, and the download step reports what the
    /// folder lacks instead: that is the error the engine logs when the load fails.
    ///
    /// The folder is checked for the tokenizer too, unlike a Hub variant, because its
    /// pipe never fetches one (`mayFetchTokenizer: false`): a picked folder is expected
    /// to load offline. Sandbox access goes through `VocabularyFileAccess`, whose two
    /// helpers are not specific to vocabulary.
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
                        WhisperKitConfig(model: variant, modelFolder: modelFolderArgument(folder)),
                        hubToken: token,
                        mayFetchTokenizer: false,
                    )
                }
            },
        )
    }
}
