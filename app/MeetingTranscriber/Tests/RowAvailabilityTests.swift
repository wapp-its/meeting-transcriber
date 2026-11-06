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

    // MARK: - Audio

    /// A finished recording whose three tracks are listed in `folder`.
    private func recording(in folder: URL, sizes: [Int] = [1000, 200, 30]) throws -> (TranscriptionEntry, MeetingFileRecord) {
        let tracks: [(role: MeetingFile.Role, name: String)] = [(.mix, "mix.wav"), (.appTrack, "app.wav"), (.micTrack, "mic.wav")]
        let files = try zip(tracks, sizes).map { track, size in
            let url = folder.appendingPathComponent(track.name)
            try Data(count: size).write(to: url)
            return MeetingFile(role: track.role, url: url, owned: true)
        }
        let entry = finished(in: folder)
        var record = MeetingFileRecord(jobID: entry.id, origin: .recorded, recordingDate: nil, files: files)
        record.outcome = .finished(protocolExpected: false)
        return (entry, record)
    }

    private func listed(_ path: String, role: MeetingFile.Role, owned: Bool = true, state: MeetingFile.State = .present) -> MeetingFile {
        MeetingFile(role: role, path: path, identity: nil, owned: owned, state: state)
    }

    /// Presence and size are read once per row, whichever way they changed since,
    /// and read again after a refresh.
    func testAudioIsCachedAndReadAgainOnRefresh() throws {
        let folder = try makeTempDirectory(prefix: "row_availability_test")
        let (entry, record) = try recording(in: folder)
        let availability = RowAvailability()
        var reads = 0
        let look = {
            availability.audioOnDisk(for: entry, record: record) { _ in
                reads += 1
                return AllRecordingsActions.readAudioOnDisk(of: record, scopeRoot: folder)
            }
        }
        XCTAssertEqual(look()?.bytes, 1230)
        XCTAssertEqual(look()?.presentCount, 3)
        XCTAssertEqual(reads, 1)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("mix.wav"))
        XCTAssertEqual(look()?.bytes, 1230, "read again before a refresh")
        XCTAssertEqual(reads, 1)

        availability.refresh()
        XCTAssertEqual(look()?.bytes, 230)
        XCTAssertEqual(look()?.presentCount, 2)
        XCTAssertEqual(reads, 2)
    }

    /// Only an answer from a folder that can be read is gone. A drive that is not
    /// connected is neither there nor gone: it adds no bytes, the row says so, and
    /// its Keep and Trash items stay.
    func testAnUnreachableFolderIsReportedAsUnreachableNotGone() throws {
        let folder = try makeTempDirectory(prefix: "row_availability_test")
        let (entry, record) = try recording(in: folder)
        let unplugged = folder.deletingLastPathComponent().appendingPathComponent("unplugged-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: folder, to: unplugged)
        addTeardownBlock { try? FileManager.default.removeItem(at: unplugged) }

        let audio = AllRecordingsActions.readAudioOnDisk(of: record, scopeRoot: folder)

        XCTAssertEqual(audio, .init(presentCount: 0, unreachableCount: 3, totalCount: 3, bytes: 0))
        XCTAssertEqual(line(record, audio).text, "Audio · on a drive that is not connected")
        XCTAssertEqual(
            items(entry, record, audio),
            [.keep(checked: false, enabled: true), .moveAudioToTrash(enabled: true), .moveMeetingToTrash(enabled: true)],
        )
    }

    private func line(_ record: MeetingFileRecord, _ audio: RecordingAudioLine.AudioOnDisk) -> RecordingAudioLine {
        RecordingAudioLine.resolve(
            record: record, live: nil, audio: audio, retention: .never, now: Date(), calendar: .current, locale: .current,
        )
    }

    /// What the row adds to its menu with this record and audio.
    private func items(
        _ entry: TranscriptionEntry, _ record: MeetingFileRecord, _ audio: RecordingAudioLine.AudioOnDisk,
    ) -> [RecordingRowActions.RowMenuItem] {
        let onDisk = FilesOnDisk(protocolExists: false, transcriptExists: false, transcriptSource: .none)
        return RecordingRowActions.menuItems(
            state: entry.state, onDisk: onDisk, canRetry: false,
            meeting: RecordingRowActions.Meeting(record: record, notionExportRunning: false, audio: audio),
        ).filter { if case .item = $0 { false } else { true } }
    }

    /// One count of each kind over a record listing all of them: what is on disk,
    /// what the disk answered gone without the record knowing, what the record knows
    /// is gone, a file listed twice and a file that is the user's.
    func testTheCountsFollowTheRecordAndTheDisk() throws {
        let folder = try makeTempDirectory(prefix: "row_availability_test")
        let path = { (name: String) in folder.appendingPathComponent(name).path }
        for (name, size) in [("mix.wav", 1000), ("mic_16k.wav", 20), ("yours.wav", 500), ("notes.md", 7)] {
            try Data(count: size).write(to: URL(fileURLWithPath: path(name)))
        }
        let files = [
            listed(path("mix.wav"), role: .mix),
            listed(path("mix.wav"), role: .mix16k), // Each path once.
            listed(path("app.wav"), role: .appTrack, state: .gone), // Known gone, and it counts.
            listed(path("mic.wav"), role: .micTrack), // Removed by hand: the record still lists it.
            listed(path("mic_16k.wav"), role: .mic16k),
            listed(path("app_16k.wav"), role: .app16k, state: .gone), // The pipeline removed its copy.
            listed(path("yours.wav"), role: .mix16k, owned: false),
            listed(path("yours.wav"), role: .mix, owned: true),
            listed(path("off.wav"), role: .mix16k, owned: false),
            listed(path("transcript.txt"), role: .transcript), // Removed by hand.
            listed(path("notes.md"), role: .protocol),
            listed(path("old.md"), role: .previousProtocol, state: .gone),
        ]
        let record = MeetingFileRecord(jobID: UUID(), origin: .recorded, recordingDate: nil, files: files)

        XCTAssertEqual(AllRecordingsActions.readAudioOnDisk(of: record, scopeRoot: folder), .init(
            presentCount: 2, unreachableCount: 0, totalCount: 4, bytes: 1020,
            gonePaths: [path("mic.wav"), path("transcript.txt")],
        ))
    }

    /// The window stays open while the store deletes a meeting's audio: the row's
    /// size and menu follow at its next draw, with no refresh, and a draw that finds
    /// the same record reads nothing.
    func testARecordThatChangedIsReadAgainWithoutARefresh() throws {
        let folder = try makeTempDirectory(prefix: "row_availability_test")
        let (entry, created) = try recording(in: folder)
        let store = MeetingFileStore(path: folder.appendingPathComponent("records/meeting_files.json"))
        XCTAssertTrue(store.create(created), "test premise")
        let availability = RowAvailability()
        var reads = 0
        let look = { () -> RecordingAudioLine.AudioOnDisk? in
            availability.audioOnDisk(for: entry, record: store.record(for: entry.id)) { _ in
                reads += 1
                return store.record(for: entry.id).map { AllRecordingsActions.readAudioOnDisk(of: $0, scopeRoot: folder) }
            }
        }
        let before = try XCTUnwrap(look())
        XCTAssertEqual(before.bytes, 1230)
        XCTAssertEqual(try items(entry, XCTUnwrap(store.record(for: entry.id)), before).count, 3)

        for file in created.files {
            try FileManager.default.removeItem(atPath: file.path)
        }
        store.update(jobID: entry.id) { record in
            for index in record.files.indices {
                record.files[index].state = .gone
            }
            record.audioDeletion = .init(kind: .automatic, at: Date())
        }

        let after = try XCTUnwrap(look())
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(after.bytes, 0)
        XCTAssertFalse(after.isAnyLeft)
        XCTAssertEqual(try items(entry, XCTUnwrap(store.record(for: entry.id)), after), [.moveMeetingToTrash(enabled: true)])
        _ = look()
        XCTAssertEqual(reads, 2, "the same record is not read again")

        store.remove(jobID: entry.id)
        XCTAssertNil(look(), "a row whose record is gone has no audio")
    }
}
