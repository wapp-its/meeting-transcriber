@testable import MeetingTranscriber
import XCTest

/// `JobOpenTarget.resolve(forEntry:preferNotion:)` for jobs as the queue
/// holds them, which is how the menu and the All Recordings window see them.
final class JobOpenTargetTests: XCTestCase {
    private func resolve(_ job: PipelineJob, preferNotion: Bool) -> JobOpenTarget? {
        JobOpenTarget.resolve(forEntry: TranscriptionEntry(job: job, finishOrder: nil), preferNotion: preferNotion)
    }

    func testNotionWinsWhenEnabledAndAPageExists() throws {
        var job = makeJob()
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )
        job.finishNotionExport(succeeded: true)

        let target = resolve(job, preferNotion: true)

        XCTAssertEqual(target, try .notion(XCTUnwrap(URL(string: "https://www.notion.so/page-1"))))
        XCTAssertEqual(target?.jobActionLabel, "Open in Notion")
        XCTAssertEqual(target?.lastNotesLabel, "Open in Notion")
    }

    func testLocalFileWinsWhenNotionIsDisabled() {
        var job = makeJob()
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )

        let target = resolve(job, preferNotion: false)

        XCTAssertEqual(target, .file(URL(fileURLWithPath: "/tmp/protocol.md")))
        XCTAssertEqual(target?.jobActionLabel, "Open")
        XCTAssertEqual(target?.lastNotesLabel, "Open Notes")
    }

    func testNotionPageIsUsedWhenNoLocalFileExists() throws {
        var job = makeJob()
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )
        job.finishNotionExport(succeeded: true)

        let target = resolve(job, preferNotion: false)

        XCTAssertEqual(target, try .notion(XCTUnwrap(URL(string: "https://www.notion.so/page-1"))))
    }

    func testPartialNotionPageUsesLocalBackupRegardlessOfPreference() {
        var job = makeJob()
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        job.beginNotionExport(speakerNames: [])
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )

        XCTAssertEqual(
            resolve(job, preferNotion: true),
            .file(URL(fileURLWithPath: "/tmp/protocol.md")),
        )
        job.finishNotionExport(succeeded: false)
        XCTAssertEqual(
            resolve(job, preferNotion: false),
            .file(URL(fileURLWithPath: "/tmp/protocol.md")),
        )
    }

    func testPartialNotionPageWithoutLocalBackupHasNoOpenTarget() {
        var job = makeJob()
        job.beginNotionExport(speakerNames: [])
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )

        XCTAssertNil(resolve(job, preferNotion: true))
    }

    func testTranscriptIsTheFallbackWhenNoProtocolWasSaved() {
        var job = makeJob()
        job.transcriptPath = URL(fileURLWithPath: "/tmp/transcript.txt")

        let target = resolve(job, preferNotion: true)

        XCTAssertEqual(target, .file(URL(fileURLWithPath: "/tmp/transcript.txt")))
    }

    func testNoTargetWithoutAFileOrPage() {
        XCTAssertNil(resolve(makeJob(), preferNotion: true))
        XCTAssertNil(JobOpenTarget.resolve(forEntry: nil, preferNotion: true))
    }

    private func makeJob() -> PipelineJob {
        PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }
}
