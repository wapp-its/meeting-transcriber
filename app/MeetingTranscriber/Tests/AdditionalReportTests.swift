@testable import MeetingTranscriber
import XCTest

/// The rule that says whose report a Markdown file is, which the row, the sheet,
/// "Regenerate from File…", the deletion and the rename all apply. Pure, except
/// the folder read, which runs on a temp folder.
final class AdditionalReportTests: XCTestCase {
    private static let withTranscript = "# Notes" + ProtocolGenerator.fullTranscriptSeparator + "[Anna] Hello."

    /// A folder read for `basename`, from names alone: a meeting has a transcript
    /// when its `.txt` is listed, or when `transcriptInside` names it.
    private func folder(
        _ basename: String, _ names: Set<String>, transcriptInside: Set<String> = [],
    ) -> MeetingReportFolder {
        let prefix = "\(basename) ("
        let stems = names.compactMap { name -> String? in
            guard name.hasPrefix(prefix) else { return nil }
            if name.hasSuffix(".txt") { return String(name.dropLast(4)) }
            if name.hasSuffix(".md"), transcriptInside.contains(String(name.dropLast(3))) { return String(name.dropLast(3)) }
            return nil
        }
        return MeetingReportFolder(basename: basename, names: names, transcriptStems: Set(stems))
    }

    private func names(_ reports: [AdditionalReport.Listed]) -> [String] {
        reports.map(\.name)
    }

    // MARK: - Names

    func testTheBuiltInTemplatesReportIsCalledStandard() {
        XCTAssertEqual(AdditionalReport.name(of: .builtIn), "Standard")
        XCTAssertEqual(AdditionalReport.name(of: .file(name: "Short summary")), "Short summary")
        XCTAssertEqual(AdditionalReport.fileName(basename: "20261013_0900_standup_ab12cd34", name: "Standard"), "20261013_0900_standup_ab12cd34 (Standard).md")
    }

    // MARK: - Ownership

    func testAPlainReportBelongsToItsMeeting() {
        let sut = folder("Budget", ["Budget.txt", "Budget.md", "Budget (Short).md"])

        XCTAssertEqual(sut.reports, [AdditionalReport.Listed(name: "Short", fileName: "Budget (Short).md")])
    }

    func testAFileWithItsOwnTranscriptIsAMeetingNeverAReport() {
        let sut = folder("Budget", ["Budget.txt", "Budget (Q3).md", "Budget (Q3).txt"])

        XCTAssertEqual(sut.reports, [])
        XCTAssertNil(sut.owner(ofFileName: "Budget (Q3).md"))
    }

    func testABracketInTheMeetingsName() {
        let sut = folder("Budget (Q3)", ["Budget (Q3).txt", "Budget (Q3).md", "Budget (Q3) (Short).md"])

        XCTAssertEqual(names(sut.reports), ["Short"])
    }

    func testABracketInTheTemplatesName() {
        let sut = folder("Budget", ["Budget.txt", "Budget (Alpha (Beta)).md"])

        XCTAssertEqual(names(sut.reports), ["Alpha (Beta)"])
    }

    func testWithBothMeetingNamesPresentTheLongerOneWins() {
        let names: Set = ["Budget.txt", "Budget (Q3).txt", "Budget (Q3) (Short).md"]

        XCTAssertEqual(folder("Budget", names).reports, [], "the longer meeting name claims it")
        XCTAssertEqual(self.names(folder("Budget (Q3)", names).reports), ["Short"])
        XCTAssertEqual(
            AdditionalReport.owner(ofStem: "Budget (Q3) (Short)") { $0 == "Budget" }?.name, "Q3) (Short",
            "without the longer meeting the file is the shorter one's report",
        )
    }

    func testAMeetingWhoseTranscriptIsOnlyInsideItsNotesClaimsItsReports() {
        let names: Set = ["Budget.txt", "Budget (Q3).md", "Budget (Q3) (Short).md"]

        XCTAssertEqual(
            self.names(folder("Budget", names, transcriptInside: ["Budget (Q3)"]).reports), ["Q3"],
            "notes without a transcript file of their own read as a report, and claim the file named after them",
        )
        XCTAssertEqual(
            self.names(folder("Budget", names).reports), ["Q3", "Q3) (Short"],
            "a hand-named file with no transcript of its own reads as the meeting's report",
        )
    }

    func testWithNoMeetingPresentAFileIsNoReport() {
        XCTAssertNil(AdditionalReport.owner(ofStem: "Budget (Short)") { _ in false })
        XCTAssertNil(AdditionalReport.owner(ofStem: "Budget") { _ in true }, "no bracket, no report")
        XCTAssertNil(AdditionalReport.owner(ofStem: "Budget ()") { _ in true }, "an empty name is no report")
    }

    func testAMeetingWhoseTranscriptIsGoneKeepsItsReports() {
        let sut = folder("Budget", ["Budget (Short).md", "Budget (Minutes).md", "Other (Short).md"])

        XCTAssertEqual(names(sut.reports), ["Minutes", "Short"], "alphabetical, and only this meeting's")
    }

