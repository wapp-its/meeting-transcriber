@testable import MeetingTranscriber
import XCTest

// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`,
// so there's no explicit `tearDown` to balance `setUp`.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class ProcessedRecordingsLedgerTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "processed_ledger_test")
    }

    // MARK: - markProcessed

    func testMarkProcessedRoundTrips() throws {
        let mixPath = tmpDir.appendingPathComponent("test_mix.wav")

        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        ledger.markProcessed(mixPath: mixPath)

        // A fresh ledger over the same dir must see the persisted path.
        let reloaded = ProcessedRecordingsLedger(logDir: tmpDir)
        XCTAssertTrue(reloaded.load().contains(mixPath.standardizedFileURL.path))

        // On-disk format stays a JSON array of standardized path strings.
        let data = try Data(contentsOf: ledger.path)
        let paths = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(paths, [mixPath.standardizedFileURL.path])
    }

    func testMarkProcessedNilIsNoOp() {
        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        ledger.markProcessed(mixPath: nil)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ledger.path.path),
            "nil mixPath must not create the ledger file",
        )
        XCTAssertTrue(ledger.load().isEmpty)
    }

    // MARK: - load

    func testLoadReturnsEmptyWhenFileMissing() {
        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        XCTAssertTrue(ledger.load().isEmpty)
    }

    func testLoadReturnsEmptyOnCorruptFile() throws {
        let ledger = ProcessedRecordingsLedger(logDir: tmpDir)
        try Data("not json".utf8).write(to: ledger.path)
        XCTAssertTrue(ledger.load().isEmpty)
    }
}
