@testable import MeetingTranscriber
import XCTest

/// Which transcript and which finished-job record a chosen protocol or
/// transcript file resolves to. Real files in a temp directory, read through
/// the injected reader the regenerate sheet uses.
final class ProtocolRegenerationTargetTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var folder: URL!

    private let basename = "20261013_0900_standup_ab12cd34"

    override func setUp() async throws {
        try await super.setUp()
        folder = try makeTempDirectory(prefix: "regeneration_target_test")
    }

    private var txt: URL {
        folder.appendingPathComponent("\(basename).txt")
    }

    private var md: URL {
        folder.appendingPathComponent("\(basename).md")
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    private func resolve(_ file: URL, records: [TerminalJobRecord] = []) throws -> ProtocolRegenerationTarget {
        try ProtocolRegenerationTarget.resolve(file: file, records: records, read: read)
    }

    /// The path a record stores, spelt through `/private` the way the pipeline
    /// writes it, while the test reaches the folder through the `/var` link.
    private func storedPath(_ url: URL) -> String {
        "/private" + url.path
    }

    private func record(
        title: String, transcriptPath: String?, protocolPath: String?, start: Date?,
    ) -> TerminalJobRecord {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0, meetingStartTime: start,
        )
        job.state = .done
        job.transcriptPath = transcriptPath.map(URL.init(fileURLWithPath:))
        job.protocolPath = protocolPath.map(URL.init(fileURLWithPath:))
        return TerminalJobRecord(job: job)
    }

    // MARK: - Transcript source

    func testTheTranscriptBesideTheFileIsPreferredWhicheverFileIsChosen() throws {
        try write("[Anna] Hello from the transcript", to: txt)
        try write("# Protocol" + ProtocolGenerator.fullTranscriptSeparator + "[Anna] Older copy", to: md)

        for chosen in [md, txt] {
            let target = try resolve(chosen)

            XCTAssertEqual(target.files.transcript?.text, "[Anna] Hello from the transcript", "chosen \(chosen.lastPathComponent)")
            XCTAssertEqual(target.files.transcript?.fromProtocol, false)
            XCTAssertEqual(target.protocolURL, md)
            XCTAssertTrue(target.hasProtocol)
        }
    }

    func testWithoutAUsableTranscriptFileTheProtocolsFullTranscriptIsUsedAndMarked() throws {
        try write("# Protocol" + ProtocolGenerator.fullTranscriptSeparator + "[Ben] Only copy", to: md)
        let withoutFile = try resolve(md)
        try write("  \n", to: txt)
        let withBlankFile = try resolve(txt)

        for target in [withoutFile, withBlankFile] {
            XCTAssertEqual(target.files.transcript?.text, "[Ben] Only copy")
            XCTAssertEqual(target.files.transcript?.fromProtocol, true)
        }
    }

    func testNoTranscriptAnywhereIsRefused() throws {
        try write("# Protocol without a transcript section", to: md)

        XCTAssertThrowsError(try resolve(md)) { error in
            XCTAssertEqual(error as? ProtocolRegenerationError, .noTranscript)
        }
    }

    // MARK: - Finished-job record

    func testARecordMatchedByEitherPathGivesTitleStartAndJobID() throws {
        try write("[Anna] Hello", to: txt)
        try write("# Protocol", to: md)
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let byTranscript = record(title: "Weekly Standup", transcriptPath: storedPath(txt), protocolPath: nil, start: start)
        let byProtocol = record(title: "Design Review", transcriptPath: nil, protocolPath: storedPath(md), start: nil)
        let unrelated = record(title: "Other", transcriptPath: "/elsewhere/x.txt", protocolPath: nil, start: nil)

        let viaTranscript = try resolve(md, records: [byTranscript, unrelated])
        let viaProtocol = try resolve(txt, records: [unrelated, byProtocol])

        XCTAssertEqual(viaTranscript.title, "Weekly Standup")
        XCTAssertEqual(viaTranscript.meetingStartTime, start)
        XCTAssertEqual(viaTranscript.jobID, byTranscript.status.jobID)
        XCTAssertEqual(viaProtocol.title, "Design Review")
        XCTAssertNil(viaProtocol.meetingStartTime)
        XCTAssertEqual(viaProtocol.jobID, byProtocol.status.jobID)
    }

    func testWithoutARecordTheTitleIsTheBasenameWithoutItsStampAndTheStartIsUnknown() throws {
        try write("[Anna] Hello", to: txt)

        let target = try resolve(txt, records: [record(title: "Other", transcriptPath: "/elsewhere/x.txt", protocolPath: nil, start: .now)])

        XCTAssertEqual(target.title, "standup_ab12cd34")
        XCTAssertNil(target.meetingStartTime)
        XCTAssertNil(target.jobID)
        XCTAssertFalse(target.hasProtocol)
    }

    // MARK: - A chosen additional report

    // swiftlint:disable:next discouraged_optional_collection
    private func list(_ url: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    func testAChosenReportTargetsTheMeetingItBelongsTo() throws {
        try write("[Anna] Hello", to: txt)
        try write("# Protocol", to: md)
        let report = folder.appendingPathComponent("\(basename) (Short).md")
        try write("# Short", to: report)
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let meeting = record(title: "Weekly Standup", transcriptPath: storedPath(txt), protocolPath: storedPath(md), start: start)

        let target = try ProtocolRegenerationTarget.resolve(file: report, records: [meeting], read: read, list: list)

        XCTAssertEqual(target.basename, basename)
        XCTAssertEqual(target.protocolURL, md, "Replace the current notes replaces the meeting's notes, never the report")
        XCTAssertEqual(target.title, "Weekly Standup")
        XCTAssertEqual(target.meetingStartTime, start)
        XCTAssertEqual(target.jobID, meeting.status.jobID)
        XCTAssertEqual(target.reports.map(\.name), ["Short"])
        XCTAssertEqual(target.reportSlot(for: .file(name: "Short")), .existing(fileName: report.lastPathComponent))
    }

    func testAChosenMeetingWithBracketsInItsNameStaysThatMeeting() throws {
        let other = folder.appendingPathComponent("\(basename) (Q3).txt")
        try write("[Anna] Hello", to: txt)
        try write("[Ben] The Q3 meeting", to: other)
        let chosen = folder.appendingPathComponent("\(basename) (Q3).md")
        try write("# Q3 notes", to: chosen)

        let target = try ProtocolRegenerationTarget.resolve(file: chosen, records: [], read: read, list: list)

        XCTAssertEqual(target.basename, "\(basename) (Q3)")
        XCTAssertEqual(target.files.transcript?.text, "[Ben] The Q3 meeting")
    }

    /// Its own transcript makes a file a meeting even when it cannot be read: the
    /// file never stands for the shorter meeting.
    func testAChosenMeetingWhoseTranscriptCannotBeReadStaysThatMeeting() throws {
        let other = folder.appendingPathComponent("\(basename) (Q3).txt")
        try write("[Anna] Hello", to: txt)
        try write("[Ben] The Q3 meeting", to: other)
        let chosen = folder.appendingPathComponent("\(basename) (Q3).md")
        try write("# Q3 notes" + ProtocolGenerator.fullTranscriptSeparator + "[Ben] The Q3 meeting", to: chosen)
        let unreadable: (URL) -> Data? = { url in url.lastPathComponent == other.lastPathComponent ? nil : try? Data(contentsOf: url) }

        let target = try ProtocolRegenerationTarget.resolve(file: chosen, records: [], read: unreadable, list: list)

        XCTAssertEqual(target.basename, "\(basename) (Q3)")
        XCTAssertEqual(target.protocolURL, chosen)
    }

    func testReadingAgainSeesTheNotesAndReportsWrittenSince() throws {
        try write("[Anna] Hello", to: txt)
        let target = try ProtocolRegenerationTarget.resolve(file: txt, records: [], read: read, list: list)
        try write("# Protocol", to: md)
        try write("# Short", to: folder.appendingPathComponent("\(basename) (Short).md"))

        let again = target.readAgain(read: read, list: list)

        XCTAssertFalse(target.hasProtocol)
        XCTAssertTrue(again.hasProtocol)
        XCTAssertEqual(again.reports.map(\.name), ["Short"])
        XCTAssertEqual(again.title, target.title)
    }

    func testAReportWhoseMeetingIsGoneIsRefused() throws {
        let report = folder.appendingPathComponent("\(basename) (Short).md")
        try write("# Short, no transcript section", to: report)

        XCTAssertThrowsError(try ProtocolRegenerationTarget.resolve(file: report, records: [], read: read, list: list)) { error in
            XCTAssertEqual(error as? ProtocolRegenerationError, .noTranscript)
        }
    }

    func testTheReportCountAndASlotTakenByAnotherMeeting() throws {
        try write("[Anna] Hello", to: txt)
        try write("# Protocol", to: md)
        try write("# Minutes", to: folder.appendingPathComponent("\(basename) (Minutes).md"))
        try write("[Ben] Another meeting", to: folder.appendingPathComponent("\(basename) (Board).txt"))

        let target = try ProtocolRegenerationTarget.resolve(file: md, records: [], read: read, list: list)

        XCTAssertEqual(target.reports.map(\.name), ["Minutes"])
        XCTAssertEqual(target.reportSlot(for: .file(name: "Board")), .otherMeeting(fileName: "\(basename) (Board).md"))
        XCTAssertEqual(target.reportSlot(for: .builtIn), .free(fileName: "\(basename) (Standard).md"))
    }
}
