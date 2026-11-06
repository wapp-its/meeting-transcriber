@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// A finished job whose Notion export failed keeps a line under "Needs you"
/// with "Retry Notion Export" and "Discard Notion Retry"; while the export
/// runs, the line sits under "In progress" and nothing can take the job off.
/// Ported from the original's flat menu to the job submenus.
@MainActor
final class MenuBarNotionRetryTests: XCTestCase {
    private actor RetryNotionExporter: NotionExporting {
        private(set) var receivedPageIDs: [String?] = []

        func exportMeeting( // swiftlint:disable:this function_parameter_count
            title _: String, date _: Date?, tags _: [String], markdown _: String,
            transcript _: String?, existingPageID: String?,
            onPageCreated _: @Sendable (NotionPageResult) async -> Void,
        ) -> NotionPageResult {
            receivedPageIDs.append(existingPageID)
            return NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
        }
    }

    private func makeView(
        pipelineQueue: PipelineQueue,
        notionExportEnabled: Bool = true,
        onDismissJob: @escaping (UUID) -> Void = { _ in },
    ) -> MenuBarView {
        var actions = MenuActions.noop
        actions.dismissJob = onDismissJob
        return MenuBarView(
            status: nil,
            isWatching: false,
            pipelineQueue: pipelineQueue,
            updateChecker: nil,
            noMic: false,
            manualRecordingPendingOrActive: false,
            notionExportEnabled: notionExportEnabled,
            actions: actions,
        )
    }

    /// A finished job whose export failed, with or without a local backup
    /// recorded to retry from.
    private func failedExportJob(backup: URL?) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Sprint", appName: "Zoom", mixPath: nil,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        job.protocolPath = backup
        job.beginNotionExport(speakerNames: [])
        job.finishNotionExport(succeeded: false)
        return job
    }

    private func retryButton(_ view: MenuBarView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.jobNotionRetryButton(0)).button()
    }

    func testFailedNotionJobRetryButtonRunsSavedExport() async throws {
        let dir = try makeTempDirectory(prefix: "menu_notion_retry_test")
        let markdown = dir.appendingPathComponent("protocol.md")
        try "# Meeting Protocol - Sprint".write(to: markdown, atomically: true, encoding: .utf8)
        let exporter = RetryNotionExporter()
        let configuration = NotionExportConfiguration(exporter: exporter, databaseID: "database-1")
        let configurationProvider: () -> NotionExportResolution = { .ready(configuration) }
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir, logDir: dir, stagingDir: dir.appendingPathComponent("staging"),
            notionExportConfigurationProvider: configurationProvider,
        )
        var job = failedExportJob(backup: markdown)
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )
        queue.insertJobForTesting(job)

        let button = try retryButton(makeView(pipelineQueue: queue))
        XCTAssertFalse(button.isDisabled())
        try button.tap()

        for _ in 0 ..< 50 where queue.jobs.first?.notionExportStatus != .completed {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(queue.jobs.first?.notionExportStatus, .completed)
        let receivedPageIDs = await exporter.receivedPageIDs
        XCTAssertEqual(receivedPageIDs, ["page-1"])
    }

    /// The row is enabled from the job's recorded state alone. The backup path
    /// here does not exist, so a view that asked the file system would disable
    /// the row, and a view body must not do that: the output folder can be a
    /// network volume. The retry re-checks the file itself when it runs.
    func testFailedNotionJobRetryRowIsEnabledWithoutAskingTheFileSystem() throws {
        let queue = try makeIsolatedQueue()
        queue.insertJobForTesting(failedExportJob(backup: URL(fileURLWithPath: "/nonexistent-volume/protocols/sprint.md")))

        XCTAssertFalse(try retryButton(makeView(pipelineQueue: queue)).isDisabled())
    }

    func testFailedNotionJobWithoutBackupRetryRowIsDisabled() throws {
        let queue = try makeIsolatedQueue()
        queue.insertJobForTesting(failedExportJob(backup: nil))

        XCTAssertTrue(try retryButton(makeView(pipelineQueue: queue)).isDisabled())
    }

    /// With the export switched off the retry has nowhere to go, and the row
    /// says where to switch it on.
    func testRetryRowIsDisabledWhileNotionExportIsOff() throws {
        let queue = try makeIsolatedQueue()
        queue.insertJobForTesting(failedExportJob(backup: URL(fileURLWithPath: "/out/sprint.md")))

        let button = try retryButton(makeView(pipelineQueue: queue, notionExportEnabled: false))
        XCTAssertTrue(button.isDisabled())
        XCTAssertEqual(try button.help().string(), "Enable Notion export in Settings → Output to retry.")
    }

    /// The failed job's line is under "Needs you" and says what failed;
    /// "Discard Notion Retry" takes this job off.
    func testDiscardNotionRetryDismissesTheJob() throws {
        let queue = try makeIsolatedQueue()
        let job = failedExportJob(backup: URL(fileURLWithPath: "/out/sprint.md"))
        queue.insertJobForTesting(job)
        var dismissed: UUID?

        // swiftlint:disable:next trailing_closure
        let body = try makeView(pipelineQueue: queue, onDismissJob: { dismissed = $0 }).inspect()

        XCTAssertNoThrow(try body.find(text: "Needs you"))
        XCTAssertNoThrow(try body.find(text: "Sprint — Notion export failed"))
        try body.find(button: "Discard Notion Retry").tap()
        XCTAssertEqual(dismissed, job.id)
    }

    func testDismissIsDisabledWhileNotionExportIsInProgress() throws {
        let queue = try makeIsolatedQueue()
        var job = PipelineJob(
            meetingTitle: "Exporting", appName: "Zoom", mixPath: nil,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        job.beginNotionExport(speakerNames: [])
        queue.insertJobForTesting(job)

        let body = try makeView(pipelineQueue: queue).inspect()
        XCTAssertNoThrow(try body.find(text: "In progress"))
        XCTAssertNoThrow(try body.find(text: "Exporting — Exporting to Notion…"))
        XCTAssertTrue(try body.find(button: "Dismiss").isDisabled())
        XCTAssertTrue(try retryButton(makeView(pipelineQueue: queue)).isDisabled())
    }
}
