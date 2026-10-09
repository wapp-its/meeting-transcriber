import Foundation
@testable import MeetingTranscriber
import XCTest

/// Every fetch goes through a real `URLSession` built from the production
/// configuration, with `RemoteVocabularyURLProtocolStub` in front of the network.
final class RemoteVocabularyFetcherTests: XCTestCase {
    private typealias Stub = RemoteVocabularyURLProtocolStub

    private static let address = URL(string: "https://lists.example.org/team/vocabulary.txt")!
    private static let plainText = ["Content-Type": "text/plain; charset=utf-8"]
    // swiftlint:disable:next force_unwrapping
    private static let validators = RemoteVocabularyValidators(etag: "\"v1\"", lastModified: "Tue, 06 Oct 2026 12:02:00 GMT")!

    override func setUp() {
        super.setUp()
        Stub.reset()
    }

    override func tearDown() {
        Stub.reset()
        super.tearDown()
    }

    func testProductionConfigurationBypassesTheURLCache() {
        let configuration = RemoteVocabularyFetcher.makeConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
    }

    func testConditionalHeadersAreSentOnlyWithValidators() async {
        Stub.answer { _ in
            .response(
                status: 200,
                headers: Self.plainText.merging(["ETag": "\"v2\"", "Last-Modified": "Wed, 07 Oct 2026 08:00:00 GMT"]) { $1 },
                body: Data("Northstar\n".utf8),
            )
        }
        let fetcher = makeFetcher()

        let first = await fetcher.fetch(url: Self.address, token: nil, validators: nil)
        _ = await fetcher.fetch(url: Self.address, token: nil, validators: Self.validators)

        XCTAssertEqual(
            first,
            .modified(
                body: Data("Northstar\n".utf8),
                validators: RemoteVocabularyValidators(etag: "\"v2\"", lastModified: "Wed, 07 Oct 2026 08:00:00 GMT"),
            ),
        )
        let requests = Stub.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "If-Modified-Since"))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Modified-Since"), "Tue, 06 Oct 2026 12:02:00 GMT")
    }

    func testNotModifiedSurfacesWhenValidatorsWereSent() async {
        Stub.answer { _ in .response(status: 304, headers: [:], body: Data()) }

        let result = await makeFetcher().fetch(url: Self.address, token: nil, validators: Self.validators)

        XCTAssertEqual(result, .notModified)
    }

    func testNotModifiedWithoutValidatorsIsAFailure() async {
        Stub.answer { _ in .response(status: 304, headers: [:], body: Data()) }

        let result = await makeFetcher().fetch(url: Self.address, token: nil, validators: nil)

        XCTAssertEqual(result, .failed(.unexpectedNotModified))
    }

    func testTokenIsSentTrimmedAsBearerOnlyWhenNonEmpty() async {
        Stub.answer { _ in .response(status: 200, headers: Self.plainText, body: Data("Northstar\n".utf8)) }
        let fetcher = makeFetcher()

        for token in [" glpat-secret \n", nil, "", "  \n"] {
            _ = await fetcher.fetch(url: Self.address, token: token, validators: nil)
        }

        let requests = Stub.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer glpat-secret", nil, nil, nil])
        XCTAssertEqual(requests.compactMap { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") }, [])
    }

    func testWebPageIsRejectedAsNotATextFile() async {
        Stub.answer { _ in
            .response(status: 200, headers: ["Content-Type": "Text/HTML; charset=utf-8"], body: Data("<html>Sign in</html>".utf8))
        }

        let result = await makeFetcher().fetch(url: Self.address, token: nil, validators: nil)

        XCTAssertEqual(result, .failed(.notTextFile))
    }

    /// The first chunk is already over the limit and the response never ends:
    /// only a reader that stops at limit + 1 byte returns before the deadline.
    func testBodyOverTheLimitIsAbandonedOnceItPassesTheLimit() async {
        let oversized = Data(repeating: UInt8(ascii: "a"), count: WhisperVocabularyPrompt.maximumFileBytes + 1)
        Stub.answer { _ in .stall(status: 200, headers: Self.plainText, firstChunk: oversized) }

        let result = await makeFetcher(totalDeadline: .seconds(20)).fetch(url: Self.address, token: nil, validators: nil)

        XCTAssertEqual(result, .failed(.tooLarge))
    }

    /// URLSession holds a response back until it has some bytes, so the stalled
    /// response carries 1 KB: far below the limit, so only the declared length
    /// can end the fetch before the deadline.
    func testDeclaredLengthOverTheLimitIsRejectedBeforeTheBody() async {
        let headers = Self.plainText.merging(["Content-Length": "\(WhisperVocabularyPrompt.maximumFileBytes + 1)"]) { $1 }
        let firstChunk = Data(repeating: UInt8(ascii: "a"), count: 1024)
        Stub.answer { _ in .stall(status: 200, headers: headers, firstChunk: firstChunk) }

        let result = await makeFetcher(totalDeadline: .seconds(20)).fetch(url: Self.address, token: nil, validators: nil)

        XCTAssertEqual(result, .failed(.tooLarge))
    }

    func testHTTPErrorStatusesMapToTheirCode() async {
        for status in [401, 404, 500] {
            Stub.answer { _ in .response(status: status, headers: Self.plainText, body: Data("error".utf8)) }

            let result = await makeFetcher().fetch(url: Self.address, token: "secret", validators: nil)

            XCTAssertEqual(result, .failed(.httpStatus(status)), "HTTP \(status)")
        }
    }

    func testTransportErrorsMapToOffline() async {
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .timedOut] {
            Stub.answer { _ in .transportError(code) }

            let result = await makeFetcher().fetch(url: Self.address, token: nil, validators: nil)

            XCTAssertEqual(result, .failed(.offline), "\(code)")
        }
    }

    func testResponseThatNeverFinishesTimesOutAtTheTotalDeadline() async {
        Stub.answer { _ in .stall(status: 200, headers: Self.plainText, firstChunk: Data("Northstar\n".utf8)) }
        let started = ContinuousClock.now

        let result = await makeFetcher(totalDeadline: .milliseconds(300)).fetch(url: Self.address, token: nil, validators: nil)

        XCTAssertEqual(result, .failed(.timedOut))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testRedirectPolicy() throws {
        let origin = try XCTUnwrap(URL(string: "https://Lists.Example.org/vocabulary.txt"))
        let cases: [(target: String, token: Bool, refusal: RemoteVocabularyFailure?)] = [
            ("https://lists.example.org/moved.txt", true, nil),
            ("https://cdn.example.net/vocabulary.txt", true, .redirectToOtherServer),
            ("https://cdn.example.net/vocabulary.txt", false, nil),
            ("http://lists.example.org/vocabulary.txt", false, .insecureRedirect),
            ("http://lists.example.org/vocabulary.txt", true, .insecureRedirect),
        ]

        for (target, token, refusal) in cases {
            let targetURL = try XCTUnwrap(URL(string: target))
            XCTAssertEqual(
                RemoteVocabularyFetcher.redirectRefusal(from: origin, to: targetURL, tokenPresent: token),
                refusal,
                "\(target) token=\(token)",
            )
        }
    }

    func testSameHostRedirectIsFollowedWithTheToken() async throws {
        let moved = try XCTUnwrap(URL(string: "https://lists.example.org/team/moved.txt"))
        Stub.answer { request in
            request.url == moved
                ? .response(status: 200, headers: Self.plainText, body: Data("Aster\n".utf8))
                : .redirect(status: 302, location: moved)
        }

        let result = await makeFetcher().fetch(url: Self.address, token: "secret", validators: nil)

        XCTAssertEqual(result, .modified(body: Data("Aster\n".utf8), validators: nil))
        XCTAssertEqual(Stub.requests.map(\.url), [Self.address, moved])
    }

    func testCrossHostRedirectWithATokenIsRefused() async throws {
        let elsewhere = try XCTUnwrap(URL(string: "https://cdn.example.net/vocabulary.txt"))
        Stub.answer { request in
            request.url == elsewhere
                ? .response(status: 200, headers: Self.plainText, body: Data("Aster\n".utf8))
                : .redirect(status: 302, location: elsewhere)
        }

        let result = await makeFetcher(totalDeadline: .seconds(3)).fetch(url: Self.address, token: "secret", validators: nil)

        XCTAssertEqual(result, .failed(.redirectToOtherServer))
        XCTAssertEqual(Stub.requests.map(\.url), [Self.address])
    }

    private func makeFetcher(totalDeadline: Duration = .seconds(20)) -> RemoteVocabularyFetcher {
        RemoteVocabularyFetcher(session: Stub.makeSession(), totalDeadline: totalDeadline)
    }
}
