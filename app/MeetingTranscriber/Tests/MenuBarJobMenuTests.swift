@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The menu bar menu shows one line per job, with the job's actions in a
/// submenu, and names what each record item actually records.
@MainActor
final class MenuBarJobMenuTests: XCTestCase {
    private func makeView(pipelineQueue: PipelineQueue = PipelineQueue(), noMic: Bool = false) -> MenuBarView {
        MenuBarView(
            status: nil,
            isWatching: false,
            pipelineQueue: pipelineQueue,
            updateChecker: nil,
            onStartStop: {},
            onRecordApp: {},
            onRecordMicrophone: {},
            noMic: noMic,
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocol: { _ in },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onNameSpeakers: nil,
            onProcessFiles: {},
            onDismissJob: { _ in },
            onQuit: {},
        )
    }

    private func makeJob(_ title: String) -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/\(title)_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
    }

    // MARK: - Record items

    func testRecordAppLabelSaysTheMicrophoneIsRecordedToo() {
        XCTAssertEqual(MenuBarView.recordAppLabel(noMic: false), "Record App + Microphone...")
        XCTAssertEqual(MenuBarView.recordAppLabel(noMic: true), "Record App Audio...")
    }

    func testRecordAppItemFollowsTheNoMicrophoneSetting() throws {
        let body = try makeView(noMic: true).inspect()
        XCTAssertNoThrow(try body.find(text: "Record App Audio..."))
        XCTAssertThrowsError(try body.find(text: "Record App + Microphone..."))
    }

    // MARK: - Job lines

    /// Four failed jobs took four lines each, plus empty ones, when a job row
    /// was an `HStack`: the menu turns every part of a row into its own item.
    func testEachJobIsOneSubmenuWithoutRowLayoutParts() throws {
        let queue = PipelineQueue()
        for title in ["One", "Two", "Three", "Four"] {
            let job = makeJob(title)
            queue.enqueue(job)
            queue.updateJobState(id: job.id, to: .error, error: "Transcription failed")
        }

        let body = try makeView(pipelineQueue: queue).inspect()

        XCTAssertEqual(body.findAll(ViewType.Menu.self).count, 4)
        XCTAssertTrue(body.findAll(ViewType.Spacer.self).isEmpty, "a Spacer becomes an empty menu line")
        XCTAssertNoThrow(try body.find(text: "Three — Failed"))
    }

    func testAJobsActionsAndFullErrorSitInItsSubmenu() throws {
        let queue = PipelineQueue()
        let job = makeJob("Broken")
        queue.enqueue(job)
        queue.updateJobState(id: job.id, to: .error, error: "Transcription failed")

        let menu = try makeView(pipelineQueue: queue).inspect().find(ViewType.Menu.self)

        XCTAssertNoThrow(try menu.find(text: "Transcription failed"))
        XCTAssertNoThrow(try menu.find(button: "Dismiss"))
    }

    // MARK: - Summary

    func testStatusIsShortForEveryState() {
        var job = makeJob("Standup")
        let expected: [(JobState, String)] = [
            (.waiting, "Waiting..."),
            (.transcribing, "Transcribing... 1:05"),
            (.diarizing, "Transcribing... 1:05"),
            (.generatingProtocol, "Transcribing... 1:05"),
            (.speakerNamingPending, "Speaker names needed"),
            (.done, "Done"),
            (.error, "Failed"),
        ]
        for (state, status) in expected {
            job.state = state
            XCTAssertEqual(JobMenuSummary.status(of: job, progress: "Transcribing... 1:05"), status, "\(state)")
        }
        job.state = .done
        job.warnings = ["Diarization failed"]
        XCTAssertEqual(JobMenuSummary.status(of: job, progress: ""), "Done, with warnings")
    }

    func testEveryStateHasItsOwnSymbol() {
        var job = makeJob("Standup")
        var symbols: Set<String> = []
        for state in [JobState.waiting, .transcribing, .diarizing, .generatingProtocol, .speakerNamingPending, .done, .error] {
            job.state = state
            symbols.insert(JobMenuSummary.symbol(of: job))
        }
        XCTAssertEqual(symbols.count, 7)
    }
}
