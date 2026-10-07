@testable import MeetingTranscriber
@testable import WhisperKit
import XCTest

/// The tokenizer pre-check in `HubTokenScopedWhisperKit` mirrors three pieces of
/// WhisperKit-internal knowledge and decides when a Hub request may run. Nothing here
/// touches the network: the fetch and, except where named, the trial load are closures
/// that record what they were asked to do.
final class WhisperTokenizerCacheTests: XCTestCase {
    private struct TrialFailed: Error, Equatable {
        let folder: URL
    }

    private struct FetchFailed: Error {}

    /// One shape of evidence for every `ensureLoadable` test.
    private final class Recorder: @unchecked Sendable {
        struct Fetch: Equatable {
            let repository: String
            let downloadBase: URL?
            let token: String
        }

        var fetches: [Fetch] = []
        var trials: [URL] = []
    }

    /// The layout every `ensureLoadable` test runs against: a model folder and a
    /// tokenizer download base, both in a fresh temp directory, so nothing reaches the
    /// real `Documents/huggingface`.
    private struct Layout {
        let modelFolder: URL
        let tokenizerFolder: URL
        let cache: WhisperTokenizerCache

        var paths: [URL] {
            cache.searchPaths
        }
    }

    /// `openai/whisper-tiny`, the repository for a multilingual 384-wide encoder.
    private let repository = "openai/whisper-tiny"

