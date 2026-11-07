@testable import MeetingTranscriber
import XCTest

/// A row's additional reports (spec R2, D3, A11): where its menu lists them, and
/// how the window reads them from disk. Pure, except the disk read, which runs
/// on a temp folder.
@MainActor
final class RecordingRowReportsTests: XCTestCase {
    private typealias FilesOnDisk = RecordingRowActions.FilesOnDisk
    private typealias Report = RecordingRowActions.Report

    private static let short = Report(name: "Short", url: URL(fileURLWithPath: "/out/standup (Short).md"))
    private static let minutes = Report(name: "Minutes", url: URL(fileURLWithPath: "/out/standup (Minutes).md"))

    private func onDisk(reports: [Report]) -> FilesOnDisk {
        FilesOnDisk(protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile, reports: reports)
    }

    // MARK: - The menu

    func testTheReportsSitBetweenTheFilesAndRegenerateUnderTheirHeading() {
        let items = RecordingRowActions.menuItems(
            state: .done, onDisk: onDisk(reports: [Self.minutes, Self.short]), canRetry: false, hasNotionPage: true,
        )

        XCTAssertEqual(items, [
            .openProtocol, .openTranscript, .showInFinder, .openInNotion,
            .separator, .reportsHeading, .report(Self.minutes, position: 0), .report(Self.short, position: 1), .separator,
            .regenerate(enabled: true),
        ])
    }

    func testARowWithoutReportsHasNeitherHeadingNorSeparator() {
        let items = RecordingRowActions.menuItems(state: .done, onDisk: onDisk(reports: []), canRetry: false)

        XCTAssertEqual(items, [.openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true)])
    }

    func testNoSeparatorOpensAMenuThatStartsWithTheReports() {
        let none = FilesOnDisk(protocolExists: false, transcriptExists: false, transcriptSource: .none, reports: [Self.short])

        XCTAssertEqual(
            RecordingRowActions.menuItems(state: .done, onDisk: none, canRetry: false),
            [.reportsHeading, .report(Self.short, position: 0), .separator, .regenerate(enabled: false)],
        )
    }

    func testAFailedRowListsItsReportsBeforeRetryAndRemove() {
        let items = RecordingRowActions.menuItems(state: .error, onDisk: onDisk(reports: [Self.short]), canRetry: true)

        XCTAssertEqual(items, [
            .openProtocol, .openTranscript, .showInFinder,
            .separator, .reportsHeading, .report(Self.short, position: 0), .separator,
            .regenerate(enabled: true), .retry, .remove,
        ])
    }

    /// A11: gh-97's items follow Regenerate Notes… with no separator before them.
    func testTheMeetingsFileItemsFollowRegenerateWithoutASeparator() {
        let meeting = RecordingRowActions.Meeting(
            record: RetentionFixture.record(), notionExportRunning: false,
            audio: RecordingAudioLine.AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 3000),
        )

        let items = RecordingRowActions.menuItems(state: .done, onDisk: onDisk(reports: [Self.short]), canRetry: false, meeting: meeting)

        let regenerate = items.firstIndex(of: .item(.regenerate(enabled: true))) ?? -1
        XCTAssertEqual(items.dropFirst(regenerate + 1).first, .keep(checked: false, enabled: true))
        XCTAssertEqual(items.filter { $0 == .item(.separator) }.count, 2)
    }

    func testARunningOrNamingRowListsNoReports() {
        for state: JobState in [.waiting, .transcribing, .diarizing, .generatingProtocol, .speakerNamingPending] {
            let items = RecordingRowActions.menuItems(state: state, onDisk: onDisk(reports: [Self.short]), canRetry: false)
            XCTAssertFalse(items.contains(.reportsHeading), "\(state)")
        }
    }

    func testTheReportsTitlesAndIdentifiers() {
        XCTAssertEqual(TranscriptionsView.title(of: RecordingRowActions.MenuItem.reportsHeading), "Additional Reports")
        XCTAssertEqual(TranscriptionsView.title(of: RecordingRowActions.MenuItem.report(Self.short, position: 1)), "Short")
        XCTAssertEqual(
            TranscriptionsView.identifier(of: RecordingRowActions.MenuItem.report(Self.short, position: 1), index: 4), "recordingMenuReport.4.1",
        )
    }

    // MARK: - Reading the disk

    func testTheWindowReadsTheReportsBesideTheRowsFiles() throws {
        let folder = try makeTempDirectory(prefix: "row_reports")
        let basename = "20261013_0900_standup_ab12cd34"
        for name in ["\(basename).txt", "\(basename).md", "\(basename) (Short).md", "\(basename) (Minutes).md", "other (Short).md"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        var job = PipelineJob(meetingTitle: "Standup", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.protocolPath = folder.appendingPathComponent("\(basename).md")
        job.transcriptPath = folder.appendingPathComponent("\(basename).txt")
        let entry = TranscriptionEntry(job: job, finishOrder: nil)

        let first = AllRecordingsActions.readFilesOnDisk(of: entry, scopeRoot: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(basename) (Short).md"))
        let second = AllRecordingsActions.readFilesOnDisk(of: entry, scopeRoot: folder)

        XCTAssertEqual(first.reports.map(\.name), ["Minutes", "Short"])
        XCTAssertEqual(first.reports.first?.url.lastPathComponent, "\(basename) (Minutes).md")
        XCTAssertEqual(second.reports.map(\.name), ["Minutes"], "a report removed in Finder is gone the next time the row is read")
        XCTAssertTrue(first.protocolExists)
    }
}
