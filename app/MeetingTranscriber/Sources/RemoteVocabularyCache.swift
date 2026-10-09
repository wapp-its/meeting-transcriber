import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RemoteVocabulary")

/// A downloaded vocabulary as read back from the cache.
struct RemoteVocabularyCopy: Equatable {
    let data: Data
    let termCount: Int
    /// The validators of the response this text came from; nil unless the
    /// sidecar matched this text and carried any.
    let validators: RemoteVocabularyValidators?
    /// From the sidecar, or the text file's modification date when the
    /// sidecar was not trusted.
    let updatedAt: Date
    /// Nil when the sidecar was not trusted.
    let checkedAt: Date?
}

/// The on-disk copies of downloaded vocabularies, one text file plus a JSON
/// sidecar per (bundle identifier, address).
///
/// - **One file per address.** The name carries a hash of the normalized
///   address, so a copy fetched for one address can never be read for another,
///   whatever happens to deletions, and the path stays stable for one address:
///   replacing the content gives the engines a new file revision, which they
///   already pick up before their next decode.
/// - **Per bundle identifier**, because the dev and release builds share
///   `AppPaths.dataDir`; neither reads or deletes the other's copies.
/// - **Commit order: text, then sidecar, then rename.** The new text goes to a
///   temporary file, the sidecar (with the new text's SHA-256) is written
///   atomically, then the temporary file is renamed over the text. A failure
///   before the rename leaves the previous text in use; a failed rename leaves
///   the previous text under a sidecar that no longer matches it.
/// - **The sidecar is trusted only when it names this address and its hash
///   matches the text on disk.** Otherwise the text stays in use without
///   validators, so the next check downloads in full and a 304 can never pin
///   text the validators do not describe.
struct RemoteVocabularyCache {
    enum CommitStep {
        case temporaryText
        case sidecar
        case rename
    }

    let directory: URL
    let bundleID: String

    static func textFile(in directory: URL, bundleID: String, address: String) -> URL {
        let digest = SHA256.hash(data: Data(RemoteVocabulary.normalizedAddress(address).utf8))
        let addressKey = String(hex(digest).prefix(addressKeyLength))
        return directory.appendingPathComponent("\(filePrefix(bundleID: bundleID))\(addressKey).txt")
    }

    /// Returns this address's copy when its text is present and valid. Invalid
    /// or missing text deletes the pair; an untrusted sidecar is deleted and
    /// the text is returned without validators.
    func load(for address: String) -> RemoteVocabularyCopy? {
        let textURL = textFile(for: address)
        guard let revision = WhisperVocabularyPrompt.fileRevision(at: textURL.path),
              revision.fileSize <= UInt64(WhisperVocabularyPrompt.maximumFileBytes),
              let data = try? Data(contentsOf: textURL),
              case let .ready(termCount) = CustomVocabularyValidation.validate(data: data)
        else {
            discard(for: address)
            return nil
        }
        let sidecarURL = Self.sidecarFile(for: textURL)
        if let sidecar = Self.readSidecar(at: sidecarURL),
           RemoteVocabulary.normalizedAddress(sidecar.metadata.url) == RemoteVocabulary.normalizedAddress(address),
           sidecar.sha256 == Self.sha256(of: data) {
            return RemoteVocabularyCopy(
                data: data,
                termCount: termCount,
                validators: sidecar.metadata.validators,
                updatedAt: sidecar.metadata.updatedAt,
                checkedAt: sidecar.metadata.checkedAt,
            )
        }
        remove(sidecarURL)
        return RemoteVocabularyCopy(
            data: data, termCount: termCount, validators: nil, updatedAt: revision.modificationTime, checkedAt: nil,
        )
    }

    /// Replaces the copy for `metadata.url` with `text`. Throws on any failure;
    /// a throw before the final rename leaves the previous pair untouched.
    func store(_ text: Data, metadata: RemoteVocabularyMetadata) throws {
        try commit(text, metadata: metadata, failingAt: nil)
    }

