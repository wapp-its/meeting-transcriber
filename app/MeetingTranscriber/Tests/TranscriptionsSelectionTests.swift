@testable import MeetingTranscriber
import XCTest

/// What a Trash action does to a selection of rows (R7) and what the window's footer
/// says (R3). Pure: the rows' records and what the disk answered come in.
@MainActor
final class TranscriptionsSelectionTests: XCTestCase {
    private typealias AudioOnDisk = RecordingAudioLine.AudioOnDisk
    private typealias Fixture = RetentionFixture
    private typealias Meeting = RecordingRowActions.Meeting
    private typealias Selected = TrashSelectionPlan.Selected

    private let threeTracks = AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 100_000_000)

    private func entry(_ title: String, state: JobState = .done) -> TranscriptionEntry {
        var job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/\(title)_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = state
        return TranscriptionEntry(job: job, finishOrder: nil)
    }

    private func recorded(
        _ title: String, state: JobState = .done, exporting: Bool = false, audio: AudioOnDisk? = nil,
        origin: MeetingFileRecord.Origin = .recorded, outcome: MeetingFileRecord.Outcome = .finished(protocolExpected: true),
        _ change: (inout MeetingFileRecord) -> Void = { _ in },
    ) -> Selected {
        Selected(
            entry: entry(title, state: state),
            meeting: Meeting(record: Fixture.record(origin: origin, outcome: outcome, change), notionExportRunning: exporting, audio: audio ?? threeTracks),
        )
    }

    private func stopped(_ kind: MeetingFileRecord.DeletionKind) -> (inout MeetingFileRecord) -> Void {
        { $0.incomplete = .init(reason: "reason", paths: [], kind: kind) }
    }

    // MARK: - Which meetings it applies to

    /// R4's rules per meeting: what the single row offers and enables, for each kind of
    /// row a selection can hold.
    func testEachMeetingFollowsTheRulesOfItsRow() {
        let noAudio = AudioOnDisk(presentCount: 0, unreachableCount: 0, totalCount: 3, bytes: 0)
        let unplugged = AudioOnDisk(presentCount: 0, unreachableCount: 3, totalCount: 3, bytes: 0)
        let rows: [(selected: Selected, audio: Bool, meeting: Bool)] = [
            (recorded("finished"), true, true),
            (recorded("kept") { $0.keep = true }, true, true),
            (recorded("drive not connected", audio: unplugged), true, true),
            (recorded("no audio left", audio: noAudio), false, true),
            (recorded("audio deletion stopped", stopped(.audioToTrash)), true, true),
            (recorded("meeting deletion stopped", stopped(.meetingToTrash)), false, true),
            (recorded("import", origin: .imported), false, true),
            (Selected(entry: entry("no record"), meeting: nil), false, false),
            (recorded("failed", state: .error, outcome: .failed), false, false),
            (recorded("failed in the history", outcome: .failed), false, false),
            (recorded("left the queue", outcome: .leftUnfinished), false, false),
            (recorded("waiting", state: .waiting, outcome: .inProgress), false, false),
            (recorded("transcribing", state: .transcribing, outcome: .inProgress), false, false),
            (recorded("diarizing", state: .diarizing, outcome: .inProgress), false, false),
            (recorded("making notes", state: .generatingProtocol, outcome: .inProgress), false, false),
            (recorded("naming", state: .speakerNamingPending), false, false),
            (recorded("another build's run", outcome: .inProgress), false, false),
            (recorded("exporting", exporting: true), false, false),
            (recorded("a deletion pending") { $0.pending = .init(kind: .audioToTrash, paths: []) }, false, false),
        ]
        for row in rows {
            let title = row.selected.entry.title
            XCTAssertEqual(TrashSelectionPlan(action: .moveAudio, selected: [row.selected]).isEnabled, row.audio, "Move Audio, \(title)")
            XCTAssertEqual(TrashSelectionPlan(action: .moveMeeting, selected: [row.selected]).isEnabled, row.meeting, "Move Meeting, \(title)")
        }

        let all = rows.map(\.selected)
        let cases: [(TrashConfirmationPrompt.Action, [String])] = [
            (.moveAudio, rows.filter(\.audio).map(\.selected.entry.title)),
            (.moveMeeting, rows.filter(\.meeting).map(\.selected.entry.title)),
        ]
        for (action, expected) in cases {
            let plan = TrashSelectionPlan(action: action, selected: all)
            XCTAssertEqual(plan.meetings.map(\.entry.title), expected, "\(action)")
            XCTAssertEqual(plan.leftOut, all.count - expected.count, "\(action)")
        }
    }

    /// With none it applies to, or nothing selected, the item stays in the menu, off.
    func testTheActionIsDisabledWhenItAppliesToNone() {
        let none = [
            recorded("failed", state: .error, outcome: .failed),
            Selected(entry: entry("no record"), meeting: nil),
        ]
        for action in [TrashConfirmationPrompt.Action.moveAudio, .moveMeeting] {
            let plan = TrashSelectionPlan(action: action, selected: none)
            XCTAssertFalse(plan.isEnabled)
            XCTAssertEqual(plan.meetings.count, 0)
            XCTAssertEqual(plan.leftOut, 2)
            XCTAssertFalse(TrashSelectionPlan(action: action, selected: []).isEnabled)
        }
    }

    /// A regeneration writes its meeting's notes when it ends, and the regenerator does
    /// not say which meeting that is, so what removes whole meetings waits for all.
    func testARegenerationLeavesOutEveryMoveMeetingAndNoMoveAudio() {
        let selected = [recorded("one"), recorded("two")]
        let meeting = TrashSelectionPlan(action: .moveMeeting, selected: selected, isRegenerating: true)
        XCTAssertFalse(meeting.isEnabled)
        XCTAssertEqual(meeting.leftOut, 2)
        let audio = TrashSelectionPlan(action: .moveAudio, selected: selected, isRegenerating: true)
        XCTAssertEqual(audio.meetings.count, 2)
        XCTAssertEqual(audio.leftOut, 0)
    }

    // MARK: - What the plan says about them

    /// Only meetings the action applies to count. An import's copy goes as one of its
    /// remaining files and never as its audio, as in the single dialog.
    func testTheSizeCoversTheAudioOfTheMeetingsItAppliesTo() {
        let selected = [
            recorded("one"),
            recorded("two", audio: AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 50_000_000)),
            recorded("failed", state: .error, outcome: .failed),
            recorded("import with a copy", origin: .imported),
        ]
        XCTAssertEqual(TrashSelectionPlan(action: .moveAudio, selected: selected).audioBytes, 150_000_000)
        XCTAssertEqual(TrashSelectionPlan(action: .moveMeeting, selected: selected).audioBytes, 150_000_000)
        XCTAssertEqual(TrashSelectionPlan(action: .moveMeeting, selected: selected).audioSize, "150 MB")
    }

    /// In the order of the selection, and only of meetings the action reaches.
    func testItNamesTheKeptMeetingsItAppliesTo() {
        let selected = [
            recorded("kept first") { $0.keep = true },
            recorded("plain"),
            recorded("kept second") { $0.keep = true },
            recorded("kept and exporting", exporting: true) { $0.keep = true },
        ]
        for action in [TrashConfirmationPrompt.Action.moveAudio, .moveMeeting] {
            XCTAssertEqual(TrashSelectionPlan(action: action, selected: selected).keptTitles, ["kept first", "kept second"], "\(action)")
        }
    }

    /// An import counts where the action reaches it: Move Audio leaves every one out.
    func testItSaysWhetherImportsAreAmongTheMeetingsItAppliesTo() {
        let withImport = [recorded("plain"), recorded("import", origin: .imported)]
        XCTAssertTrue(TrashSelectionPlan(action: .moveMeeting, selected: withImport).hasImports)
        XCTAssertFalse(TrashSelectionPlan(action: .moveAudio, selected: withImport).hasImports)
        XCTAssertFalse(TrashSelectionPlan(action: .moveMeeting, selected: [recorded("plain")]).hasImports)
        let failedImport = recorded("failed import", state: .error, origin: .imported, outcome: .failed)
        XCTAssertFalse(TrashSelectionPlan(action: .moveMeeting, selected: [recorded("plain"), failedImport]).hasImports)
    }

    /// What the confirmation answers for: per meeting, what the action covers, less what
    /// the disk answered gone. Only the meetings it applies to are in it.
    func testItKeepsThePathsTheConfirmationAnswersFor() throws {
        let gone = Fixture.file(.appTrack, "b_app.wav").path
        let partly = recorded("partly", audio: AudioOnDisk(presentCount: 2, unreachableCount: 0, totalCount: 3, bytes: 1, gonePaths: [gone]))
        let failed = recorded("failed", state: .error, outcome: .failed)
        let tracks = ["b_mix.wav", "b_mic.wav"].map { Fixture.file(.mix, $0).path }

        let audio = TrashSelectionPlan(action: .moveAudio, selected: [partly, failed]).named
        XCTAssertEqual(audio, [partly.entry.id: Set(tracks)])

        let meeting = TrashSelectionPlan(action: .moveMeeting, selected: [partly, failed]).named
        XCTAssertEqual(try XCTUnwrap(meeting[partly.entry.id]), Set(tracks + ["b.txt", "b.md"].map { Fixture.file(.mix, $0).path }))
        XCTAssertNil(meeting[failed.entry.id])
    }

    // MARK: - The selected rows

    /// A row the search hides or that has left the list is not acted on and not counted,
    /// and the rows keep the list's order.
    func testOnlyRowsShownCountAsSelected() {
        let rows = [entry("one"), entry("two"), entry("three")]
        let selection = TranscriptionsSelection()
        selection.ids = [rows[2].id, rows[0].id, UUID()]

        XCTAssertEqual(selection.entries(in: rows).map(\.title), ["one", "three"])
        XCTAssertEqual(selection.entries(in: [rows[1], rows[2]]).map(\.title), ["three"])
        XCTAssertEqual(selection.entries(in: []).map(\.title), [])
    }

    // MARK: - Footer

    func testTheFooterSaysTheCountTheSizeAndWhatTheSettingDoes() {
        let rows: [(counts: (shown: Int, selected: Int), bytes: Int64, retention: RecordingRetention, text: String)] = [
            ((8, 0), 700_000_000, .never, "8 recordings · audio 700 MB"),
            ((1, 0), 700_000_000, .never, "1 recording · audio 700 MB"),
            (
                (8, 0),
                700_000_000,
                .afterProtocol,
                "8 recordings · audio 700 MB · recordings are deleted automatically right after the notes (Settings → Output)",
            ),
            ((8, 0), 700_000_000, .days7, "8 recordings · audio 700 MB · recordings are deleted automatically after 7 days (Settings → Output)"),
            ((8, 0), 700_000_000, .days30, "8 recordings · audio 700 MB · recordings are deleted automatically after 30 days (Settings → Output)"),
            ((8, 0), 700_000_000, .days90, "8 recordings · audio 700 MB · recordings are deleted automatically after 90 days (Settings → Output)"),
            ((8, 3), 700_000_000, .never, "3 of 8 selected · audio 700 MB"),
            ((8, 3), 700_000_000, .days30, "3 of 8 selected · audio 700 MB · recordings are deleted automatically after 30 days (Settings → Output)"),
            ((8, 1), 700_000_000, .never, "1 of 8 selected · audio 700 MB"),
            ((2, 0), 0, .never, "2 recordings · no audio"),
            ((0, 0), 0, .days7, "0 recordings · no audio · recordings are deleted automatically after 7 days (Settings → Output)"),
        ]
        for row in rows {
            XCTAssertEqual(
                TranscriptionsFooter.text(shown: row.counts.shown, selected: row.counts.selected, audioBytes: row.bytes, retention: row.retention),
                row.text,
            )
        }
    }
}
