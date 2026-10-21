@testable import MeetingTranscriber
import XCTest

/// The All Recordings window's per-row cache of files on disk, and the reader
/// that fills it. Real files in a temp directory, read the way the window
/// reads them (`AllRecordingsActions.readFilesOnDisk`).
@MainActor
final class RowAvailabilityTests: XCTestCase {
    private typealias FilesOnDisk = RecordingRowActions.FilesOnDisk

    private let basename = "20261020_0900_retro_ab12cd34"

    /// A finished job whose protocol and transcript are recorded in `folder`.
    private func finished(in folder: URL) -> TranscriptionEntry {
        var job = PipelineJob(
            meetingTitle: "Retro", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/retro_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        job.protocolPath = folder.appendingPathComponent("\(basename).md")
        job.transcriptPath = folder.appendingPathComponent("\(basename).txt")
        return TranscriptionEntry(job: job, finishOrder: 0)
    }

    private func read(_ entry: TranscriptionEntry, scopeRoot: URL) -> FilesOnDisk {
        AllRecordingsActions.readFilesOnDisk(of: entry, scopeRoot: scopeRoot)
    }

    private func menu(_ entry: TranscriptionEntry, _ store: RowAvailability, scopeRoot: URL) -> [RecordingRowActions.MenuItem] {
        let onDisk = store.filesOnDisk(for: entry) { read($0, scopeRoot: scopeRoot) }
        return RecordingRowActions.menuItems(state: entry.state, onDisk: onDisk, canRetry: false)
    }

    /// A transcript deleted in Finder drops Open Transcript at the next
    /// refresh, not before, and one put back returns it at the refresh after.
    func testARemovedTranscriptLeavesTheMenuAtTheNextRefreshAndARestoredOneComesBack() throws {
        let folder = try makeTempDirectory(prefix: "row_availability_test")
        let entry = finished(in: folder)
        let transcript = try XCTUnwrap(entry.transcriptURL)
        try Data("# Retro".utf8).write(to: XCTUnwrap(entry.protocolURL))
        try Data("[Anna] Hello".utf8).write(to: transcript)
        let store = RowAvailability()
        let withTranscript: [RecordingRowActions.MenuItem] = [
            .openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true),
        ]
        XCTAssertEqual(menu(entry, store, scopeRoot: folder), withTranscript)

        try FileManager.default.removeItem(at: transcript)
        XCTAssertEqual(menu(entry, store, scopeRoot: folder), withTranscript, "read again before a refresh")
        store.refresh()
        XCTAssertEqual(
            menu(entry, store, scopeRoot: folder),
            [.openProtocol, .showInFinder, .regenerate(enabled: false)],
        )

        try Data("[Anna] Hello".utf8).write(to: transcript)
        store.refresh()
        XCTAssertEqual(menu(entry, store, scopeRoot: folder), withTranscript)
    }

    /// Between two refreshes a row is read once however often it is drawn,
    /// and each row is read on its own.
    func testARenderBetweenRefreshesReadsNoFile() {
        let folder = URL(fileURLWithPath: "/out")
        let first = finished(in: folder)
        let second = finished(in: folder)
        let store = RowAvailability()
        var reads: [UUID] = []
        let resolve: (TranscriptionEntry) -> FilesOnDisk = { entry in
            reads.append(entry.id)
            return FilesOnDisk(protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile)
        }

        _ = store.filesOnDisk(for: first, resolve: resolve)
        _ = store.filesOnDisk(for: first, resolve: resolve)
        _ = store.filesOnDisk(for: second, resolve: resolve)
        _ = store.filesOnDisk(for: second, resolve: resolve)
        XCTAssertEqual(reads, [first.id, second.id])

        store.refresh()
        _ = store.filesOnDisk(for: first, resolve: resolve)
        XCTAssertEqual(reads, [first.id, second.id, first.id])
    }

    /// A transcript the regenerator cannot send (blank, or not UTF-8) gives
    /// no source, unless the protocol holds the full transcript; a readable
    /// one is the source itself. The file still counts as there to open.
    func testTheTranscriptSourceIsTheRegeneratorsOwnRule() throws {
        struct Case {
            let name: String
            let transcript: Data
            let protocolText: String?
            let source: RecordingRowActions.TranscriptSource
        }
        let blank = Data(" \n".utf8)
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        let fullProtocol = "# Retro" + ProtocolGenerator.fullTranscriptSeparator + "[Anna] Hello"
        let cases = [
            Case(name: "blank, no protocol", transcript: blank, protocolText: nil, source: .none),
            Case(name: "invalid UTF-8, protocol without transcript", transcript: invalidUTF8, protocolText: "# Retro", source: .none),
            Case(name: "blank, protocol with transcript", transcript: blank, protocolText: fullProtocol, source: .protocolOnly),
            Case(name: "invalid UTF-8, protocol with transcript", transcript: invalidUTF8, protocolText: fullProtocol, source: .protocolOnly),
            Case(name: "readable", transcript: Data("[Anna] Hello".utf8), protocolText: nil, source: .transcriptFile),
        ]
        for testCase in cases {
            let folder = try makeTempDirectory(prefix: "row_availability_test")
            let entry = finished(in: folder)
            try testCase.transcript.write(to: XCTUnwrap(entry.transcriptURL))
            if let protocolText = testCase.protocolText {
                try Data(protocolText.utf8).write(to: XCTUnwrap(entry.protocolURL))
            }

            let onDisk = read(entry, scopeRoot: folder)

            XCTAssertEqual(onDisk.transcriptSource, testCase.source, testCase.name)
            XCTAssertTrue(onDisk.transcriptExists, testCase.name)
            XCTAssertEqual(onDisk.protocolExists, testCase.protocolText != nil, testCase.name)
        }
    }
}
