@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The rows' Trash actions over the real controller and record, on real files in a
/// temporary folder with a fake Trash, wired as the App wires them.
extension TranscriptionsViewTests {
    private func makeHarness() throws -> MeetingDeletionHarness {
        let suite = "TranscriptionsView-\(getpid())-\(UUID().uuidString)"
        let root = try makeTempDirectory(prefix: "transcriptions-view")
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: root.appendingPathComponent("output"),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try MeetingDeletionHarness(root: root, settings: settings)
    }

    /// The window over the real controller and record, wired as the App wires it, as
    /// it stands now.
    private func window(over controller: PipelineController, scopeRoot: URL) -> TranscriptionsView {
        var actions = AllRecordingsActions.noop
        actions.filesOnDisk = { AllRecordingsActions.readFilesOnDisk(of: $0, scopeRoot: scopeRoot) }
        actions.meetingFiles = { controller.meetingFileStore.record(for: $0) }
        actions.audioOnDisk = { entry in
            controller.meetingFileStore.record(for: entry.id).map { AllRecordingsActions.readAudioOnDisk(of: $0, scopeRoot: scopeRoot) }
        }
        actions.moveAudioToTrash = { controller.moveAudioToTrash(jobID: $0) }
        actions.moveMeetingToTrash = { controller.moveMeetingToTrash(jobID: $0) }
        actions.retryDeletion = { controller.retryDeletion(jobID: $0) }
        actions.setKeep = { controller.setKeep(jobID: $0, $1) }
        return makeView(controller.transcriptionEntries, actions: actions)
    }

    private func confirm(_ item: String, in view: TranscriptionsView) throws {
        try button(item, in: view).tap()
        try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: view)
    }

    private func audioLine(in view: TranscriptionsView) throws -> String? {
        try texts(in: view).first { $0.hasPrefix("Audio") }
    }

    /// Move Audio: the row shows where the audio went, and has nothing more to move.
    func testConfirmedMoveAudioThenTheRowSaysWhereTheAudioWent() throws {
        let harness = try makeHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        _ = try harness.recordedMeeting()

        try confirm(A11yID.recordingMenuMoveAudioToTrash(0), in: window(over: controller, scopeRoot: harness.outputDir))

        let after = window(over: controller, scopeRoot: harness.outputDir)
        let line = try XCTUnwrap(audioLine(in: after))
        XCTAssertTrue(line.hasPrefix("Audio moved to the Trash on "), line)
        XCTAssertThrowsError(try button(A11yID.recordingMenuMoveAudioToTrash(0), in: after))
        XCTAssertEqual(harness.fakeTrash.moved.count, 3)
    }

    /// Move Meeting: the row is gone, with no record needed to say so.
    func testConfirmedMoveMeetingThenTheRowIsGone() throws {
        let harness = try makeHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        _ = try harness.recordedMeeting()

        try confirm(A11yID.recordingMenuMoveMeetingToTrash(0), in: window(over: controller, scopeRoot: harness.outputDir))

        XCTAssertEqual(controller.transcriptionEntries, [])
        XCTAssertNoThrow(try window(over: controller, scopeRoot: harness.outputDir).inspect().find(text: "No transcriptions yet"))
    }

    /// A track moved away when the dialog opened, so the dialog leaves it out, and back
    /// before the click. The click moves nothing and says so, as the dialog never named
    /// that file; asked again, the dialog names it and the click moves it.
    func testAFileThatCameBackAfterTheDialogOpenedIsNotMovedUnnamed() throws {
        let cases: [(item: (Int) -> String, moved: Int)] = [
            (A11yID.recordingMenuMoveAudioToTrash, 3),
            (A11yID.recordingMenuMoveMeetingToTrash, 5),
        ]
        for testCase in cases {
            let harness = try makeHarness()
            let controller = harness.controller(queue: harness.makeQueue())
            let job = try harness.recordedMeeting()
            let track = try XCTUnwrap(job.micPath)
            let aside = harness.root.appendingPathComponent("aside.wav")
            try FileManager.default.moveItem(at: track, to: aside)
            let sut = window(over: controller, scopeRoot: harness.outputDir)

            try button(testCase.item(0), in: sut).tap()
            XCTAssertFalse(try trashAlert(in: sut).message().text().string().contains(track.lastPathComponent), "test premise")
            try FileManager.default.moveItem(at: aside, to: track)
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

            XCTAssertEqual(harness.fakeTrash.moved, [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: track.path))
            XCTAssertThrowsError(try trashAlert(in: sut))
            XCTAssertNoThrow(try sut.inspect().find(text: Self.nothingMoved))
            XCTAssertNil(controller.meetingFileStore.record(for: job.id)?.pending)

            try button(testCase.item(0), in: sut).tap()
            XCTAssertTrue(try trashAlert(in: sut).message().text().string().contains(track.lastPathComponent))
            XCTAssertThrowsError(try sut.inspect().find(text: Self.nothingMoved), "asking again takes the message away")
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

            XCTAssertTrue(harness.fakeTrash.moved.contains(track.lastPathComponent))
            XCTAssertEqual(harness.fakeTrash.moved.count, testCase.moved)
        }
    }

    /// A file the Trash refuses: for each Trash item the row says so, counts what went
    /// and offers Retry Deletion, which finishes the job once the Trash takes the file.
    func testARefusedFileLeavesDeletionIncompleteAndRetryFinishes() throws {
        let cases: [(item: (Int) -> String, finishes: (MeetingDeletionHarness, PipelineController, TranscriptionsView) throws -> Void)] = [
            (A11yID.recordingMenuMoveAudioToTrash, { _, _, view in
                let line = try XCTUnwrap(self.audioLine(in: view))
                XCTAssertTrue(line.hasPrefix("Audio moved to the Trash on "), line)
                XCTAssertThrowsError(try self.button(A11yID.recordingRetryDeletionButton(0), in: view))
            }),
            (A11yID.recordingMenuMoveMeetingToTrash, { _, controller, _ in
                XCTAssertEqual(controller.transcriptionEntries, [])
            }),
        ]
        for testCase in cases {
            let harness = try makeHarness()
            let controller = harness.controller(queue: harness.makeQueue())
            let job = try harness.recordedMeeting()
            let refused = try XCTUnwrap(job.appPath).lastPathComponent
            harness.fakeTrash.refusal = { $0.lastPathComponent == refused ? CocoaError(.featureUnsupported) : nil }

            try confirm(testCase.item(0), in: window(over: controller, scopeRoot: harness.outputDir))

            let stopped = window(over: controller, scopeRoot: harness.outputDir)
            XCTAssertEqual(try audioLine(in: stopped), "Audio · 2 of 3 files moved to the Trash")
            XCTAssertNoThrow(try stopped.inspect().find(text: "Deletion incomplete: this volume has no Trash"))
            XCTAssertEqual(try button(A11yID.recordingRetryDeletionButton(0), in: stopped).labelView().text().string(), "Retry Deletion")
            XCTAssertThrowsError(try button(A11yID.recordingMainButton(0), in: stopped))

            harness.fakeTrash.refusal = { _ in nil }
            try button(A11yID.recordingRetryDeletionButton(0), in: stopped).tap()

            try testCase.finishes(harness, controller, window(over: controller, scopeRoot: harness.outputDir))
        }
    }
}
