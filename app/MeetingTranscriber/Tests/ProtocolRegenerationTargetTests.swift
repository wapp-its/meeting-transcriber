@testable import MeetingTranscriber
import XCTest

/// Which transcript and which finished-job record a chosen protocol or
/// transcript file resolves to. Real files in a temp directory, read through
/// the injected reader the window uses.
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

    // MARK: - Latest

    func testLatestSkipsRecordsWhoseFilesAreGone() throws {
        try write("[Anna] Hello", to: txt)
        let present = record(title: "Kept", transcriptPath: storedPath(txt), protocolPath: storedPath(md), start: nil)
        let gone = record(
            title: "Deleted",
            transcriptPath: folder.appendingPathComponent("gone.txt").path,
            protocolPath: folder.appendingPathComponent("gone.md").path,
            start: nil,
        )
        let older = record(title: "Older", transcriptPath: storedPath(txt), protocolPath: nil, start: nil)

        let latest = ProtocolRegenerationTarget.latest(
            records: [older, present, gone],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            read: read,
        )

        XCTAssertEqual(latest?.title, "Kept")
        XCTAssertEqual(latest?.jobID, present.status.jobID)
        XCTAssertNil(ProtocolRegenerationTarget.latest(records: [gone], fileExists: { _ in false }, read: read))
    }
}
