@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// A row's additional reports in its "…" menu and its right-click menu (spec R2):
/// listed under their heading, each opening its own file through the window's
/// Open. Where they sit among the items is `RecordingRowReportsTests`.
extension TranscriptionsViewTests {
    private static let reports = [
        RecordingRowActions.Report(name: "Minutes", url: URL(fileURLWithPath: "/out/s (Minutes).md")),
        RecordingRowActions.Report(name: "Short", url: URL(fileURLWithPath: "/out/s (Short).md")),
    ]

    private func withReports(_ base: AllRecordingsActions = .noop) -> AllRecordingsActions {
        var actions = base
        actions.filesOnDisk = { _ in
            FilesOnDisk(protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile, reports: Self.reports)
        }
        return actions
    }

    func testBothMenusListTheReportsUnderTheirHeading() throws {
        let row = entry("Standup", protocolPath: "/out/s.md", transcriptPath: "/out/s.txt")
        let sut = makeView([row], actions: withReports())
        let expected = [
            A11yID.recordingMenuOpenProtocol(0), A11yID.recordingMenuOpenTranscript(0), A11yID.recordingMenuShowInFinder(0),
            A11yID.recordingMenuReportsHeading(0), A11yID.recordingMenuReport(0, 0), A11yID.recordingMenuReport(0, 1),
            A11yID.recordingMenuRegenerate(0),
        ]
        let more = A11yID.recordingMoreButton(0)
        let moreItems = try sut.inspect().find(viewWithAccessibilityIdentifier: more)
            .findAll { (try? $0.accessibilityIdentifier()).map { $0 != more } ?? false }
            .map { try $0.accessibilityIdentifier() }
        let rightClick = try VStack { sut.selectionMenu(for: [row.id]) }.inspect()
            .findAll { (try? $0.accessibilityIdentifier()) != nil }
            .map { try $0.accessibilityIdentifier() }

        XCTAssertEqual(moreItems, expected)
        XCTAssertEqual(rightClick, expected)
        let heading = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingMenuReportsHeading(0))
        XCTAssertEqual(try heading.text().string(), "Additional Reports")
        XCTAssertEqual(try button(A11yID.recordingMenuReport(0, 1), in: sut).labelView().text().string(), "Short")
    }

    func testEachReportOpensItsOwnFileAndAGoneOneSaysSo() throws {
        let row = entry("Standup", protocolPath: "/out/s.md", transcriptPath: "/out/s.txt")
        var calls: [String] = []
        var base = recording { calls.append($0) }
        let open = base.openProtocol
        base.openProtocol = { url in open(url) && !url.path.hasSuffix("(Short).md") }
        let sut = makeView([row], actions: withReports(base))

        try button(A11yID.recordingMenuReport(0, 0), in: sut).tap()
        XCTAssertThrowsError(try sut.inspect().find(text: "The file was moved or deleted."))
        try button(A11yID.recordingMenuReport(0, 1), in: sut).tap()

        XCTAssertEqual(calls, ["openProtocol /out/s (Minutes).md", "openProtocol /out/s (Short).md"])
        XCTAssertNoThrow(try sut.inspect().find(text: "The file was moved or deleted."))
    }

    /// The row's main button and Show in Finder keep the main notes (R2, R3).
    func testTheMainButtonAndShowInFinderKeepTheMainNotes() throws {
        let row = entry("Standup", protocolPath: "/out/s.md", transcriptPath: "/out/s.txt")
        var calls: [String] = []
        let sut = makeView([row], actions: withReports(recording { calls.append($0) }))

        try button(A11yID.recordingMainButton(0), in: sut).tap()
        try button(A11yID.recordingMenuShowInFinder(0), in: sut).tap()
        try button(A11yID.recordingMenuOpenProtocol(0), in: sut).tap()

        XCTAssertEqual(calls, ["openProtocol /out/s.md", "reveal /out/s.md", "openProtocol /out/s.md"])
    }

    /// A regeneration that ended may have written a report: the rows are read again.
    func testARegenerationThatEndsReadsTheRowsAgain() throws {
        var reads = 0
        var actions = AllRecordingsActions.noop
        actions.filesOnDisk = { entry in
            reads += 1
            return Self.recordedFilesOnDisk(entry)
        }
        let sut = makeView([entry("Retro", protocolPath: "/out/retro.md")], actions: actions, regenerationPhase: .running)
        _ = try sut.inspect().find(text: "Retro")
        XCTAssertEqual(reads, 1)

        try sut.inspect().vStack().callOnChange(
            oldValue: ProtocolRegenerator.Phase.running,
            newValue: .succeeded(URL(fileURLWithPath: "/out/r.md"), warnings: []),
        )
        _ = try sut.inspect().find(text: "Retro")

        XCTAssertEqual(reads, 2)
    }

    // MARK: - Move Meeting to Trash

    /// The window over the real controller and record, wired as the App wires it.
    private func reportWindow(over controller: PipelineController, scopeRoot: URL) -> TranscriptionsView {
        var actions = AllRecordingsActions.noop
        actions.filesOnDisk = { AllRecordingsActions.readFilesOnDisk(of: $0, scopeRoot: scopeRoot) }
        actions.meetingFiles = { controller.meetingFileStore.record(for: $0) }
        actions.audioOnDisk = { entry in
            controller.meetingFileStore.record(for: entry.id).map { AllRecordingsActions.readAudioOnDisk(of: $0, scopeRoot: scopeRoot) }
        }
        actions.reloadMeetingFiles = { controller.meetingFileStore.reload() }
        actions.moveMeetingToTrash = { controller.moveMeetingToTrash(jobID: $0, named: $1) }
        actions.meetingReports = { controller.meetingReportPaths(of: $0) }
        return makeView(controller.transcriptionEntries, actions: actions)
    }

    /// The dialog counts and names the reports; one written after it opened stops the
    /// click, and asking again names it too.
    func testTheDialogNamesTheReportsAndOneWrittenSinceStopsTheClick() throws {
        let suite = "TranscriptionsViewReports-\(getpid())-\(UUID().uuidString)"
        let root = try makeTempDirectory(prefix: "transcriptions-view-reports")
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: root.appendingPathComponent("output"))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let harness = try MeetingDeletionHarness(root: root, settings: settings)
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        let stem = try XCTUnwrap(job.transcriptPath).deletingPathExtension().lastPathComponent
        try Data("# Short".utf8).write(to: harness.recordings.appendingPathComponent("\(stem) (Short).md"))
        let sut = reportWindow(over: controller, scopeRoot: harness.outputDir)

        try button(A11yID.recordingMenuMoveMeetingToTrash(0), in: sut).tap()
        let message = try trashAlert(in: sut).message().text().string()
        XCTAssertTrue(message.contains("meeting notes and 1 additional report go to the Trash"), message)
        XCTAssertTrue(message.contains("\(stem) (Short).md"), message)
        try Data("# Minutes".utf8).write(to: harness.recordings.appendingPathComponent("\(stem) (Minutes).md"))
        try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

        XCTAssertEqual(harness.fakeTrash.moved, [])
        XCTAssertNoThrow(try sut.inspect().find(text: Self.nothingMoved))

        try button(A11yID.recordingMenuMoveMeetingToTrash(0), in: sut).tap()
        XCTAssertTrue(try trashAlert(in: sut).message().text().string().contains("2 additional reports"))
        try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

        XCTAssertTrue(harness.fakeTrash.moved.contains("\(stem) (Minutes).md"))
        XCTAssertTrue(harness.fakeTrash.moved.contains("\(stem) (Short).md"))
        XCTAssertEqual(controller.transcriptionEntries, [])
    }
}
