@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// A row's "Transcribe Again…": both menus list it and "Identify Speakers Again…" as
/// `RecordingRowActions` decides, from what the window hands that decision; it opens
/// the sheet for its own row; and the row's source audio is read once per refresh, where
/// the record lists it. Which rows get it is `RecordingRowActionsTests`, what the sheet
/// does `TranscribeAgainSheetTests`.
extension TranscriptionsViewTests {
    func rerunRow(_ title: String) -> TranscriptionEntry {
        entry(title, protocolPath: "/out/\(title).md", transcriptPath: "/out/\(title).txt")
    }

    /// A window whose rows each have a finished meeting with its source audio there.
    func rerunActions(_ rows: [TranscriptionEntry]) -> AllRecordingsActions {
        let meetings = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, meeting($0)) })
        var actions = AllRecordingsActions.noop
        actions.filesOnDisk = { Self.recordedFilesOnDisk($0) }
        actions.meetingFiles = { meetings[$0]?.record }
        actions.audioOnDisk = { meetings[$0.id]?.audio }
        actions.sourceAudio = { _ in .present }
        return actions
    }

    func testTranscribeAgainOpensTheSheetForItsRowAndQueuesItsMeeting() throws {
        let rows = [rerunRow("Retro"), rerunRow("Standup")]
        let state = TranscribeAgainSheetState()
        var queued: [UUID] = []
        var actions = rerunActions(rows)
        actions.transcribeAgain = { id in
            queued.append(id)
            return .queued
        }
        let sut = makeView(rows, actions: actions, transcribeAgain: state)
        XCTAssertThrowsError(try sut.inspect().find(TranscribeAgainSheet.self), "no sheet before a click")

        try button(A11yID.recordingMenuTranscribeAgain(1), in: sut).tap()
        XCTAssertEqual(state.meeting?.id, rows[1].id)
        let sheet = try sut.inspect().find(ViewType.Sheet.self).find(TranscribeAgainSheet.self)
        XCTAssertNoThrow(try sheet.find(text: RerunSheetText.meetingLine(XCTUnwrap(state.meeting))))
        try sheet.find(viewWithAccessibilityIdentifier: A11yID.transcribeAgainConfirmButton).button().tap()

        XCTAssertEqual(queued, [rows[1].id])
        XCTAssertThrowsError(try sut.inspect().find(TranscribeAgainSheet.self), "closed once queued")
    }

    /// The "…" menu and the right-click menu list the same items, the row decision's,
    /// Identify Speakers Again right after Transcribe Again.
    func testBothMenusListTheReRunItemsAsTheRowDecides() throws {
        let row = rerunRow("Retro")
        let sut = makeView([row], actions: rerunActions([row]))
        var rerunnable = meeting(row)
        rerunnable.sourceAudio = .present
        let expected = RecordingRowActions.menuItems(state: .done, onDisk: Self.recordedFilesOnDisk(row), canRetry: false, meeting: rerunnable)
            .map { TranscriptionsView.identifier(of: $0, index: 0) }
            .filter { !$0.isEmpty }
        let moreButton = A11yID.recordingMoreButton(0)

        let more = try sut.inspect().find(viewWithAccessibilityIdentifier: moreButton)
            .findAll { try $0.accessibilityIdentifier() != moreButton }
            .map { try $0.accessibilityIdentifier() }
        let rightClick = try VStack { sut.selectionMenu(for: [row.id]) }.inspect()
            .findAll { (try? $0.accessibilityIdentifier()) != nil }
            .map { try $0.accessibilityIdentifier() }

        let again = try XCTUnwrap(expected.firstIndex(of: A11yID.recordingMenuTranscribeAgain(0)), "\(expected)")
        XCTAssertEqual(expected.firstIndex(of: A11yID.recordingMenuIdentifySpeakersAgain(0)), again + 1, "\(expected)")
        XCTAssertEqual(more, expected)
        XCTAssertEqual(rightClick, expected)
    }

    /// The window hands the decision record-only mode and a running regeneration; a
    /// finished meeting held for Retry Meeting Notes is offered both re-run items.
    func testTheItemFollowsRecordOnlyModeAndARunningRegeneration() throws {
        var job = PipelineJob(
            meetingTitle: "Retro", appName: "Teams", mixPath: URL(fileURLWithPath: "/rec/Retro_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        job.transcriptPath = URL(fileURLWithPath: "/out/Retro.txt")
        job.notesFailure = .timedOut
        let held = TranscriptionEntry(job: job, finishOrder: nil)
        XCTAssertTrue(held.hasRetryableMeetingNotes, "test premise")
        let cases: [(String, recordOnly: Bool, ProtocolRegenerator.Phase, disabled: Bool)] = [
            ("held for Retry Meeting Notes", false, .idle, false),
            ("record-only mode", true, .idle, true),
            ("a regeneration running", false, .running, true),
        ]
        for (name, recordOnly, phase, disabled) in cases {
            var actions = rerunActions([held])
            actions.optionsUse = { ProtocolOptionsUse(destination: .off, recordOnly: recordOnly) }
            let sut = makeView([held], actions: actions, regenerationPhase: phase)
            XCTAssertEqual(try button(A11yID.recordingMenuTranscribeAgain(0), in: sut).isDisabled(), disabled, name)
            XCTAssertEqual(try button(A11yID.recordingMenuIdentifySpeakersAgain(0), in: sut).isDisabled(), disabled, name)
        }
    }

    /// From the rows' cache: a redraw reads nothing again, a row action reads anew.
    func testTheSourceAudioIsReadOncePerRefresh() throws {
        let row = rerunRow("Retro")
        var reads = 0
        var actions = rerunActions([row])
        actions.sourceAudio = { _ in
            reads += 1
            return .present
        }
        let sut = makeView([row], actions: actions)
        let draw = { _ = try sut.inspect().find(text: "Retro") }

        try draw()
        try draw()
        XCTAssertEqual(reads, 1)

        try button(A11yID.recordingMainButton(0), in: sut).tap()
        try draw()
        XCTAssertEqual(reads, 2)
    }

    /// Where the record lists the tracks, an import's own file among them, which the
    /// app does not own; a record that lists none, or lists them as gone, has none.
    func testTheSourceAudioIsReadWhereTheRecordListsIt() throws {
        let folder = try makeTempDirectory(prefix: "source-audio")
        let own = folder.appendingPathComponent("talk.m4a")
        try Data("audio".utf8).write(to: own)
        let importOf = { (path: String) in
            MeetingFileRecord(
                jobID: UUID(), origin: .imported, recordingDate: nil,
                files: [MeetingFile(role: .mix, path: path, identity: nil, owned: false, state: .present)], createdBy: RetentionFixture.thisBuild,
            )
        }
        let read = { (record: MeetingFileRecord) in AllRecordingsActions.readSourceAudio(of: record, scopeRoot: folder) }

        XCTAssertEqual(read(importOf(own.path)), .present)
        XCTAssertEqual(read(importOf(folder.appendingPathComponent("unplugged/talk.m4a").path)), .onlyUnreachable)
        try FileManager.default.removeItem(at: own)
        XCTAssertEqual(read(importOf(own.path)), .gone)
        XCTAssertEqual(read(RetentionFixture.record { $0.files.removeAll { $0.role.isAudio } }), .gone, "notes made from a transcript")
        XCTAssertEqual(read(RetentionFixture.record { $0.setAudio(to: .gone) }), .gone, "tracks listed as gone")
    }
}
