@testable import MeetingTranscriber
import XCTest

/// Notes whose summary section names the run that wrote them.
private final class NumberedNotesGen: ProtocolGenerating {
    private(set) var runs = 0
    var fails = false

    func generate(
        transcript _: String, title _: String, diarized _: Bool, meetingStartTime _: Date?, instructions _: ProtocolInstructions,
    ) throws -> String {
        runs += 1
        if fails { throw ProtocolError.emptyProtocol }
        return "# Notes\n\n## Summary\nRun \(runs).\n\n## Topics\n- Release"
    }
}

/// The queue's notes save points (spec R2): a new meeting's notes and a retry's are
/// handed on as saved, a re-run's only at its success and from the file it made
/// current, and failed notes are not. Every note and summary here is made up.
@MainActor
final class PipelineQueueNotesSummaryTests: XCTestCase {
    private typealias Fixture = PipelineQueueRerunFixture

    /// What the queue handed on, as `kind title` lines.
    private final class Saves {
        var lines: [String] = []
    }

    private func watch(_ queue: PipelineQueue, into saves: Saves, summarizer: MeetingSummarizer) {
        queue.onNotesSaved = { id, notes, title in
            switch notes {
            case .text: saves.lines.append("text \(title)")
            case let .file(url): saves.lines.append("file \(url.lastPathComponent)")
            }
            summarizer.notesSaved(jobID: id, notes: notes, title: title) { nil }
        }
    }

    /// The meeting's notes give its summary; Transcribe Again's own save gives none, its
    /// success the new notes' one from the current file, a typed summary kept.
    func testANewMeetingAndAReRunsSuccessGiveTheSummaryAndKeepATypedOne() async throws {
        for typed in [false, true] {
            let fixture = try Fixture(tmpDir: makeTempDirectory(prefix: "notes_summary"))
            let generator = NumberedNotesGen()
            let factory: () -> (any ProtocolGenerating)? = { generator }
            let queue = fixture.makeQueue(protocolGenerator: factory)
            let summarizer = MeetingSummarizer(store: MeetingSummaryStore(path: fixture.logDir.appendingPathComponent(MeetingSummaryStore.filename)))
            let saves = Saves()
            watch(queue, into: saves, summarizer: summarizer)

            let meeting = try await fixture.finishedMeeting(in: queue)
            XCTAssertEqual(saves.lines, ["text \(meeting.meetingTitle)"])
            XCTAssertEqual(summarizer.store.summaries(for: meeting.id)?.notes?.text, "Run 1.")
            if typed {
                summarizer.store.update(jobID: meeting.id) { MeetingSummary.afterTyped($0, field: "Mine", at: Date()) }
            }

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
            await queue.awaitProcessing()
            try await fixture.poll("the re-run's summary") { summarizer.store.summaries(for: meeting.id)?.notes?.text == "Run 2." }

            let current = try XCTUnwrap(queue.job(withID: meeting.id)?.protocolPath)
            XCTAssertEqual(saves.lines, ["text \(meeting.meetingTitle)", "file \(current.lastPathComponent)"], "typed: \(typed)")
            XCTAssertEqual(summarizer.store.summaries(for: meeting.id)?.typed?.text, typed ? "Mine" : nil)
            XCTAssertEqual(summarizer.store.summaries(for: meeting.id)?.shown, typed ? "Mine" : "Run 2.")
        }
    }

    /// Retry Meeting Notes hands its notes on; a retry whose notes fail again hands
    /// nothing on.
    func testARetryHandsItsNotesOnAndFailedNotesDoNot() async throws {
        for fails in [false, true] {
            let dir = try makeTempDirectory(prefix: "notes_summary_retry")
            let generator = NumberedNotesGen()
            generator.fails = fails
            let queue = PipelineQueue(
                engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
                outputDir: dir, logDir: dir,
            )
            let summarizer = MeetingSummarizer(store: MeetingSummaryStore(path: dir.appendingPathComponent(MeetingSummaryStore.filename)))
            let saves = Saves()
            watch(queue, into: saves, summarizer: summarizer)
            let transcript = dir.appendingPathComponent("20261030_0900_sprint.txt")
            try "[Me] Hello".write(to: transcript, atomically: true, encoding: .utf8)
            var job = PipelineJob(meetingTitle: "Sprint", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
            job.state = .done
            job.namingSlug = "20261030_0900_sprint"
            job.transcriptPath = transcript
            job.warnings = [PipelineQueue.protocolGenerationFailedWarning]
            job.notesFailure = .claudeSignedOut
            queue.insertJobForTesting(job)

            XCTAssertTrue(queue.retryMeetingNotes(id: job.id))
            await queue.awaitProcessing()

            XCTAssertEqual(generator.runs, 1)
            XCTAssertEqual(saves.lines, fails ? [] : ["text Sprint"], "fails: \(fails)")
            XCTAssertEqual(summarizer.store.summaries(for: job.id)?.notes?.text, fails ? nil : "Run 1.")
        }
    }
}
