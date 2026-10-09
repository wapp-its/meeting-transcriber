import CryptoKit
import Foundation
@testable import MeetingTranscriber
import XCTest

final class RemoteVocabularyCacheTests: XCTestCase {
    private static let address = "https://lists.example.org/team/vocabulary.txt"
    private static let otherAddress = "https://lists.example.org/other/vocabulary.txt"
    private static let bundleID = "com.example.transcriber"
    private static let updatedAt = Date(timeIntervalSince1970: 1_791_288_120)
    private static let checkedAt = Date(timeIntervalSince1970: 1_791_291_720)

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteVocabularyCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    func testCacheDirectoryLivesUnderTheDataDirectory() {
        XCTAssertEqual(
            AppPaths.remoteVocabularyCacheDirectory,
            AppPaths.dataDir.appendingPathComponent("vocabulary", isDirectory: true),
        )
    }

    func testFileNameIsKeyedByBundleAndTrimmedAddress() {
        let file = RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.address)

        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(file.lastPathComponent, "remote-vocabulary-\(Self.bundleID)-\(Self.addressKey(Self.address)).txt")
        XCTAssertEqual(
            RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: "  \(Self.address)\n"),
            file,
        )
        XCTAssertNotEqual(RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.otherAddress), file)
        XCTAssertNotEqual(RemoteVocabularyCache.textFile(in: directory, bundleID: "com.example.transcriber.dev", address: Self.address), file)
    }

    func testStoredCopyLoadsWithItsValidatorsDatesAndTermCount() throws {
        let cache = makeCache()
        let text = Data("Northstar\nnorthstar\nAster\n".utf8)

        try cache.store(text, metadata: metadata(etag: "\"v1\""))

        XCTAssertEqual(
            cache.load(for: "\(Self.address) "),
            RemoteVocabularyCopy(
                data: text,
                termCount: 2,
                validators: RemoteVocabularyValidators(etag: "\"v1\"", lastModified: "Tue, 06 Oct 2026 12:02:00 GMT"),
                updatedAt: Self.updatedAt,
                checkedAt: Self.checkedAt,
            ),
        )
        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecarFile(for: Self.address))) as? [String: Any],
        )
        XCTAssertEqual(Set(sidecar.keys), ["url", "sha256", "etag", "lastModified", "updatedAt", "checkedAt"])
        XCTAssertEqual(sidecar["sha256"] as? String, Self.hex(SHA256.hash(data: text)))
        XCTAssertEqual(sidecar["updatedAt"] as? String, "2026-10-06T12:02:00Z")
    }

    /// Both engines key their prepared vocabulary on the file revision, so a
    /// replaced copy of the same length must still read as a new revision.
    func testReplacingTheCopyChangesTheFileRevision() throws {
        let cache = makeCache()
        let path = RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.address).path

        try cache.store(Data("Alpha\n".utf8), metadata: metadata(etag: "\"v1\""))
        let first = try XCTUnwrap(WhisperVocabularyPrompt.fileRevision(at: path))
        try cache.store(Data("Gamma\n".utf8), metadata: metadata(etag: "\"v2\""))
        let second = try XCTUnwrap(WhisperVocabularyPrompt.fileRevision(at: path))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("Gamma\n".utf8))
    }

    func testAFailedCommitStepLeavesThePreviousTextAndThrows() throws {
        let previous = Data("Northstar\n".utf8)
        // A failed rename leaves a sidecar describing the new text, so the
        // previous text loses its validators and a 304 cannot pin it.
        let expectedValidators: [(RemoteVocabularyCache.CommitStep, RemoteVocabularyValidators?)] = [
            (.temporaryText, RemoteVocabularyValidators(etag: "\"v1\"", lastModified: "Tue, 06 Oct 2026 12:02:00 GMT")),
            (.sidecar, RemoteVocabularyValidators(etag: "\"v1\"", lastModified: "Tue, 06 Oct 2026 12:02:00 GMT")),
            (.rename, nil),
        ]

        for (failingStep, validators) in expectedValidators {
            let cache = makeCache(subdirectory: "\(failingStep)")
            try cache.store(previous, metadata: metadata(etag: "\"v1\""))

            XCTAssertThrowsError(
                try cache.storeForTesting(Data("Aster\n".utf8), metadata: metadata(etag: "\"v2\""), failingAt: failingStep),
                "\(failingStep)",
            )

            let textFile = RemoteVocabularyCache.textFile(in: cache.directory, bundleID: Self.bundleID, address: Self.address)
            XCTAssertEqual(try Data(contentsOf: textFile), previous, "\(failingStep)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).count, 2, "\(failingStep)")
            XCTAssertEqual(cache.load(for: Self.address)?.data, previous, "\(failingStep)")
            XCTAssertEqual(cache.load(for: Self.address)?.validators, validators, "\(failingStep)")
        }
    }

    func testMissingOrInvalidTextDeletesThePair() throws {
        let cache = makeCache()
        let contents: [(String, Data?)] = [
            ("missing", nil),
            ("empty", Data("\n \n".utf8)),
            ("not UTF-8", Data([0xFF, 0xFE, 0xFD])),
            ("too many terms", Data((0 ... 256).map { "Term\($0)" }.joined(separator: "\n").utf8)),
        ]

        for (label, text) in contents {
            try cache.store(Data("Northstar\n".utf8), metadata: metadata(etag: "\"v1\""))
            let textFile = RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.address)
            if let text {
                try text.write(to: textFile)
            } else {
                try FileManager.default.removeItem(at: textFile)
            }

            XCTAssertNil(cache.load(for: Self.address), label)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], label)
        }
    }

    func testUntrustedSidecarIsDeletedAndTheTextKeptWithoutValidators() throws {
        let cache = makeCache()
        let text = Data("Northstar\n".utf8)
        let sidecar = sidecarFile(for: Self.address)
        let damages: [(String, () throws -> Void)] = [
            ("missing", { try FileManager.default.removeItem(at: sidecar) }),
            ("corrupt", { try Data("{".utf8).write(to: sidecar) }),
            ("foreign", {
                try cache.updateMetadata(self.metadata(etag: "\"v1\"", url: Self.otherAddress), describing: text)
                try FileManager.default.removeItem(at: sidecar)
                try FileManager.default.moveItem(at: self.sidecarFile(for: Self.otherAddress), to: sidecar)
            }),
            ("other text", { try cache.updateMetadata(self.metadata(etag: "\"v1\""), describing: Data("Aster\n".utf8)) }),
        ]

        for (label, damage) in damages {
            try cache.store(text, metadata: metadata(etag: "\"v1\""))
            try damage()
            let textFile = RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.address)
            let modified = try XCTUnwrap(WhisperVocabularyPrompt.fileRevision(at: textFile.path)).modificationTime

            XCTAssertEqual(
                cache.load(for: Self.address),
                RemoteVocabularyCopy(data: text, termCount: 1, validators: nil, updatedAt: modified, checkedAt: nil),
                label,
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), label)
        }
    }

    func testUpdatingMetadataLeavesTheTextFileUntouched() throws {
        let cache = makeCache()
        let text = Data("Northstar\n".utf8)
        try cache.store(text, metadata: metadata(etag: "\"v1\""))
        let path = RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.address).path
        let revision = WhisperVocabularyPrompt.fileRevision(at: path)
        let later = Self.checkedAt.addingTimeInterval(3600)

        try cache.updateMetadata(metadata(etag: "\"v2\"", checkedAt: later), describing: text)

        XCTAssertEqual(WhisperVocabularyPrompt.fileRevision(at: path), revision)
        XCTAssertEqual(cache.load(for: Self.address)?.validators?.etag, "\"v2\"")
        XCTAssertEqual(cache.load(for: Self.address)?.checkedAt, later)
    }

    func testDiscardRemovesBothFilesAndToleratesAbsence() throws {
        let cache = makeCache()
        try cache.store(Data("Northstar\n".utf8), metadata: metadata(etag: "\"v1\""))

        cache.discard(for: Self.address)
        cache.discard(for: Self.address)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testDiscardAllRemovesOnlyThisBundlesOtherAddresses() throws {
        let cache = makeCache()
        let otherBundle = RemoteVocabularyCache(directory: directory, bundleID: "com.example.transcriber.dev")
        let dashedBundle = RemoteVocabularyCache(directory: directory, bundleID: "\(Self.bundleID)-beta")
        for store in [cache, otherBundle, dashedBundle] {
            try store.store(Data("Northstar\n".utf8), metadata: metadata(etag: "\"v1\""))
            try store.store(Data("Aster\n".utf8), metadata: metadata(etag: "\"v1\"", url: Self.otherAddress))
        }
        let keptText = RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.address)
        let leftover = keptText.appendingPathExtension("\(UUID().uuidString).tmp")
        try Data("Aster\n".utf8).write(to: leftover)
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))

        cache.discardAll(except: Self.address)

        let removed = try before.subtracting(FileManager.default.contentsOfDirectory(atPath: directory.path))
        let otherText = RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: Self.otherAddress)
        XCTAssertEqual(removed, [otherText.lastPathComponent, sidecarFile(for: Self.otherAddress).lastPathComponent, leftover.lastPathComponent])
        XCTAssertEqual(cache.load(for: Self.address)?.data, Data("Northstar\n".utf8))
    }

    // MARK: - Helpers

    private func makeCache(subdirectory: String? = nil) -> RemoteVocabularyCache {
        var target: URL = directory
        if let subdirectory {
            target.appendPathComponent(subdirectory, isDirectory: true)
        }
        return RemoteVocabularyCache(directory: target, bundleID: Self.bundleID)
    }

    private func metadata(
        etag: String,
        url: String = RemoteVocabularyCacheTests.address,
        checkedAt: Date = RemoteVocabularyCacheTests.checkedAt,
    ) -> RemoteVocabularyMetadata {
        RemoteVocabularyMetadata(
            url: url,
            etag: etag,
            lastModified: "Tue, 06 Oct 2026 12:02:00 GMT",
            updatedAt: Self.updatedAt,
            checkedAt: checkedAt,
        )
    }

    private func sidecarFile(for address: String) -> URL {
        RemoteVocabularyCache.textFile(in: directory, bundleID: Self.bundleID, address: address)
            .deletingPathExtension().appendingPathExtension("json")
    }

    private static func addressKey(_ address: String) -> String {
        String(hex(SHA256.hash(data: Data(address.utf8))).prefix(16))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
