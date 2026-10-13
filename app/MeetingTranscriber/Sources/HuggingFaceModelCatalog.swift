import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "HuggingFaceModelCatalog")

/// Finds WhisperKit models on the Hugging Face Hub and lists what a repository
/// offers. Abstracted so the model browser can be tested without a network.
protocol HuggingFaceModelCataloging: Sendable {
    /// Up to 20 repositories tagged `whisperkit` whose name matches `query`, most
    /// downloaded first.
    func searchWhisperKitModels(matching query: String, token: String?) async throws -> [HuggingFaceModelSummary]

    /// The variants of `repoID` this app can load, with its license and whether it is gated.
    func repository(_ repoID: String, token: String?) async throws -> HuggingFaceRepositoryListing
}

/// One search hit.
struct HuggingFaceModelSummary: Equatable, Sendable, Identifiable {
    let id: String
    /// Nil when the API leaves the count out.
    let downloads: Int?
}

/// What one repository offers this app.
struct HuggingFaceRepositoryListing: Equatable, Sendable, Identifiable {
    let id: String
    /// Sorted by name; empty when no folder holds a complete model.
    let variants: [HuggingFaceModelVariant]
    /// Nil when the repository states none.
    let license: HuggingFaceLicense?
    let isGated: Bool
    let modelCardURL: URL
}

/// A folder of a repository that holds every file the local loader requires
/// (`WhisperKitLocalSnapshot`), so the custom-model path can download and load it.
struct HuggingFaceModelVariant: Equatable, Sendable, Identifiable {
    let name: String
    /// All files under the folder, not only the required ones, since the download
    /// fetches them all. Nil when any of them carries no size.
    let sizeBytes: Int64?

    var id: String {
        name
    }
}

/// A repository's license as Hugging Face names it.
struct HuggingFaceLicense: Equatable, Sendable {
    let identifier: String

    /// `apache-2.0` → "Apache 2.0", `mit` → "MIT", `cc-by-nc-sa-4.0` → "CC BY-NC-SA 4.0",
    /// anything else as it is.
    var label: String {
        let lowercased = identifier.lowercased()
        if lowercased == "apache-2.0" { return "Apache 2.0" }
        if lowercased == "mit" { return "MIT" }
        guard lowercased.hasPrefix("cc-") else { return identifier }
        let components = lowercased.split(separator: "-").dropFirst().map(String.init)
        let versionIndex = components.firstIndex { $0.first?.isNumber == true }
        let terms = components.indices.filter { $0 != versionIndex }.map { components[$0] }
        var parts = ["CC"]
        if !terms.isEmpty {
            parts.append(terms.joined(separator: "-").uppercased())
        }
        if let versionIndex {
            parts.append(components[versionIndex])
        }
        return parts.joined(separator: " ")
    }

    /// Any `-`-separated component reading `nc`, as in `cc-by-nc-4.0` or
    /// `swissdial-cc-by-nc-4.0-no-reidentification`.
    var isNonCommercial: Bool {
        identifier.lowercased().split(separator: "-").contains("nc")
    }

    var displayText: String {
        isNonCommercial ? "\(label) — non-commercial" : label
    }
}

/// Why a catalog call failed. Cancellation is not a case: it is rethrown as
/// `CancellationError`, because nobody is waiting for a message then.
enum HuggingFaceCatalogError: Error, Equatable {
    /// Any transport failure.
    case unreachable
    /// HTTP 401 or 403. The Hub answers an anonymous call for a private or missing
    /// repository with 401, so this is not only a rejected token.
    case refused
    case notFound
    case rateLimited
    case unexpectedStatus(Int)
    case malformedResponse
    /// Rejected before any request was sent.
    case invalidRepository

    var message: String {
        switch self {
        case .unreachable:
            "Cannot reach Hugging Face. Models already on this Mac keep working."

        case .refused:
            "Hugging Face refused the request: the repository is private or does not exist, or the token in Settings was not accepted."

        case .notFound:
            "Hugging Face has no such repository."

        case .rateLimited:
            "Hugging Face is limiting requests. Try again in a minute."

        case let .unexpectedStatus(status):
            "Hugging Face answered with HTTP \(status)."

        case .malformedResponse:
            "Hugging Face sent a response this app cannot read."

        case .invalidRepository:
            "Not a valid Hugging Face repository name."
        }
    }
}

/// The two Hub API calls the model browser makes: a search over repositories
/// tagged `whisperkit`, and one repository's file listing with sizes, from which
/// its loadable variants, license and gated flag are read.
///
/// The token is sent as a bearer token only when it is non-empty after trimming.
/// Nothing the person typed or the Hub sent is logged, and never the token: a
/// failure logs its HTTP status or error type only.
struct HuggingFaceModelCatalog: HuggingFaceModelCataloging {
    static let requestTimeout: TimeInterval = 20
    private static let searchLimit = 20
    private static let hubHost = "huggingface.co"

