@testable import MeetingTranscriber
import XCTest

/// The summary file (spec R1): what survives a restart, what a second running build
/// writing the same file leaves intact, and what an unreadable file, a held lock or a
/// failed write do. Every summary here is made up.
@MainActor
final class MeetingSummaryStoreTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makePath() throws -> URL {
        try makeTempDirectory(prefix: "meeting-summary-store").appendingPathComponent(MeetingSummaryStore.filename)
    }

    private func notes(_ text: String) -> MeetingSummaries {
        MeetingSummaries(notes: .init(text: text, writtenAt: date))
    }

    func testSummariesSurviveInANewStoreInAnOwnerOnlyFile() throws {
        let path = try makePath()
        let (first, second) = (UUID(), UUID())
        let store = MeetingSummaryStore(path: path)
        let typed = MeetingSummaries(notes: .init(text: "From the notes", writtenAt: date), typed: .init(text: "Mine", writtenAt: date))

        XCTAssertTrue(store.update(jobID: first) { _ in typed })
        XCTAssertTrue(store.update(jobID: second) { _ in self.notes("Second") })
        XCTAssertTrue(store.remove(jobID: second))

        XCTAssertEqual(MeetingSummaryStore(path: path).summaries, [first: typed])
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// Another build's store wrote a meeting after this one last read the file: each
    /// write reads the file again under the lock, so both meetings stay.
    func testTwoWritersKeepEachOthersMeetings() throws {
        let path = try makePath()
        let (mine, theirs) = (UUID(), UUID())
        let store = MeetingSummaryStore(path: path)
        let other = MeetingSummaryStore(path: path)

        other.update(jobID: theirs) { _ in self.notes("Theirs") }
        store.update(jobID: mine) { _ in self.notes("Mine") }

        XCTAssertEqual(store.summaries, [mine: notes("Mine"), theirs: notes("Theirs")])
        XCTAssertEqual(MeetingSummaryStore(path: path).summaries.count, 2)
    }

    /// A file that does not decode, or names a format this build does not know, is
    /// moved aside before anything new is written, and the store starts empty.
    func testAnUndecodableFileIsMovedAsideAndTheStoreStartsEmpty() throws {
        let path = try makePath()
        let aside = path.appendingPathExtension("unreadable")
        for content in [Data("not json".utf8), Data(#"{"version":2,"summaries":{}}"#.utf8)] {
            try content.write(to: path)

            let store = MeetingSummaryStore(path: path)

            XCTAssertEqual(store.summaries, [:])
            XCTAssertEqual(try Data(contentsOf: aside), content)
            XCTAssertTrue(store.update(jobID: UUID()) { _ in self.notes("New") })
            XCTAssertEqual(MeetingSummaryStore(path: path).summaries.count, 1)
        }
    }

    /// The other build holds the lock past the wait: the write fails and nothing changes.
    func testAWriteFailsWhileTheLockStaysHeld() throws {
        let path = try makePath()
        let store = MeetingSummaryStore(path: path)
        let descriptor = open(path.path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0, "test premise: this handle holds the lock")

        XCTAssertFalse(store.update(jobID: UUID()) { _ in self.notes("New") })

        close(descriptor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    /// A write that fails leaves the summaries as the file holds them.
    func testAFailedWriteReturnsFalseAndKeepsWhatTheFileHolds() throws {
        let path = try makePath()
        let kept = UUID()
        let store = MeetingSummaryStore(path: path)
        store.update(jobID: kept) { _ in self.notes("Kept") }
        let folder = path.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        XCTAssertFalse(store.update(jobID: UUID()) { _ in self.notes("New") })

        XCTAssertEqual(store.summaries, [kept: notes("Kept")])
    }

    func testRemoveAllExceptKeepsOnlyTheMeetingsAsked() throws {
        let path = try makePath()
        let (kept, dropped) = (UUID(), UUID())
        let store = MeetingSummaryStore(path: path)
        store.update(jobID: kept) { _ in self.notes("Kept") }
        store.update(jobID: dropped) { _ in self.notes("Dropped") }

        XCTAssertTrue(store.removeAll { $0 == kept })

        XCTAssertEqual(MeetingSummaryStore(path: path).summaries, [kept: notes("Kept")])
    }
}
