import Foundation
import os

/// Fetches a vocabulary file from a web address. Abstracted so the refresh
/// logic can be tested without a network.
protocol RemoteVocabularyFetching: Sendable {
    func fetch(url: URL, token: String?, validators: RemoteVocabularyValidators?) async -> RemoteVocabularyFetchResult
}

/// One conditional GET over its own `URLSession`.
///
/// - **No URL cache.** The session has `urlCache = nil` and ignores local cache
///   data, and the conditional headers are set here. With a cache in place
///   Foundation may revalidate on its own and hand back its cached 200 for a
///   304, and the caller could no longer tell "unchanged" from "downloaded".
/// - **Two time limits.** The request timeout (30 s) only bounds inactivity,
///   so a server trickling bytes would keep a check open indefinitely; the
///   whole fetch is therefore raced against a total deadline (60 s) and the
///   transfer is cancelled when it expires.
/// - **Redirects** follow `redirectRefusal(from:to:tokenPresent:)`: never to a
///   non-https address, and with a token never to another host, so the token
///   only reaches the server the user named. A refused redirect leaves the 3xx
///   as the task's result, which is reported as the refusal.
/// - **Bounded body.** A body is read only up to the vocabulary size limit plus
///   one byte; a larger one is abandoned and reported as too large.
struct RemoteVocabularyFetcher: RemoteVocabularyFetching {
    static let idleTimeout: TimeInterval = 30
    static let defaultTotalDeadline: Duration = .seconds(60)

    private let session: URLSession
    private let totalDeadline: Duration

    init(
        session: URLSession = URLSession(configuration: Self.makeConfiguration()),
        totalDeadline: Duration = defaultTotalDeadline,
    ) {
        self.session = session
        self.totalDeadline = totalDeadline
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = idleTimeout
        return configuration
    }

    /// Returns why a redirect from the configured address to `target` is not
    /// followed, or nil when it may be.
    static func redirectRefusal(from origin: URL, to target: URL, tokenPresent: Bool) -> RemoteVocabularyFailure? {
        guard target.scheme?.lowercased() == "https" else { return .insecureRedirect }
        guard tokenPresent else { return nil }
        let originHost = origin.host(percentEncoded: false)?.lowercased()
        let targetHost = target.host(percentEncoded: false)?.lowercased()
        return originHost == targetHost ? nil : .redirectToOtherServer
    }

    func fetch(url: URL, token: String?, validators: RemoteVocabularyValidators?) async -> RemoteVocabularyFetchResult {
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = Self.makeRequest(url: url, token: token, validators: validators)
        let redirectGuard = RedirectGuard(origin: url, tokenPresent: !token.isEmpty)
        let validatorsSent = validators != nil
        let session = session
        let deadline = totalDeadline
        return await withTaskGroup(of: RemoteVocabularyFetchResult.self) { group in
            group.addTask {
                await Self.transfer(request, session: session, redirectGuard: redirectGuard, validatorsSent: validatorsSent)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline)
                } catch {
                    return .failed(.cancelled)
                }
                return .failed(.timedOut)
            }
            let first = await group.next() ?? .failed(.cancelled)
            group.cancelAll()
            return first
        }
    }

    private static func makeRequest(url: URL, token: String, validators: RemoteVocabularyValidators?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
        request.httpMethod = "GET"
        if let etag = validators?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func transfer(
        _ request: URLRequest, session: URLSession, redirectGuard: RedirectGuard, validatorsSent: Bool,
    ) async -> RemoteVocabularyFetchResult {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        } catch {
            return .failed(redirectGuard.refusal ?? failure(for: error))
        }
        // Ends the transfer on every early return, so an abandoned body is not
        // downloaded to the end in the background.
        defer { bytes.task.cancel() }
        if let refusal = redirectGuard.refusal { return .failed(refusal) }
        guard let http = response as? HTTPURLResponse else { return .failed(.offline) }
        switch http.statusCode {
        case 200:
            return await body(of: http, bytes: bytes)

        case 304:
            return validatorsSent ? .notModified : .failed(.unexpectedNotModified)

        default:
            return .failed(.httpStatus(http.statusCode))
        }
    }

    private static func body(of response: HTTPURLResponse, bytes: URLSession.AsyncBytes) async -> RemoteVocabularyFetchResult {
        // A sign-in page after a redirect, or an error page served with 200,
        // would otherwise pass a one-term-per-line parse.
        if isWebPage(contentType: response.value(forHTTPHeaderField: "Content-Type")) {
            return .failed(.notTextFile)
        }
        let limit = WhisperVocabularyPrompt.maximumFileBytes
        if response.expectedContentLength > Int64(limit) { return .failed(.tooLarge) }
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > limit { return .failed(.tooLarge) }
            }
        } catch {
            return .failed(failure(for: error))
        }
        let validators = RemoteVocabularyValidators(
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
        )
        return .modified(body: body, validators: validators)
    }

    private static func isWebPage(contentType: String?) -> Bool {
        guard let mediaType = contentType?.split(separator: ";", maxSplits: 1).first else { return false }
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "text/html"
    }

    private static func failure(for error: any Error) -> RemoteVocabularyFailure {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .offline
    }
}

/// Applies the redirect policy for one fetch and remembers a refusal, which
/// the fetch reads after the transfer completes.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: URL
    private let tokenPresent: Bool
    private let refusalState = OSAllocatedUnfairLock<RemoteVocabularyFailure?>(initialState: nil)

    init(origin: URL, tokenPresent: Bool) {
        self.origin = origin
        self.tokenPresent = tokenPresent
    }

    var refusal: RemoteVocabularyFailure? {
        refusalState.withLock { $0 }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @Sendable (URLRequest?) -> Void,
    ) {
        guard let target = request.url else {
            completionHandler(nil)
            return
        }
        if let refusal = RemoteVocabularyFetcher.redirectRefusal(from: origin, to: target, tokenPresent: tokenPresent) {
            refusalState.withLock { $0 = refusal }
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}
