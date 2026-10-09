import Foundation
@testable import MeetingTranscriber
import XCTest

/// Records each fetch and answers it; with `holds` set, a fetch waits until the
/// test releases it, so a test can change settings while a check is in flight.
@MainActor
final class RemoteVocabularyFetcherFake: RemoteVocabularyFetching {
    struct Request: Equatable {
        let url: URL
        let token: String?
        let validators: RemoteVocabularyValidators?
    }

    private(set) var requests: [Request] = []
    var answer: RemoteVocabularyFetchResult = .failed(.offline)
    var holds = false
    private var held: [CheckedContinuation<RemoteVocabularyFetchResult, Never>] = []

    var heldCount: Int {
        held.count
    }

    func fetch(url: URL, token: String?, validators: RemoteVocabularyValidators?) async -> RemoteVocabularyFetchResult {
        requests.append(Request(url: url, token: token, validators: validators))
        guard holds else { return answer }
        return await withCheckedContinuation { held.append($0) }
    }

    /// Answers the oldest held fetch.
    func release(_ result: RemoteVocabularyFetchResult) {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(returning: result)
    }

    func releaseAll() {
        while !held.isEmpty {
            release(.failed(.cancelled))
        }
    }
}

/// `RemoteVocabularyController` over a fake fetcher, its own cache directory,
/// its own defaults suite and its own Keychain account, with a clock the test
/// moves. Debounce and interval are short; nothing waits for real seconds.
@MainActor
final class RemoteVocabularyControllerTests: XCTestCase {
    private final class TestClock {
        var date = Date(timeIntervalSince1970: 1_791_288_120)
    }