    /// What a folder must hold to be a variant, relative to it.
    private static let requiredVariantFiles = Set(
        WhisperKitLocalSnapshot.requiredBundles.flatMap { bundle in
            WhisperKitLocalSnapshot.requiredFiles.map { "\(bundle).mlmodelc/\($0)" }
        },
    )

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchWhisperKitModels(matching query: String, token: String?) async throws -> [HuggingFaceModelSummary] {
        let url = Self.hubURL(path: "/api/models", queryItems: [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "whisperkit"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(Self.searchLimit)),
        ])
        let data = try await get(url, token: token, call: "search")
        let entries = try Self.decode([SearchEntry].self, from: data, call: "search")
        return entries
            .filter { AppSettings.isValidRepoID($0.id) }
            .map { HuggingFaceModelSummary(id: $0.id, downloads: $0.downloads) }
    }

    func repository(_ repoID: String, token: String?) async throws -> HuggingFaceRepositoryListing {
        guard AppSettings.isValidRepoID(repoID) else { throw HuggingFaceCatalogError.invalidRepository }
        let url = Self.hubURL(path: "/api/models/\(repoID)", queryItems: [URLQueryItem(name: "blobs", value: "true")])
        let data = try await get(url, token: token, call: "listing")
        let response = try Self.decode(RepositoryResponse.self, from: data, call: "listing")
        return HuggingFaceRepositoryListing(
            id: repoID,
            variants: Self.variants(in: response.siblings),
            license: Self.license(card: response.cardData, tags: response.tags),
            isGated: response.gated?.isGated ?? false,
            modelCardURL: Self.hubURL(path: "/\(repoID)"),
        )
    }

    // MARK: - Transport

    private static func hubURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = hubHost
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
            // URLComponents leaves "+" as it is, which the Hub reads as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        // A scheme, a host and a path starting with "/" always form a URL; the only
        // caller-supplied path part is a repository id `isValidRepoID` accepted.
        // swiftlint:disable:next force_unwrapping
        return components.url!
    }

    private func get(_ url: URL, token: String?, call: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportFailure(error, call: call)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            logger.warning("Hugging Face \(call, privacy: .public): not an HTTP response")
            throw HuggingFaceCatalogError.malformedResponse
        }
        guard status == 200 else {
            logger.warning("Hugging Face \(call, privacy: .public) answered HTTP \(status, privacy: .public)")
            throw Self.failure(forStatus: status)
        }
        return data
    }

    private static func failure(forStatus status: Int) -> HuggingFaceCatalogError {
        switch status {
        case 401, 403: .refused
        case 404: .notFound
        case 429: .rateLimited
        default: .unexpectedStatus(status)
        }
    }

    private static func transportFailure(_ error: any Error, call: String) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            logger.warning("Hugging Face \(call, privacy: .public) failed: URLError \(urlError.code.rawValue, privacy: .public)")
        } else {
            logger.warning("Hugging Face \(call, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return HuggingFaceCatalogError.unreachable
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, call: String) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.warning("Hugging Face \(call, privacy: .public) sent a response that does not decode")
            throw HuggingFaceCatalogError.malformedResponse
        }
    }

    // MARK: - Reading a listing

    /// Top-level folders holding every required file under a name the settings
    /// accept as a variant, sorted by name.
    private static func variants(in siblings: [RepositoryResponse.Sibling]) -> [HuggingFaceModelVariant] {
        var filesByFolder: [String: [(path: String, size: Int64?)]] = [:]
        for sibling in siblings {
            let parts = sibling.rfilename.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            filesByFolder[String(parts[0]), default: []].append((String(parts[1]), sibling.size))
        }
        return filesByFolder
            .compactMap { folder, files -> HuggingFaceModelVariant? in
                guard AppSettings.isValidVariant(folder),
                      requiredVariantFiles.isSubset(of: files.map(\.path))
                else { return nil }
                let sizes = files.compactMap(\.size)
                return HuggingFaceModelVariant(name: folder, sizeBytes: sizes.count == files.count ? sizes.reduce(0, +) : nil)
            }
            .sorted { $0.name < $1.name }
    }

    /// The model card's license; for `other`, the card's `license_name`; without a
    /// card license, the first `license:` tag.
    private static func license(card: RepositoryResponse.CardData?, tags: [String]) -> HuggingFaceLicense? {
        let tagPrefix = "license:"
        let tagged = tags.first { $0.hasPrefix(tagPrefix) }.map { String($0.dropFirst(tagPrefix.count)) }
        guard let stated = nonEmpty(card?.license?.first) ?? nonEmpty(tagged) else { return nil }
        if stated.lowercased() == "other", let name = nonEmpty(card?.licenseName) {
            return HuggingFaceLicense(identifier: name)
        }
        return HuggingFaceLicense(identifier: stated)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - API answers

/// One entry of `GET /api/models`.
private struct SearchEntry: Decodable {
    let id: String
    let downloads: Int?
}

/// The fields of `GET /api/models/<owner>/<name>?blobs=true` the listing reads.
private struct RepositoryResponse: Decodable {
    struct Sibling: Decodable {
        let rfilename: String
        let size: Int64?
    }

    struct CardData: Decodable {
        let license: LicenseValue?
        let licenseName: String?

        private enum CodingKeys: String, CodingKey {
            case license
            case licenseName = "license_name"
        }
    }

    let siblings: [Sibling]
    let gated: GatedValue?
    let cardData: CardData?
    let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case siblings, gated, cardData, tags
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siblings = try container.decode([Sibling].self, forKey: .siblings)
        gated = try container.decodeIfPresent(GatedValue.self, forKey: .gated)
        cardData = try container.decodeIfPresent(CardData.self, forKey: .cardData)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// `cardData.license`: one id, or a list of them of which the first counts.
private struct LicenseValue: Decodable {
    let first: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            first = single
        } else {
            first = try container.decode([String].self).first
        }
    }
}

/// `gated`: `false`, or how access is granted (`"auto"`, `"manual"`).
private struct GatedValue: Decodable {
    let isGated: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            isGated = flag
        } else {
            isGated = try !container.decode(String.self).isEmpty
        }
    }
}