    /// Rewrites only the sidecar, for an answer that confirmed the copy (a 304,
    /// or a body identical to it). The hash is taken from `text`, the copy the
    /// answer was checked against, never re-read from disk: if the file on disk
    /// differs, `load` then distrusts the sidecar instead of it blessing text
    /// the validators do not describe.
    func updateMetadata(_ metadata: RemoteVocabularyMetadata, describing text: Data) throws {
        try writeSidecar(metadata, describing: text, beside: textFile(for: metadata.url))
    }

    /// Removes this address's pair, tolerating its absence.
    func discard(for address: String) {
        let textURL = textFile(for: address)
        remove(textURL)
        remove(Self.sidecarFile(for: textURL))
    }

    /// Removes this bundle's files for every address but `address`, including
    /// temporary files an interrupted commit left behind. A file that cannot be
    /// deleted is logged and skipped; it is never read, because reads go only
    /// through the current address's name.
    func discardAll(except address: String) {
        let keptText = textFile(for: address)
        let kept: Set = [keptText.lastPathComponent, Self.sidecarFile(for: keptText).lastPathComponent]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where isOwnFile(name) && !kept.contains(name) {
            remove(directory.appendingPathComponent(name))
        }
    }

    #if DEBUG
        /// `store` with one commit step failing, so tests can fail each in turn.
        func storeForTesting(_ text: Data, metadata: RemoteVocabularyMetadata, failingAt step: CommitStep) throws {
            try commit(text, metadata: metadata, failingAt: step)
        }
    #endif

    // MARK: - Private

    private static let addressKeyLength = 16

    /// The JSON beside a text file: the metadata plus the SHA-256 of the text
    /// it describes, flattened into one object.
    private struct Sidecar: Codable {
        let sha256: String
        let metadata: RemoteVocabularyMetadata

        private enum CodingKeys: String, CodingKey {
            case sha256
        }

        init(sha256: String, metadata: RemoteVocabularyMetadata) {
            self.sha256 = sha256
            self.metadata = metadata
        }

        init(from decoder: any Decoder) throws {
            sha256 = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .sha256)
            metadata = try RemoteVocabularyMetadata(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try metadata.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sha256, forKey: .sha256)
        }
    }

    private static func filePrefix(bundleID: String) -> String {
        "remote-vocabulary-\(bundleID)-"
    }

    private static func sidecarFile(for textFile: URL) -> URL {
        textFile.deletingPathExtension().appendingPathExtension("json")
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func readSidecar(at url: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Sidecar.self, from: data)
    }

    private func textFile(for address: String) -> URL {
        Self.textFile(in: directory, bundleID: bundleID, address: address)
    }

    private func writeSidecar(_ metadata: RemoteVocabularyMetadata, describing text: Data, beside textURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sidecar = Sidecar(sha256: Self.sha256(of: text), metadata: metadata)
        try encoder.encode(sidecar).write(to: Self.sidecarFile(for: textURL), options: .atomic)
    }

    /// This bundle's prefix followed by an address key and a dot. Checking the
    /// key, not just the prefix, keeps a bundle whose identifier extends this
    /// one with a dash (`com.a` and `com.a-b`) out of reach.
    private func isOwnFile(_ name: String) -> Bool {
        let prefix = Self.filePrefix(bundleID: bundleID)
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        let key = rest.prefix(Self.addressKeyLength)
        return key.count == Self.addressKeyLength
            && key.allSatisfy(\.isHexDigit)
            && rest.dropFirst(Self.addressKeyLength).first == "."
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error(
                "Could not delete \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)",
            )
        }
    }

    private func commit(_ text: Data, metadata: RemoteVocabularyMetadata, failingAt failingStep: CommitStep?) throws {
        let textURL = textFile(for: metadata.url)
        let temporaryURL = textURL.appendingPathExtension("\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Self.fail(.temporaryText, at: failingStep)
            try text.write(to: temporaryURL)
            try Self.fail(.sidecar, at: failingStep)
            try writeSidecar(metadata, describing: text, beside: textURL)
            try Self.fail(.rename, at: failingStep)
            guard rename(temporaryURL.path, textURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func fail(_ step: CommitStep, at failingStep: CommitStep?) throws {
        if step == failingStep { throw CocoaError(.fileWriteUnknown) }
    }
}
