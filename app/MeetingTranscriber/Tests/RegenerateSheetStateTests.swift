@testable import MeetingTranscriber
import XCTest

/// Opening the All Recordings window's regenerate sheet: the meeting it opens
/// with, when it offers "Choose File…", and that a row whose files are gone
/// leaves it closed. The regenerator reads its files from a dictionary.
@MainActor
final class RegenerateSheetStateTests: XCTestCase {
    private static let basename = "20261013_0900_board_ab12cd34"
    private static let txt = URL(fileURLWithPath: "/out/protocols/\(basename).txt")
    private static let md = URL(fileURLWithPath: "/out/protocols/\(basename).md")
    private static let start = Date(timeIntervalSinceReferenceDate: 780_000_000)
    private static let transcript = Data("[Anna] We ship on Friday.".utf8)
    private static let oldProtocol = Data("# Old protocol".utf8)

    /// A job titled "Board" whose files are `md` and `txt`, as the queue holds
    /// it. An import has no meeting start.
    private func job(state: JobState = .done, imported: Bool = false, protocolFile: Bool = true) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Board", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/board_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
            meetingStartTime: imported ? nil : Self.start,
        )
        job.state = state
        job.protocolPath = protocolFile ? Self.md : nil
        job.transcriptPath = Self.txt
        return job
    }

    private var bothFiles: [String: Data] {
        [Self.txt.path: Self.transcript, Self.md.path: Self.oldProtocol]
    }

    /// A finished row opens the sheet with its meeting, from its own files,
    /// and without "Choose File…".
    func testARowOpensTheSheetWithItsMeetingAndNoChooseFile() throws {
        let finished = job()
        let entry = try XCTUnwrap(TranscriptionEntry(record: TerminalJobRecord(job: finished), finishOrder: 0))
        let sut = RegenerateSheetState()

        XCTAssertTrue(sut.present(entry: entry, using: ProtocolRegenerator.reading(bothFiles)))

        XCTAssertTrue(sut.isPresented)
        XCTAssertFalse(sut.allowsChooseFile)
        let target = try XCTUnwrap(sut.initialTarget)
        XCTAssertEqual(target.protocolURL.path, Self.md.path)
        XCTAssertEqual(target.basename, Self.basename)
        XCTAssertEqual(target.title, "Board")
        XCTAssertEqual(target.meetingStartTime, Self.start)
        XCTAssertEqual(target.jobID, finished.id.uuidString)
        XCTAssertEqual(target.files, ProtocolRegenerationFiles(transcriptFile: Self.transcript, protocolFile: Self.oldProtocol))
    }

    /// A failed job stays listed after the history dropped its record. Its
    /// title, start and job still come from the row, never from the file
    /// name, which would read "board_ab12cd34" with no date or job.
    func testAFailedJobWithoutAHistoryRecordKeepsTheRowsTitleStartAndJob() throws {
        let failed = job(state: .error, protocolFile: false)
        let sut = RegenerateSheetState()

        sut.present(
            entry: TranscriptionEntry(job: failed, finishOrder: nil),
            using: ProtocolRegenerator.reading([Self.txt.path: Self.transcript]),
        )

        let target = try XCTUnwrap(sut.initialTarget)
        XCTAssertEqual(target.title, "Board")
        XCTAssertEqual(target.meetingStartTime, Self.start)
        XCTAssertEqual(target.jobID, failed.id.uuidString)
        XCTAssertEqual(target.protocolURL.path, Self.md.path, "the new protocol goes beside the transcript")
        XCTAssertFalse(target.hasProtocol)
    }

    /// An import has no meeting start; the row's date, when it was added, is
    /// not offered in its place, so the sheet says the date is unknown.
    func testAnImportRowHasNoMeetingStart() throws {
        let sut = RegenerateSheetState()

        sut.present(entry: TranscriptionEntry(job: job(imported: true), finishOrder: nil), using: ProtocolRegenerator.reading(bothFiles))

        let target = try XCTUnwrap(sut.initialTarget)
        XCTAssertNil(target.meetingStartTime)
    }

    /// A row whose files went away after its menu was built: no sheet, and
    /// false, so the window says the file was moved or deleted.
    func testARowWhoseFilesAreGoneLeavesTheSheetClosed() {
        let sut = RegenerateSheetState()

        XCTAssertFalse(sut.present(entry: TranscriptionEntry(job: job(), finishOrder: nil), using: ProtocolRegenerator.reading([:])))

        XCTAssertFalse(sut.isPresented)
        XCTAssertNil(sut.initialTarget)
    }

    /// "Regenerate from File…" opens the sheet without a meeting and with
    /// "Choose File…", also after a row's sheet was open.
    func testOpeningWithoutARowOffersChooseFileAndNoMeeting() {
        let regenerator = ProtocolRegenerator.reading(bothFiles)
        let sut = RegenerateSheetState()
        sut.present(entry: TranscriptionEntry(job: job(), finishOrder: nil), using: regenerator)
        sut.isPresented = false

        XCTAssertTrue(sut.present(entry: nil, using: regenerator))

        XCTAssertTrue(sut.isPresented)
        XCTAssertNil(sut.initialTarget)
        XCTAssertTrue(sut.allowsChooseFile)
    }

    /// Every opening forgets the last run's result, so a success or failure
    /// never shows for the next meeting.
    func testEveryOpeningForgetsTheLastRunsResult() async throws {
        let regenerator = ProtocolRegenerator.reading(bothFiles)
        let row = TranscriptionEntry(job: job(), finishOrder: nil)
        let target = try regenerator.target(for: row)
        let options = MeetingProtocolOptions(template: .builtIn, rawBackground: "")
        let sut = RegenerateSheetState()

        await regenerator.regenerate(target, options: options)
        XCTAssertEqual(regenerator.phase, .failed(ProtocolRegenerationError.providerOff.localizedDescription))
        sut.present(entry: row, using: regenerator)
        XCTAssertEqual(regenerator.phase, .idle, "opened for a row")

        await regenerator.regenerate(target, options: options)
        sut.present(entry: nil, using: regenerator)
        XCTAssertEqual(regenerator.phase, .idle, "opened without a meeting")
    }
}

extension ProtocolRegenerator {
    /// A regenerator reading its files from `files`, by path, and knowing no
    /// finished job, as after the history dropped a failed job's record.
    /// Protocol generation is off, so a run ends at once in `.failed`. Also
    /// used by `TranscriptionsViewTests`.
    static func reading(_ files: [String: Data]) -> ProtocolRegenerator {
        var operations = ProtocolRegenerationFileOperations.live
        operations.read = { files[$0.path] }
        operations.fileExists = { files[$0.path] != nil }
        return ProtocolRegenerator(environment: .init(
            generatorFactory: { nil },
            templateStore: ProtocolTemplateStore(directory: URL(fileURLWithPath: "/nonexistent/templates")),
            includeFullTranscript: { false },
            recordOnly: { false },
            queuedJobs: { [] },
            records: { [] },
            outputDir: { URL(fileURLWithPath: "/out") },
            notifier: RecordingNotifier(),
            fileOperations: operations,
        ))
    }
}