    private func makeLayout() throws -> Layout {
        let root = try makeTempDirectory(prefix: "wk-tokenizer")
        let modelFolder = root.appendingPathComponent("model", isDirectory: true)
        let tokenizerFolder = root.appendingPathComponent("tokenizers", isDirectory: true)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tokenizerFolder, withIntermediateDirectories: true)
        let cache = WhisperTokenizerCache(
            logitsDim: 51865,
            encoderDim: 384,
            modelFolder: modelFolder,
            tokenizerFolder: tokenizerFolder,
        )
        return Layout(modelFolder: modelFolder, tokenizerFolder: tokenizerFolder, cache: cache)
    }

    private func write(_ contents: String, named name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
    }

    /// Run `ensureLoadable` on `layout` with recording closures. `trial` decides, per
    /// call, whether the folder loads.
    private func ensure(
        _ layout: Layout,
        recorder: Recorder,
        token: String = "",
        mayFetch: Bool = true,
        fetchError: (any Error)? = nil,
        trial: @escaping (URL, Int) throws -> Void = { _, _ in },
    ) async throws {
        try await layout.cache.ensureLoadable(
            token: token,
            mayFetch: mayFetch,
            fetch: { repository, downloadBase, token in
                recorder.fetches.append(.init(repository: repository, downloadBase: downloadBase, token: token))
                if let fetchError { throw fetchError }
            },
            trialLoad: { folder, _, _ in
                recorder.trials.append(folder)
                try trial(folder, recorder.trials.count)
            },
        )
    }

    // MARK: - Mirrors of WhisperKit internals

    /// `WhisperKit.loadTokenizerIfNeeded` picks the tokenizer repository through two
    /// internal functions. A drift here would fetch one repository while WhisperKit
    /// looks for another, and WhisperKit would then fetch its own with the machine's
    /// token.
    func testRepositoryMatchesWhisperKitOverTheWholeGrid() {
        for logitsDim in [51864, 51865, 51866, 50000] {
            for encoderDim in [384, 512, 768, 1024, 1280, 999] {
                let expected = ModelUtilities.tokenizerNameForVariant(
                    ModelUtilities.detectVariant(logitsDim: logitsDim, encoderDim: encoderDim),
                )
                XCTAssertEqual(
                    WhisperTokenizerCache.repository(logitsDim: logitsDim, encoderDim: encoderDim),
                    expected,
                    "logitsDim \(logitsDim), encoderDim \(encoderDim)",
                )
            }
        }
    }

    /// The order `loadTokenizerIfNeeded` and `ModelUtilities.loadTokenizer` search in:
    /// the first folder holding `tokenizer.json` is the one WhisperKit loads.
    func testSearchPathsFollowWhisperKitsOrder() throws {
        let layout = try makeLayout()
        let hubPath = "models/\(repository)"
        let model = layout.modelFolder.path
        let tokenizers = layout.tokenizerFolder.path

        // Compared as paths: the library builds its URLs with `appending(component:)`,
        // whose spelling of the same location differs from `appendingPathComponent`.
        XCTAssertEqual(layout.paths.map(\.path), [
            "\(tokenizers)/\(hubPath)",
            tokenizers,
            model,
            "\(model)/\(hubPath)",
        ])
        let withoutTokenizerFolder = WhisperTokenizerCache.searchPaths(
            repository: repository,
            modelFolder: layout.modelFolder,
            tokenizerFolder: nil,
        )
        XCTAssertEqual(
            withoutTokenizerFolder.dropFirst().map(\.path),
            [model, "\(model)/\(hubPath)"],
            "Without a tokenizer folder, only the download base's location precedes the model folder",
        )
    }

    // MARK: - ensureLoadable

    /// Nothing local: one fetch with the app's token, the empty one included, then a
    /// trial of the folder WhisperKit searches first, which is where the fetch writes.
    func testNothingLocalFetchesOnceWithTheGivenToken() async throws {
        for token in ["", "hf_appToken"] {
            let layout = try makeLayout()
            let recorder = Recorder()

            try await ensure(layout, recorder: recorder, token: token)

            XCTAssertEqual(
                recorder.fetches,
                [.init(repository: repository, downloadBase: layout.tokenizerFolder, token: token)],
                "token \(token.debugDescription)",
            )
            XCTAssertEqual(recorder.trials, [layout.paths[0]], "token \(token.debugDescription)")
        }
    }

    func testALoadableCopyInAnySearchPathIsNotFetched() async throws {
        for index in 0 ..< 4 {
            let layout = try makeLayout()
            try write("{}", named: "tokenizer.json", in: layout.paths[index])
            let recorder = Recorder()

            try await ensure(layout, recorder: recorder)

            XCTAssertEqual(recorder.fetches, [], "search path \(index)")
            XCTAssertEqual(recorder.trials, [layout.paths[index]], "search path \(index)")
        }
    }

    /// A copy that does not load is exactly what makes WhisperKit fall back to its own
    /// fetch with the machine's token, so it is replaced first.
    func testABrokenCopyIsFetchedIntoTheFirstSearchPathAndTriedAgain() async throws {
        let layout = try makeLayout()
        try write("{}", named: "tokenizer.json", in: layout.modelFolder)
        let recorder = Recorder()

        try await ensure(layout, recorder: recorder, token: "hf_appToken") { folder, call in
            if call == 1 { throw TrialFailed(folder: folder) }
        }

        XCTAssertEqual(recorder.fetches, [.init(repository: repository, downloadBase: layout.tokenizerFolder, token: "hf_appToken")])
        XCTAssertEqual(recorder.trials, [layout.modelFolder, layout.paths[0]])
    }

    /// A broken copy in the first search path, the download cache itself, with the
    /// download records the Hub client wrote for it. The client keeps a file whose record
    /// still names the current commit without reading it, so a fetch over it would hand
    /// the same broken bytes back; the files and their records have to be gone before
    /// the fetch runs, or the load fails until the user deletes the cache by hand.
    func testABrokenCopyInTheFirstSearchPathIsRemovedWithItsRecordsBeforeTheFetch() async throws {
        let layout = try makeLayout()
        let cacheFolder = layout.paths[0]
        let recordsFolder = cacheFolder.appendingPathComponent(".cache/huggingface/download")
        var cached: [URL] = []
        for name in WhisperTokenizerCache.files {
            try write("not json", named: name, in: cacheFolder)
            // The record the client writes: commit hash, etag, timestamp, one per line.
            try write("0123456789abcdef0123456789abcdef01234567\n\"etag\"\n1.0\n", named: "\(name).metadata", in: recordsFolder)
            cached += [cacheFolder.appendingPathComponent(name), recordsFolder.appendingPathComponent("\(name).metadata")]
        }
        let recorder = Recorder()
        final class Seen: @unchecked Sendable {
            var atFetch: [String] = []
        }
        let seen = Seen()

        try await layout.cache.ensureLoadable(
            token: "",
            mayFetch: true,
            fetch: { repository, downloadBase, token in
                recorder.fetches.append(.init(repository: repository, downloadBase: downloadBase, token: token))
                seen.atFetch = cached.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
            },
            trialLoad: { folder, _, _ in
                recorder.trials.append(folder)
                if recorder.trials.count == 1 { throw TrialFailed(folder: folder) }
            },
        )

        XCTAssertEqual(recorder.trials, [cacheFolder, cacheFolder])
        XCTAssertEqual(recorder.fetches.count, 1)
        XCTAssertEqual(seen.atFetch, [], "The fetch must find the broken copy and its download records gone")
    }

    func testAFetchedCopyThatStillDoesNotLoadFailsTheLoad() async throws {
        let layout = try makeLayout()
        let recorder = Recorder()

        do {
            try await ensure(layout, recorder: recorder) { folder, _ in throw TrialFailed(folder: folder) }
            XCTFail("A tokenizer that does not load must fail the load, never reach WhisperKit's own fetch")
        } catch {
            XCTAssertEqual(error as? TrialFailed, TrialFailed(folder: layout.paths[0]))
        }
        XCTAssertEqual(recorder.fetches.count, 1)
    }

    func testAFailedFetchFailsTheLoad() async throws {
        let layout = try makeLayout()
        let recorder = Recorder()

        do {
            try await ensure(layout, recorder: recorder, fetchError: FetchFailed())
            XCTFail("A failed fetch must fail the load")
        } catch {
            XCTAssertTrue(error is FetchFailed, "got \(error)")
        }
        XCTAssertEqual(recorder.trials, [], "Nothing to try after a failed fetch")
    }

    /// A picked folder is never downloaded, so a missing or broken tokenizer fails the
    /// load instead of being fetched.
    func testAPickedFolderWithoutALoadableTokenizerFailsWithoutAFetch() async throws {
        for brokenCopy in [false, true] {
            let layout = try makeLayout()
            if brokenCopy {
                try write("{}", named: "tokenizer.json", in: layout.modelFolder)
            }
            let recorder = Recorder()

            do {
                try await ensure(layout, recorder: recorder, mayFetch: false) { folder, _ in
                    throw TrialFailed(folder: folder)
                }
                XCTFail("brokenCopy \(brokenCopy): the load must fail")
            } catch {
                XCTAssertEqual(error as? WhisperKitModelError, .folderNotLoadable, "brokenCopy \(brokenCopy)")
            }
            XCTAssertEqual(recorder.fetches, [], "brokenCopy \(brokenCopy): a picked folder must never be fetched")
        }
    }

    // MARK: - The real trial load

    /// Two copies the real trial rejects: one whose `tokenizer.json` does not parse,
    /// and a cache missing `tokenizer_config.json`. A plain existence check would wave
    /// both through, and WhisperKit would then fetch with the machine's token.
    private let unloadableCopies: [(name: String, files: [String: String])] = [
        ("malformed tokenizer.json", ["tokenizer.json": "not json", "tokenizer_config.json": "{}"]),
        ("no tokenizer_config.json", ["tokenizer.json": "{}"]),
    ]

    private func ensureWithTheRealTrial(_ layout: Layout, mayFetch: Bool, recorder: Recorder) async throws {
        try await layout.cache.ensureLoadable(
            token: "",
            mayFetch: mayFetch,
            fetch: { repository, downloadBase, token in
                recorder.fetches.append(.init(repository: repository, downloadBase: downloadBase, token: token))
            },
            trialLoad: { folder, downloadBase, token in
                recorder.trials.append(folder)
                try await WhisperTokenizerCache.trialLoad(folder, downloadBase: downloadBase, token: token)
            },
        )
    }

    func testAnUnloadableCopyOnDiskIsFetchedForAHubModel() async throws {
        for copy in unloadableCopies {
            let layout = try makeLayout()
            for (name, contents) in copy.files {
                try write(contents, named: name, in: layout.modelFolder)
            }
            let recorder = Recorder()

            // The recording fetch writes nothing, so the re-trial fails too: what
            // matters here is that the real trial sent the load to the fetch.
            try? await ensureWithTheRealTrial(layout, mayFetch: true, recorder: recorder)

            XCTAssertEqual(
                recorder.fetches,
                [.init(repository: repository, downloadBase: layout.tokenizerFolder, token: "")],
                copy.name,
            )
            XCTAssertEqual(recorder.trials, [layout.modelFolder, layout.paths[0]], copy.name)
        }
    }

    func testAnUnloadableCopyInAPickedFolderFailsAsNotLoadable() async throws {
        for copy in unloadableCopies {
            let layout = try makeLayout()
            for (name, contents) in copy.files {
                try write(contents, named: name, in: layout.modelFolder)
            }
            let recorder = Recorder()

            do {
                try await ensureWithTheRealTrial(layout, mayFetch: false, recorder: recorder)
                XCTFail("\(copy.name): the load must fail")
            } catch {
                XCTAssertEqual(error as? WhisperKitModelError, .folderNotLoadable, copy.name)
            }
            XCTAssertEqual(recorder.fetches, [], copy.name)
        }
    }
}
