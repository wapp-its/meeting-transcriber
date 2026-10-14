import Foundation
@testable import MeetingTranscriber
import os

/// URL-loading stub for `RemoteVocabularyFetcher` tests: records every request
/// it sees and answers with the reply the test installed. Separate from the
/// shared `MockURLProtocol` so these tests own their state. Call `reset()` in
/// both `setUp` and `tearDown`.
final class RemoteVocabularyURLProtocolStub: URLProtocol {
    enum Reply {
        case response(status: Int, headers: [String: String], body: Data)
        case transportError(URLError.Code)
        /// Delivers the response and a first chunk, then never finishes.
        case stall(status: Int, headers: [String: String], firstChunk: Data)
        case redirect(status: Int, location: URL)
    }

    private struct State {
        var reply: (@Sendable (URLRequest) -> Reply)?
        var requests: [URLRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    static func answer(_ reply: @escaping @Sendable (URLRequest) -> Reply) {
        state.withLock { $0.reply = reply }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    /// The production session configuration with this stub in front.
    static func makeSession() -> URLSession {
        let configuration = RemoteVocabularyFetcher.makeConfiguration()
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let reply = Self.state.withLock { state in
            state.requests.append(request)
            return state.reply
        }
        guard let client, let url = request.url else { return }
        switch reply?(request) ?? .transportError(.badServerResponse) {
        case let .response(status, headers, body):
            client.urlProtocol(self, didReceive: Self.response(url, status, headers), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)

        case let .transportError(code):
            client.urlProtocol(self, didFailWithError: URLError(code))

        case let .stall(status, headers, firstChunk):
            client.urlProtocol(self, didReceive: Self.response(url, status, headers), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: firstChunk)

        case let .redirect(status, location):
            var redirected = request
            redirected.url = location
            let response = Self.response(url, status, ["Location": location.absoluteString])
            client.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func response(_ url: URL, _ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        // swiftlint:disable:next force_unwrapping
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