    // MARK: - Where a new report goes

    func testTheSlotIsFreeOrTheExistingReport() {
        let sut = folder("Budget", ["Budget.txt", "Budget.md", "Budget (Short).md"])

        XCTAssertEqual(sut.slot(forReportNamed: "Minutes"), .free(fileName: "Budget (Minutes).md"))
        XCTAssertEqual(sut.slot(forReportNamed: "Short"), .existing(fileName: "Budget (Short).md"))
    }

    func testAReportNameThatIsAnotherMeetingsProtocolIsTaken() {
        let sut = folder("Budget", ["Budget.txt", "Budget (Q3).md", "Budget (Q3).txt"])

        XCTAssertEqual(sut.slot(forReportNamed: "Q3"), .otherMeeting(fileName: "Budget (Q3).md"))
    }

    func testAReportNameALongerMeetingNameClaimsIsTaken() {
        let sut = folder("Budget", ["Budget.txt", "Budget (Q3).txt"])

        XCTAssertEqual(sut.slot(forReportNamed: "Q3) (Short"), .otherMeeting(fileName: "Budget (Q3) (Short).md"))
    }

    // MARK: - Names that differ only in case

    /// The default macOS volume reaches `Budget (q3).md` by the name `Budget (Q3).md`,
    /// so the template "Q3" would write over the other meeting's notes.
    func testAnotherMeetingWhoseNameDiffersOnlyInCaseHoldsTheName() {
        let sut = folder("Budget", ["Budget.txt", "Budget.md", "Budget (q3).txt", "Budget (q3).md"])

        XCTAssertEqual(sut.slot(forReportNamed: "Q3"), .otherMeeting(fileName: "Budget (Q3).md"))
        XCTAssertEqual(sut.reports, [])
    }

    /// Written under its own name, the report reaches the case variant on the
    /// default volume, so the sheet warns that it replaces it.
    func testTheTemplatesReportUnderAnotherCaseIsTheOneItReplaces() {
        let sut = folder("Budget", ["Budget.txt", "Budget.md", "Budget (short).md"])

        XCTAssertEqual(sut.slot(forReportNamed: "Short"), .existing(fileName: "Budget (Short).md"))
        XCTAssertEqual(sut.reports, [AdditionalReport.Listed(name: "short", fileName: "Budget (short).md")])
    }

    /// On a case-sensitive volume `Budget` and `budget` are two meetings: neither
    /// lists the other's report, so Move Meeting to Trash never takes it.
    func testAMeetingNeverListsTheReportOfAMeetingWhoseNameDiffersOnlyInCase() {
        let names: Set = ["Budget.txt", "budget.txt", "budget (Short).md"]

        XCTAssertEqual(folder("Budget", names).reports, [])
        XCTAssertEqual(folder("budget", names).reports, [AdditionalReport.Listed(name: "Short", fileName: "budget (Short).md")])
    }

    func testALongerMeetingWhoseNameDiffersOnlyInCaseClaimsTheFile() throws {
        let names = ["Budget.txt", "budget (q3).txt", "Budget (Q3) (Short).md"]

        let sut = try XCTUnwrap(MeetingReportFolder.read(
            folder: URL(fileURLWithPath: "/out"), basename: "Budget", list: { _ in names },
            read: { names.contains($0.lastPathComponent) ? Data("[Anna] Hi.".utf8) : nil },
        ))

        XCTAssertEqual(sut.reports, [])
        XCTAssertEqual(sut.slot(forReportNamed: "Q3) (Short"), .otherMeeting(fileName: "Budget (Q3) (Short).md"))
    }

    // MARK: - Reading a folder

    func testReadingAFolderFindsTranscriptsInsideNotes() throws {
        let dir = try makeTempDirectory(prefix: "additional_report")
        try Data("[Anna] Hi.".utf8).write(to: dir.appendingPathComponent("Budget.txt"))
        try Data(Self.withTranscript.utf8).write(to: dir.appendingPathComponent("Budget (Q3).md"))
        try Data("# Short".utf8).write(to: dir.appendingPathComponent("Budget (Q3) (Short).md"))
        try Data("# Long".utf8).write(to: dir.appendingPathComponent("Budget (Long).md"))

        let sut = try XCTUnwrap(MeetingReportFolder.read(
            folder: dir, basename: "Budget", list: { try? FileManager.default.contentsOfDirectory(atPath: $0.path) },
            read: { try? Data(contentsOf: $0) },
        ))

        XCTAssertEqual(sut.transcriptStems, ["Budget (Q3)"])
        XCTAssertEqual(names(sut.reports), ["Long", "Q3"], "the notes with a transcript inside claim the file named after them")
        XCTAssertNil(MeetingReportFolder.read(folder: dir, basename: "Budget", list: { _ in nil }, read: { _ in nil }))
    }
}
