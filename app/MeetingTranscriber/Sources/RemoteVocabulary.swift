import Foundation

/// Where the custom vocabulary comes from. One source at a time: with `.url`
/// the engines read only the downloaded copy. Nothing is merged with the local
/// file and nothing falls back to it, so a central list never silently turns
/// into a personal one.
enum VocabularySource: String, CaseIterable {
    case file
    case url

    var label: String {
        switch self {
        case .file: "Local file"
        case .url: "URL"
        }
    }
}

/// Why a configured address is not fetched.
enum RemoteVocabularyAddressProblem: Error, Equatable {
    case empty
    case notHTTPS
    case missingHost

    var message: String {
        switch self {
        case .empty: "No address entered"
        case .notHTTPS: "The address must start with https://"
        case .missingHost: "The address names no server"
        }
    }
}

/// Address handling shared by the fetcher, the cache and the settings.
enum RemoteVocabulary {
    /// The form an address is keyed and compared by: surrounding whitespace,
    /// a pasted trailing newline included, never names a different file.
    static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only `https://` addresses with a server name are fetched. Plain http is
    /// refused because the optional access token would travel in clear text.
    static func validateAddress(_ address: String) -> Result<URL, RemoteVocabularyAddressProblem> {
        let trimmed = normalizedAddress(address)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.lowercased().hasPrefix("https://") else { return .failure(.notHTTPS) }
        guard let url = URL(string: trimmed),
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return .failure(.missingHost) }
        return .success(url)
    }
}

/// The HTTP validators of the response a copy came from. `nil` stands for a
/// response that carried neither, so "no validators" has one spelling and the
/// fetcher sends conditional headers only when it has something to send.
struct RemoteVocabularyValidators: Equatable, Sendable {
    let etag: String?
    let lastModified: String?

    init?(etag: String?, lastModified: String?) {
        let etag = etag.flatMap { $0.isEmpty ? nil : $0 }
        let lastModified = lastModified.flatMap { $0.isEmpty ? nil : $0 }
        guard etag != nil || lastModified != nil else { return nil }
        self.etag = etag
        self.lastModified = lastModified
    }
}

/// What the cache records beside a downloaded copy. `updatedAt` is when the
/// content last changed, `checkedAt` when the server was last reached. The
/// term count is not stored: it is derived from the text whenever it is read.
struct RemoteVocabularyMetadata: Codable, Equatable, Sendable {
    /// The address the copy was downloaded from, compared in normalized form.
    let url: String
    let etag: String?
    let lastModified: String?
    let updatedAt: Date
    let checkedAt: Date

    var validators: RemoteVocabularyValidators? {
        RemoteVocabularyValidators(etag: etag, lastModified: lastModified)
    }
}

/// Why a check did not produce a usable copy.
enum RemoteVocabularyFailure: Equatable, Sendable {
    case offline
    case timedOut
    case httpStatus(Int)
    /// With a token set, a redirect to another host is not followed, so the
    /// token never reaches a server the user did not name.
    case redirectToOtherServer
    case insecureRedirect
    case notTextFile
    case tooLarge
    case invalidContent(CustomVocabularyValidation)
    case couldNotSave
    /// A 304 to a request that sent no validators: there is nothing it could
    /// confirm, so it is not taken as "the copy is current".
    case unexpectedNotModified
    case cancelled

    var message: String {
        switch self {
        case .offline: "No connection to the server"
        case .timedOut: "The server did not answer in time"
        case let .httpStatus(code) where code == 401 || code == 403: "Access denied (HTTP \(code)) – check the access token"
        case .httpStatus(404): "Not found (HTTP 404) – check the address"
        case let .httpStatus(code): "The server answered with HTTP \(code)"
        case .redirectToOtherServer: "The address redirects to another server; the token is not sent there"
        case .insecureRedirect: "The address redirects to an address without https"
        case .notTextFile: "The address returned a web page, not a text file"
        case .tooLarge: "The file is larger than \(WhisperVocabularyPrompt.maximumFileBytes / 1024) KB"
        case let .invalidContent(validation): Self.sentenceFragment(validation.message)
        case .couldNotSave: "The download could not be saved"
        case .unexpectedNotModified: "The server reported no change for a copy this app does not have"
        case .cancelled: "The check was cancelled"
        }
    }

    /// The local file's validation sentences end with a period; here they are
    /// followed by " · using the copy …", so the period is dropped.
    private static func sentenceFragment(_ sentence: String) -> String {
        sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }
}

/// The outcome of one fetch.
enum RemoteVocabularyFetchResult: Equatable, Sendable {
    case modified(body: Data, validators: RemoteVocabularyValidators?)
    case notModified
    case failed(RemoteVocabularyFailure)
}

/// The copy the engines read, as Settings describes it.
struct RemoteVocabularyCopyInfo: Equatable, Sendable {
    let termCount: Int
    let updatedAt: Date
}

/// What Settings shows for the URL source.
enum RemoteVocabularyStatus: Equatable {
    case inactive
    case addressProblem(RemoteVocabularyAddressProblem)
    case notDownloaded
    case checking
    case current(termCount: Int, updatedAt: Date, checkedAt: Date)
    case failed(RemoteVocabularyFailure, lastGood: RemoteVocabularyCopyInfo?)

    /// `formatDate` is injected so the sentences are testable with a fixed
    /// formatter; the view passes a locale-aware one.
    func message(formatDate: (Date) -> String) -> String {
        switch self {
        case .inactive:
            "Not in use – the vocabulary comes from the local file"

        case let .addressProblem(problem):
            "\(problem.message) – no vocabulary in use"

        case .notDownloaded:
            "Not downloaded yet – no vocabulary in use"

        case .checking:
            "Checking the address…"

        case let .current(termCount, updatedAt, checkedAt):
            "\(Self.terms(termCount)) · updated \(formatDate(updatedAt)) · checked \(formatDate(checkedAt))"

        case let .failed(failure, lastGood?):
            "\(failure.message) · using the copy from \(formatDate(lastGood.updatedAt)) (\(Self.terms(lastGood.termCount)))"

        case let .failed(failure, nil):
            "\(failure.message) · no vocabulary in use"
        }
    }

    private static func terms(_ count: Int) -> String {
        "\(count) term\(count == 1 ? "" : "s")"
    }
}
