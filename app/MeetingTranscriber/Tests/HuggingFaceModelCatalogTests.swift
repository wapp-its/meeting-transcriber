import Foundation
@testable import MeetingTranscriber
import os
import XCTest

/// Pins the Hugging Face catalog client against recorded API answers through
/// `MockURLProtocol`, so no test here reaches the network.
///
/// `Fixtures/HuggingFace/` holds three answers recorded anonymously with curl on
/// 2026-10-14 (the "swiss" search and the `spert` and `gcoli` listings) and one
/// derived by hand: `repo-gated-derived.json` is the recorded `spert` listing with
/// `"gated": "manual"` in place of `false`, because no gated WhisperKit repository
/// small enough to record was at hand. Other shapes are inline JSON below.
final class HuggingFaceModelCatalogTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    private static let spertID = "spert/flix-swissgerman-whisperkit"
    private static let gcoliID = "gcoli/whisper-large-v3-swiss-german-coreml"

    /// One file of a repository listing; `size` nil leaves the key out.
    private struct File {
        let path: String
        let size: Int?
    }

    /// The requests the mock answered, in order. Locked because the protocol runs
    /// on URLSession's own queue.
    private let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        MockURLProtocol.rawResponseHandler = nil
        MockURLProtocol.hangHandler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Typed as the protocol, so the tests call the client the way the browser does.
    private func makeCatalog() -> any HuggingFaceModelCataloging {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return HuggingFaceModelCatalog(session: URLSession(configuration: configuration))
    }

    private func respond(body: Data, status: Int = 200) {
        let requests = requests
        MockURLProtocol.handler = { request in
            requests.withLock { $0.append(request) }
            // swiftlint:disable:next force_unwrapping
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
    }

    private func respond(fixture name: String) throws {
        try respond(body: Data(contentsOf: fixtureURL("HuggingFace/\(name)")))
    }

    private func onlyRequest() throws -> URLRequest {
        let sent = requests.withLock { $0 }
        XCTAssertEqual(sent.count, 1)
        return try XCTUnwrap(sent.first)
    }

    private func thrownError(_ call: () async throws -> Void) async -> (any Error)? {
        do {
            try await call()
            return nil
        } catch {
            return error
        }
    }

    /// Every file `WhisperKitLocalSnapshot` requires of a variant, inside `folder`.
    private static func requiredFiles(in folder: String, size: Int) -> [File] {
        WhisperKitLocalSnapshot.requiredBundles.flatMap { bundle in
            WhisperKitLocalSnapshot.requiredFiles.map { File(path: "\(folder)/\(bundle).mlmodelc/\($0)", size: size) }
        }
    }

    private static func listing(files: [File] = [], card: [String: Any] = [:], tags: [String] = []) throws -> Data {
        let siblings: [[String: Any]] = files.map { file in
            var sibling: [String: Any] = ["rfilename": file.path]
            sibling["size"] = file.size
            return sibling
        }
        var object: [String: Any] = ["id": "owner/repo", "siblings": siblings, "tags": tags, "gated": false]
        if !card.isEmpty {
            object["cardData"] = card
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Requests

    func testSearchAsksForWhisperKitModelsMostDownloadedFirst() async throws {
        try respond(fixture: "search-swiss.json")
        _ = try await makeCatalog().searchWhisperKitModels(matching: "swiss", token: nil)

        let request = try onlyRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://huggingface.co/api/models?search=swiss&filter=whisperkit&sort=downloads&direction=-1&limit=20",
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 20)
    }

    func testSearchSendsTheQueryAsTyped() async throws {
        respond(body: Data("[]".utf8))
        _ = try await makeCatalog().searchWhisperKitModels(matching: "c++ a&b=c", token: nil)

        let url = try XCTUnwrap(onlyRequest().url)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        // A bare "+" would reach the Hub as a space.
        XCTAssertTrue(query.hasPrefix("search=c%2B%2B%20a%26b%3Dc&filter=whisperkit"), query)
    }

    func testListingAsksForTheRepositoryWithItsFileSizes() async throws {
        try respond(fixture: "repo-spert-flix-swissgerman-whisperkit.json")
        _ = try await makeCatalog().repository(Self.spertID, token: nil)

        let request = try onlyRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/api/models/spert/flix-swissgerman-whisperkit?blobs=true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 20)
    }

    func testBearerHeaderOnlyForANonEmptyTrimmedToken() async throws {
        let cases: [(token: String?, header: String?)] = [
            (nil, nil),
            ("", nil),
            ("  ", nil),
            ("abc", "Bearer abc"),
            (" abc\n", "Bearer abc"),
        ]
        let catalog = makeCatalog()
        for testCase in cases {
            respond(body: Data("[]".utf8))
            _ = try await catalog.searchWhisperKitModels(matching: "swiss", token: testCase.token)
            respond(body: Data(#"{"siblings":[]}"#.utf8))
            _ = try await catalog.repository(Self.spertID, token: testCase.token)
        }

        let headers = requests.withLock { $0 }.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(headers, cases.flatMap { [$0.header, $0.header] })
    }

    func testAnInvalidRepositoryIDSendsNoRequest() async {
        respond(body: Data(#"{"siblings":[]}"#.utf8))
        let catalog = makeCatalog()
        for repoID in ["", "spert", "spert/flix/extra", "../etc", "spert/flix swiss", "spert/..", "spert/fl*x"] {
            let error = await thrownError { _ = try await catalog.repository(repoID, token: "abc") }
            XCTAssertEqual(error as? HuggingFaceCatalogError, .invalidRepository, repoID)
        }
        XCTAssertTrue(requests.withLock { $0 }.isEmpty)
    }

    // MARK: - Search results

    func testSearchReturnsTheRecordedSwissHitsInAPIOrder() async throws {
        try respond(fixture: "search-swiss.json")
        let results = try await makeCatalog().searchWhisperKitModels(matching: "swiss", token: nil)

        XCTAssertEqual(results, [
            HuggingFaceModelSummary(id: Self.spertID, downloads: 95),
            HuggingFaceModelSummary(id: Self.gcoliID, downloads: 21),
        ])
    }

    func testSearchDropsIDsThatAreNotRepositories() async throws {
        let body = #"[{"id":"owner/first","downloads":7},{"id":"no-owner"},{"id":"a/b/c"},{"id":"owner/bad name"},{"id":"owner/second"}]"#
        respond(body: Data(body.utf8))
        let results = try await makeCatalog().searchWhisperKitModels(matching: "any", token: nil)

        XCTAssertEqual(results, [
            HuggingFaceModelSummary(id: "owner/first", downloads: 7),
            HuggingFaceModelSummary(id: "owner/second", downloads: nil),
        ])
    }

    // MARK: - Repository listings

    func testSpertListsItsOneVariantWithItsSizeUnderApache() async throws {
        try respond(fixture: "repo-spert-flix-swissgerman-whisperkit.json")
        let listing = try await makeCatalog().repository(Self.spertID, token: nil)

        XCTAssertEqual(listing.id, Self.spertID)
        XCTAssertEqual(listing.variants, [HuggingFaceModelVariant(name: "flix-swissgerman-large-v3_8bit", sizeBytes: 1_627_283_096)])
        XCTAssertEqual(listing.variants.map(\.id), ["flix-swissgerman-large-v3_8bit"])
        let license = try XCTUnwrap(listing.license)
        XCTAssertEqual(license.label, "Apache 2.0")
        XCTAssertFalse(license.isNonCommercial)
        XCTAssertFalse(listing.isGated)
        XCTAssertEqual(listing.modelCardURL.absoluteString, "https://huggingface.co/spert/flix-swissgerman-whisperkit")
    }

    func testGcoliHasNoLoadableVariantAndANonCommercialLicense() async throws {
        try respond(fixture: "repo-gcoli-whisper-large-v3-swiss-german-coreml.json")
        let listing = try await makeCatalog().repository(Self.gcoliID, token: nil)

        // Its bundles sit at the repository's top level, not in a variant folder.
        XCTAssertTrue(listing.variants.isEmpty, "\(listing.variants)")
        let license = try XCTUnwrap(listing.license)
        XCTAssertEqual(license.identifier, "swissdial-cc-by-nc-4.0-no-reidentification")
        XCTAssertTrue(license.isNonCommercial)
        XCTAssertEqual(license.displayText, "swissdial-cc-by-nc-4.0-no-reidentification — non-commercial")
    }

    /// Reads the hand-derived `repo-gated-derived.json` (see the class comment).
    func testAGatedRepositoryIsMarkedGated() async throws {
        try respond(fixture: "repo-gated-derived.json")
        let listing = try await makeCatalog().repository(Self.spertID, token: nil)

        XCTAssertTrue(listing.isGated)
        XCTAssertEqual(listing.variants.map(\.name), ["flix-swissgerman-large-v3_8bit"])
    }

    func testAVariantIsAValidFolderHoldingEveryRequiredFile() async throws {
        let complete = Self.requiredFiles(in: "large_8bit", size: 100)
        var unsized = complete
        unsized[0] = File(path: complete[0].path, size: nil)
        let cases: [(name: String, files: [File], expected: [HuggingFaceModelVariant])] = [
            (
                "every file under the folder counts towards its size",
                complete + [File(path: "large_8bit/config.json", size: 5), File(path: "README.md", size: 9)],
                [HuggingFaceModelVariant(name: "large_8bit", sizeBytes: 905)],
            ),
            ("one required file missing", Array(complete.dropLast()), []),
            ("folder name the settings would refuse", Self.requiredFiles(in: "large 8bit", size: 100), []),
            ("a file without a size", unsized, [HuggingFaceModelVariant(name: "large_8bit", sizeBytes: nil)]),
            (
                "variants sorted by name",
                Self.requiredFiles(in: "small", size: 1) + Self.requiredFiles(in: "base", size: 2),
                [HuggingFaceModelVariant(name: "base", sizeBytes: 18), HuggingFaceModelVariant(name: "small", sizeBytes: 9)],
            ),
        ]
        let catalog = makeCatalog()
        for testCase in cases {
            try respond(body: Self.listing(files: testCase.files))
            let listing = try await catalog.repository("owner/repo", token: nil)
            XCTAssertEqual(listing.variants, testCase.expected, testCase.name)
        }
    }

    func testLicenseComesFromTheCardThenItsNameThenATag() async throws {
        let cases: [(name: String, card: [String: Any], tags: [String], expected: String?)] = [
            ("a list of licenses: the first counts", ["license": ["mit", "apache-2.0"]], [], "mit"),
            ("other: its name", ["license": "other", "license_name": "my-license"], ["license:other"], "my-license"),
            ("other without a name", ["license": "other"], [], "other"),
            ("the card wins over a tag", ["license": "mit"], ["license:apache-2.0"], "mit"),
            ("only a tag", [:], ["whisperkit", "license:cc-by-4.0"], "cc-by-4.0"),
            ("none stated", [:], ["whisperkit"], nil),
        ]
        let catalog = makeCatalog()
        for testCase in cases {
            try respond(body: Self.listing(card: testCase.card, tags: testCase.tags))
            let listing = try await catalog.repository("owner/repo", token: nil)
            XCTAssertEqual(listing.license?.identifier, testCase.expected, testCase.name)
        }
    }

    // MARK: - Failures

    func testHTTPFailuresMapToTheirCause() async {
        let cases: [(status: Int, expected: HuggingFaceCatalogError)] = [
            (401, .refused),
            (403, .refused),
            (404, .notFound),
            (429, .rateLimited),
            (500, .unexpectedStatus(500)),
        ]
        let catalog = makeCatalog()
        for testCase in cases {
            respond(body: Data("{}".utf8), status: testCase.status)
            let searchError = await thrownError { _ = try await catalog.searchWhisperKitModels(matching: "swiss", token: nil) }
            XCTAssertEqual(searchError as? HuggingFaceCatalogError, testCase.expected, "search \(testCase.status)")
            let listingError = await thrownError { _ = try await catalog.repository(Self.spertID, token: nil) }
            XCTAssertEqual(listingError as? HuggingFaceCatalogError, testCase.expected, "listing \(testCase.status)")
        }
    }

    func testATransportFailureReadsAsUnreachable() async {
        let catalog = makeCatalog()
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost] {
            MockURLProtocol.errorHandler = { _ in URLError(code) }
            let error = await thrownError { _ = try await catalog.searchWhisperKitModels(matching: "swiss", token: nil) }
            XCTAssertEqual(error as? HuggingFaceCatalogError, .unreachable, "\(code)")
        }
    }

    func testCancellingTheCallIsRethrownAsCancellation() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        MockURLProtocol.hangHandler = { request in
            started.withLock { $0 = true }
            // swiftlint:disable:next force_unwrapping
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let catalog = makeCatalog()
        let call = Task { try await catalog.repository(Self.spertID, token: nil) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !started.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        call.cancel()

        let result = await call.result
        guard case let .failure(error) = result else {
            XCTFail("expected a failure, got \(result)")
            return
        }
        XCTAssertTrue(error is CancellationError, "\(error)")
    }

    func testAnUnreadableBodyIsMalformed() async {
        respond(body: Data("<html>not json</html>".utf8))
        let catalog = makeCatalog()
        let searchError = await thrownError { _ = try await catalog.searchWhisperKitModels(matching: "swiss", token: nil) }
        XCTAssertEqual(searchError as? HuggingFaceCatalogError, .malformedResponse)
        let listingError = await thrownError { _ = try await catalog.repository(Self.spertID, token: nil) }
        XCTAssertEqual(listingError as? HuggingFaceCatalogError, .malformedResponse)
    }

    func testEveryFailureHasItsOneLineMessage() {
        let cases: [(error: HuggingFaceCatalogError, message: String)] = [
            (.unreachable, "Cannot reach Hugging Face. Models already on this Mac keep working."),
            (
                .refused,
                "Hugging Face refused the request: the repository is private or does not exist, or the token in Settings was not accepted.",
            ),
            (.notFound, "Hugging Face has no such repository."),
            (.rateLimited, "Hugging Face is limiting requests. Try again in a minute."),
            (.unexpectedStatus(502), "Hugging Face answered with HTTP 502."),
            (.malformedResponse, "Hugging Face sent a response this app cannot read."),
            (.invalidRepository, "Not a valid Hugging Face repository name."),
        ]
        for testCase in cases {
            XCTAssertEqual(testCase.error.message, testCase.message)
        }
    }
}
