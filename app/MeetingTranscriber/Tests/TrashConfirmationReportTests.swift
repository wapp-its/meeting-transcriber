@testable import MeetingTranscriber
import XCTest

/// What the Move Meeting to Trash confirmation says about additional reports
/// (spec A10): counted after the notes, named with the other files, and counted
/// over all meetings of a selection.
@MainActor
final class TrashConfirmationReportTests: XCTestCase {
    private typealias Fixture = RetentionFixture

    private let audio = RecordingAudioLine.AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 12_000_000)
    private let reports = ["/rec/b (Short).md", "/rec/b (Minutes).md"]

    private func moveMeeting(_ record: MeetingFileRecord, reports: [String]) -> TrashConfirmationText {
        TrashConfirmationText.moveMeeting(
            meetingTitle: "Budget review", record: record, audio: audio, hasNotionPage: false, hasFailedExport: false, reports: reports,
        )
    }

    func testOneMeetingCountsAndNamesItsReports() {
        let text = moveMeeting(Fixture.record(), reports: reports)

        XCTAssertEqual(text.lines, [
            "Its audio (12 MB), transcript, meeting notes and 2 additional reports go to the Trash, and the meeting leaves this list.",
            "Voice profiles learned from it stay.",
            "b_mix.wav\nb_app.wav\nb_mic.wav\nb.txt\nb.md\nb (Short).md\nb (Minutes).md",
        ])
    }

    func testOnlyAReportLeftIsStillMoved() {
        let gone = Fixture.record { $0.files = $0.files.map { MeetingFile(role: $0.role, path: $0.path, identity: nil, owned: $0.owned, state: .gone) } }

        XCTAssertEqual(moveMeeting(gone, reports: [reports[0]]).lines, [
            "Its 1 additional report goes to the Trash, and the meeting leaves this list.",
            "Voice profiles learned from it stay.",
            "b (Short).md",
        ])
    }

    /// A report the record already lists (an earlier run's) is named once.
    func testAReportTheRecordListsIsNamedOnce() {
        let listed = Fixture.record { record in
            record.files.append(MeetingFile(role: .previousProtocol, path: self.reports[0], identity: nil, owned: true, state: .present))
        }

        XCTAssertEqual(moveMeeting(listed, reports: [reports[0]]).lines.last, "b_mix.wav\nb_app.wav\nb_mic.wav\nb.txt\nb.md\nb (Short).md")
    }

    func testASelectionCountsTheReportsOfAllItsMeetings() {
        let rows = ["Retro", "Standup"].map { title in
            var job = PipelineJob(meetingTitle: title, appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
            job.state = .done
            return TrashSelectionPlan.Selected(
                entry: TranscriptionEntry(job: job, finishOrder: nil),
                meeting: .init(record: Fixture.record(), notionExportRunning: false, audio: audio),
            )
        }
        var plan = TrashSelectionPlan(action: .moveMeeting, selected: rows)
        plan.reports = [rows[0].entry.id: [reports[0]], rows[1].entry.id: reports]

        XCTAssertEqual(
            TrashConfirmationText.forSelection(plan).lines.first,
            "Their audio (24 MB), transcripts, meeting notes and 3 additional reports go to the Trash, and the meetings leave this list.",
        )
        XCTAssertEqual(plan.named[rows[1].entry.id]?.isSuperset(of: reports), true, "the confirmation answers for them")
    }
}