    private static let address = "https://lists.example.org/team/vocabulary.txt"
    private static let otherAddress = "https://lists.example.org/other/vocabulary.txt"
    // swiftlint:disable:next force_unwrapping
    private static let url = URL(string: address)!
    // swiftlint:disable:next force_unwrapping
    private static let v1 = RemoteVocabularyValidators(etag: "\"v1\"", lastModified: "Tue, 06 Oct 2026 12:02:00 GMT")!
    private static let terms = Data("Northstar\nAster\n".utf8)

    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tokenAccount: String!
    private var cacheDirectory: URL!
    private var settings: AppSettings!
    private var fetcher: RemoteVocabularyFetcherFake!
    private var clock: TestClock!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "RemoteVocabularyControllerTests-\(getpid())-\(UUID().uuidString)"
        tokenAccount = "RemoteVocabularyControllerTests-token-\(getpid())-\(UUID().uuidString)"
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteVocabularyControllerTests-\(UUID().uuidString)", isDirectory: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = makeSettings()
        settings.vocabularySource = .url
        settings.remoteVocabularyURL = Self.address
        fetcher = RemoteVocabularyFetcherFake()
        clock = TestClock()
    }

    override func tearDown() async throws {
        fetcher.releaseAll()
        fetcher = nil
        settings = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheDirectory.path)
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        KeychainHelper.delete(key: tokenAccount)
        tokenAccount = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        clock = nil
        try await super.tearDown()
    }

    // MARK: - When it checks

    func testNoCheckWhileTheSourceIsLocalFileOrTheAddressIsInvalid() async throws {
        settings.vocabularySource = .file
        let controller = makeController(interval: .milliseconds(10))

        controller.start()
        controller.refreshNow()

        XCTAssertEqual(controller.status, .inactive)

        settings.vocabularySource = .url
        settings.remoteVocabularyURL = "http://lists.example.org/team/vocabulary.txt"
        await waitFor(controller.status == .addressProblem(.notHTTPS), timeout: .seconds(2))
        controller.refreshNow()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(controller.status, .addressProblem(.notHTTPS))
        XCTAssertEqual(fetcher.requests, [])
        XCTAssertFalse(controller.isChecking)
    }

    func testStartChecksOnceAndStoresAValidDownload() async throws {
        fetcher.answer = .modified(body: Self.terms, validators: Self.v1)
        let controller = makeController()

        controller.start()

        XCTAssertTrue(controller.isChecking)
        XCTAssertEqual(controller.status, .checking)
        await waitForChecks(controller, count: 1)
        XCTAssertEqual(fetcher.requests, [.init(url: Self.url, token: nil, validators: nil)])
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: settings.effectiveVocabularyPath)), Self.terms,
            "The file the engines read holds the download",
        )
        XCTAssertEqual(controller.status, .current(termCount: 2, updatedAt: clock.date, checkedAt: clock.date))
        XCTAssertFalse(controller.isChecking)

        controller.start()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fetcher.requests.count, 1, "A second start() does nothing")
    }

    func testChecksRepeatEveryInterval() async {
        let controller = makeController(interval: .milliseconds(30))

        controller.start()

        await waitFor(fetcher.requests.count >= 3, timeout: .seconds(2))
        XCTAssertGreaterThanOrEqual(fetcher.requests.count, 3)
    }

    // MARK: - Conditional requests

    func testTheNextCheckSendsTheValidatorsAndA304OnlyRecordsTheCheckTime() async {
        let controller = await startedWithCopy()
        let storedAt = clock.date
        let revision = WhisperVocabularyPrompt.fileRevision(at: textFile.path)
        clock.date += 600
        fetcher.answer = .notModified

        controller.refreshNow()
        await waitForChecks(controller, count: 2)

        XCTAssertEqual(fetcher.requests.last?.validators, Self.v1)
        XCTAssertEqual(WhisperVocabularyPrompt.fileRevision(at: textFile.path), revision, "A 304 leaves the text file untouched")
        XCTAssertEqual(controller.status, .current(termCount: 2, updatedAt: storedAt, checkedAt: clock.date))
        let copy = settings.remoteVocabularyCache.load(for: Self.address)
        XCTAssertEqual(copy?.checkedAt, clock.date)
        XCTAssertEqual(copy?.updatedAt, storedAt)
        XCTAssertEqual(copy?.validators, Self.v1)
    }

    func testAnIdenticalBodyIsNotRewrittenAndAChangedOneReplacesTheCopy() async throws {
        let controller = await startedWithCopy()
        let storedAt = clock.date
        let revision = WhisperVocabularyPrompt.fileRevision(at: textFile.path)
        let v2 = RemoteVocabularyValidators(etag: "\"v2\"", lastModified: nil)
        clock.date += 600
        fetcher.answer = .modified(body: Self.terms, validators: v2)

        controller.refreshNow()
        await waitForChecks(controller, count: 2)

        XCTAssertEqual(WhisperVocabularyPrompt.fileRevision(at: textFile.path), revision, "An identical body is not rewritten")
        XCTAssertEqual(controller.status, .current(termCount: 2, updatedAt: storedAt, checkedAt: clock.date))
        let copy = settings.remoteVocabularyCache.load(for: Self.address)
        XCTAssertEqual(copy?.validators, v2)
        XCTAssertEqual(copy?.updatedAt, storedAt)

        clock.date += 600
        fetcher.answer = .modified(body: Data("Northstar\nAster\nVega\n".utf8), validators: nil)
        controller.refreshNow()
        await waitForChecks(controller, count: 3)

        XCTAssertNotEqual(WhisperVocabularyPrompt.fileRevision(at: textFile.path), revision)
        XCTAssertEqual(try Data(contentsOf: textFile), Data("Northstar\nAster\nVega\n".utf8))
        XCTAssertEqual(controller.status, .current(termCount: 3, updatedAt: clock.date, checkedAt: clock.date))
    }

    // MARK: - Failures

    func testAFailedCheckKeepsTheCopyAndNamesTheCopyTheEnginesRead() async throws {
        let cases: [(name: String, answer: RemoteVocabularyFetchResult, failure: RemoteVocabularyFailure, lockCache: Bool)] = [
            ("invalid body", .modified(body: Data(" \n".utf8), validators: nil), .invalidContent(.empty), false),
            ("offline", .failed(.offline), .offline, false),
            ("401", .failed(.httpStatus(401)), .httpStatus(401), false),
            ("timeout", .failed(.timedOut), .timedOut, false),
            ("save failure", .modified(body: Data("Vega\n".utf8), validators: nil), .couldNotSave, true),
        ]
        let controller = await startedWithCopy()
        let lastGood = RemoteVocabularyCopyInfo(termCount: 2, updatedAt: clock.date)

        for (name, answer, failure, lockCache) in cases {
            clock.date += 60
            fetcher.answer = answer
            if lockCache {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cacheDirectory.path)
            }
            let checks = fetcher.requests.count + 1

            controller.refreshNow()
            await waitForChecks(controller, count: checks)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheDirectory.path)

            XCTAssertEqual(controller.status, .failed(failure, lastGood: lastGood), name)
            XCTAssertFalse(controller.isChecking, name)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: settings.effectiveVocabularyPath)), Self.terms, name)
        }
    }

    func testAFailedCheckWithoutACopyReportsNoVocabularyInUse() async {
        let controller = makeController()

        controller.start()
        await waitForChecks(controller, count: 1)

        XCTAssertEqual(controller.status, .failed(.offline, lastGood: nil))
        XCTAssertEqual(controller.status.message { _ in "" }, "No connection to the server · no vocabulary in use")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.effectiveVocabularyPath))
    }

    // MARK: - Generations

    func testAnAddressChangeDeletesTheOldCopyAndDropsTheCheckInFlight() async throws {
        let controller = await startedWithCopy(debounce: .seconds(1))
        let oldFile = textFile
        fetcher.holds = true
        controller.refreshNow()
        await waitFor(fetcher.heldCount == 1, timeout: .seconds(2))

        settings.remoteVocabularyURL = Self.otherAddress
        await waitFor(controller.status == .notDownloaded, timeout: .seconds(2))

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "The old address's copy is deleted")
        XCTAssertFalse(controller.isChecking)

        // The old address's server answers only now; that answer must not land.
        fetcher.release(.modified(body: Data("Stale\n".utf8), validators: Self.v1))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(controller.status, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path), [])

        await waitFor(fetcher.heldCount == 1, timeout: .seconds(3))
        XCTAssertEqual(fetcher.requests.last?.url.absoluteString, Self.otherAddress)
        XCTAssertNil(fetcher.requests.last?.validators)
        fetcher.release(.modified(body: Self.terms, validators: nil))
        await waitFor(!controller.isChecking, timeout: .seconds(2))

        XCTAssertEqual(controller.status, .current(termCount: 2, updatedAt: clock.date, checkedAt: clock.date))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: settings.effectiveVocabularyPath)), Self.terms)
    }

    func testATokenChangeTriggersOneDebouncedCheckWithTheNewToken() async throws {
        let controller = await startedWithCopy(debounce: .milliseconds(500))
        fetcher.answer = .notModified

        settings.remoteVocabularyToken = "glpat-first"
        try await Task.sleep(for: .milliseconds(20))
        settings.remoteVocabularyToken = "  glpat-second\n"
        await waitForChecks(controller, count: 2)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fetcher.requests.map(\.token), [nil, "glpat-second"], "One check, after the last change, with the trimmed token")
    }

    func testANewControllerOnTheSameCacheStartsFromTheStoredCopy() async {
        _ = await startedWithCopy()
        let lastGood = RemoteVocabularyCopyInfo(termCount: 2, updatedAt: clock.date)
        clock.date += 3600
        fetcher.answer = .failed(.offline)
        let restarted = makeController()

        restarted.start()
        await waitForChecks(restarted, count: 2)

        XCTAssertEqual(fetcher.requests.last?.validators, Self.v1)
        XCTAssertEqual(restarted.status, .failed(.offline, lastGood: lastGood))
    }

    // MARK: - App wiring and log

    /// `AppState` is built by many unit tests. Its controller must not touch the
    /// cache until the scene starts it: an armed controller would delete the
    /// copy below, which belongs to an address other than the configured one.
    func testAppStateExposesTheControllerAndItsInitTouchesNoCache() async throws {
        let otherCopy = RemoteVocabularyMetadata(
            url: Self.otherAddress, etag: nil, lastModified: nil, updatedAt: clock.date, checkedAt: clock.date,
        )
        try settings.remoteVocabularyCache.store(Self.terms, metadata: otherCopy)
        let before = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).sorted()
        let logDir = try makeTempDirectory(prefix: "RemoteVocabularyControllerTests-AppState")
        let appSettings = makeSettings(defaultOutputDir: logDir.appendingPathComponent("output", isDirectory: true))

        let state = AppState(
            settings: appSettings, notifier: SilentNotifier(), pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: logDir),
        )
        appSettings.remoteVocabularyURL = "https://lists.example.org/third/vocabulary.txt"
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).sorted(), before)
        XCTAssertEqual(state.remoteVocabulary.status, .inactive)
        XCTAssertFalse(state.remoteVocabulary.isChecking)
    }

    func testTheLogLineCarriesOnlyTheOutcomeAndTheHTTPStatus() {
        let date = clock.date
        let cases: [(RemoteVocabularyController.CheckOutcome, RemoteVocabularyFetchResult, String)] = [
            (.updated(termCount: 2, at: date), .modified(body: Self.terms, validators: Self.v1), "updated, HTTP 200"),
            (.unchanged(termCount: 2, updatedAt: date, checkedAt: date), .notModified, "unchanged, HTTP 304"),
            (
                .failed(.httpStatus(401)), .failed(.httpStatus(401)),
                "failed (Access denied (HTTP 401) – check the access token), HTTP 401",
            ),
            (.failed(.offline), .failed(.offline), "failed (No connection to the server), HTTP none"),
            (
                .failed(.invalidContent(.empty)), .modified(body: Data(" \n".utf8), validators: nil),
                "failed (Vocabulary file contains no terms), HTTP 200",
            ),
        ]

        for (outcome, result, expected) in cases {
            XCTAssertEqual(RemoteVocabularyController.logDescription(of: outcome, result: result), expected)
        }
    }

    // MARK: - Helpers

    private var textFile: URL {
        RemoteVocabularyCache.textFile(
            in: cacheDirectory, bundleID: settings.remoteVocabularyCache.bundleID, address: Self.address,
        )
    }

    private func makeSettings(defaultOutputDir: URL = AppPaths.downloadsProtocolsDir) -> AppSettings {
        AppSettings(
            defaults: defaults,
            remoteVocabularyTokenAccount: tokenAccount,
            defaultOutputDir: defaultOutputDir,
            remoteVocabularyCacheDirectory: cacheDirectory,
        )
    }

    private func makeController(
        debounce: Duration = .milliseconds(20), interval: Duration = .seconds(3600),
    ) -> RemoteVocabularyController {
        let clock = clock
        return RemoteVocabularyController(settings: settings, fetcher: fetcher, debounce: debounce, interval: interval) {
            clock?.date ?? Date()
        }
    }

    /// A started controller whose first check stored `terms` with `v1` at
    /// `clock.date`.
    private func startedWithCopy(debounce: Duration = .milliseconds(20)) async -> RemoteVocabularyController {
        fetcher.answer = .modified(body: Self.terms, validators: Self.v1)
        let controller = makeController(debounce: debounce)
        controller.start()
        await waitForChecks(controller, count: 1)
        XCTAssertEqual(controller.status, .current(termCount: 2, updatedAt: clock.date, checkedAt: clock.date))
        return controller
    }

    private func waitForChecks(_ controller: RemoteVocabularyController, count: Int) async {
        await waitFor(fetcher.requests.count >= count && !controller.isChecking, timeout: .seconds(2))
    }
}
