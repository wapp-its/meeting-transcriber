@testable import MeetingTranscriber
import XCTest

/// A provider stand-in for the summary call: it records each request, can be held
/// until a test opens its gate, and answers what the test set.
final class StubSummaryGenerator: ProtocolGenerating, @unchecked Sendable {
    struct Request: Equatable {
        let text: String
        let title: String
        let diarized: Bool
        let meetingStartTime: Date?
        let template: String
        let background: String?
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private let answer: Result<String, any Error>
    private let gate: AsyncGate?
    /// Sleeps until cancelled, as a provider that never answers.
    private let hangs: Bool

    init(answer: Result<String, any Error> = .success("The team agreed on the plan."), gate: AsyncGate? = nil, hangs: Bool = false) {
        self.answer = answer
        self.gate = gate
        self.hangs = hangs
    }

    var requests: [Request] {
        lock.withLock { recorded }
    }

    func generate(
        transcript: String, title: String, diarized: Bool, meetingStartTime: Date?, instructions: ProtocolInstructions,
    ) async throws -> String {
        let request = Request(
            text: transcript, title: title, diarized: diarized, meetingStartTime: meetingStartTime,
            template: instructions.template, background: instructions.background,
        )
        lock.withLock { recorded.append(request) }
        if let gate { await gate.wait() }
        if hangs { try await Task.sleep(for: .seconds(60)) }
        return try answer.get()
    }
}

/// The summary a notes save gives (spec R2, R5, R8): from the notes' section, else
/// from one call to the provider, and nothing from a call that fails, times out,
/// answers nothing or was overtaken. Every note and summary here is made up.
@MainActor
final class MeetingSummarizerTests: XCTestCase {
    private static let withoutSection = "# Notes\n\n## Decisions\n- Ship on Friday"
    private static let withSection = "# Notes\n\n## Summary\nFrom the section."
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeSummarizer(callTimeout: Duration = .seconds(30)) throws -> MeetingSummarizer {
        let path = try makeTempDirectory(prefix: "meeting-summarizer").appendingPathComponent(MeetingSummaryStore.filename)
        return MeetingSummarizer(store: MeetingSummaryStore(path: path), now: { [date] in date }, callTimeout: callTimeout)
    }

    private func saved(_ text: String) -> MeetingSummaries {
        MeetingSummaries(notes: .init(text: text, writtenAt: date))
    }

    /// Notes without a section: one call with the notes, the title, no speaker note, no
    /// meeting time and the summary instruction; the cleaned answer is the summary.
    func testNotesWithoutASectionAskTheProviderOnceWithTheInstruction() async throws {
        let summarizer = try makeSummarizer()
        let generator = StubSummaryGenerator(answer: .success("**The team** agreed on the plan.\n"))
        let job = UUID()
        var asked = 0

        summarizer.notesSaved(jobID: job, notes: .text(Self.withoutSection), title: "Weekly sync") {
            asked += 1
            return generator
        }
        await summarizer.awaitCalls()

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(generator.requests, [.init(
            text: Self.withoutSection, title: "Weekly sync", diarized: false, meetingStartTime: nil,
            template: MeetingSummary.instruction, background: nil,
        )])
        XCTAssertEqual(summarizer.store.summaries(for: job), saved("The team agreed on the plan."))
    }

    /// Notes with a section, and provider None, make no call; a typed summary stays.
    func testASectionOrNoProviderMakesNoCall() async throws {
        let summarizer = try makeSummarizer()
        let job = UUID()
        let typed = MeetingSummaries.Saved(text: "Mine", writtenAt: date)
        summarizer.store.update(jobID: job) { _ in MeetingSummaries(typed: typed) }
        var asked = 0

        summarizer.notesSaved(jobID: job, notes: .text(Self.withSection), title: "Sync") {
            asked += 1
            return StubSummaryGenerator()
        }
        summarizer.notesSaved(jobID: UUID(), notes: .text(Self.withoutSection), title: "Sync") { nil }
        await summarizer.awaitCalls()

        XCTAssertEqual(asked, 0)
        XCTAssertEqual(summarizer.store.summaries(for: job), MeetingSummaries(notes: .init(text: "From the section.", writtenAt: date), typed: typed))
        XCTAssertEqual(summarizer.store.summaries.count, 1)
    }

    /// A failed, timed-out or empty call stores nothing and keeps the earlier summary.
    func testAFailedTimedOutOrEmptyCallKeepsTheEarlierSummary() async throws {
        let generators = [
            StubSummaryGenerator(answer: .failure(ProtocolError.httpError(500, "made-up"))),
            StubSummaryGenerator(hangs: true),
            StubSummaryGenerator(answer: .success(" \n---\n")),
        ]
        for generator in generators {
            let summarizer = try makeSummarizer(callTimeout: .milliseconds(200))
            let job = UUID()
            summarizer.store.update(jobID: job) { _ in self.saved("Earlier") }

            summarizer.notesSaved(jobID: job, notes: .text(Self.withoutSection), title: "Sync") { generator }
            await summarizer.awaitCalls()

            XCTAssertEqual(generator.requests.count, 1)
            XCTAssertEqual(summarizer.store.summaries(for: job), saved("Earlier"))
        }
    }

    /// A newer save of the meeting, and its move to the Trash, each drop the answer of
    /// a call still running, also from a provider that ignores the cancel.
    func testAnOvertakenOrTrashedMeetingsAnswerIsDropped() async throws {
        let summarizer = try makeSummarizer()
        let (overtaken, trashed) = (UUID(), UUID())
        let gate = AsyncGate()
        let held = StubSummaryGenerator(answer: .success("Late answer"), gate: gate)

        summarizer.notesSaved(jobID: overtaken, notes: .text(Self.withoutSection), title: "Sync") { held }
        summarizer.notesSaved(jobID: trashed, notes: .text(Self.withoutSection), title: "Sync") { held }
        while await !gate.hasWaiter {
            try await Task.sleep(for: .milliseconds(10))
        }
        summarizer.notesSaved(jobID: overtaken, notes: .text(Self.withSection), title: "Sync") { held }
        summarizer.forget(jobID: trashed)
        await gate.open()
        await summarizer.awaitCalls()

        XCTAssertEqual(held.requests.count, 1, "the trashed meeting's call, queued behind, never started")
        XCTAssertEqual(summarizer.store.summaries, [overtaken: saved("From the section.")])
    }

    /// The file records each meeting's latest notes save: a newer save or a removal in
    /// another running build, and summaries cleared in the sheet, drop the answer of a
    /// call still running here.
    func testAnotherBuildsSaveOrRemovalAndAClearedSummaryDropTheAnswer() async throws {
        enum Change: CaseIterable { case newerSaveElsewhere, removalElsewhere, clearedInTheSheet }
        for change in Change.allCases {
            let path = try makeTempDirectory(prefix: "meeting-summarizer").appendingPathComponent(MeetingSummaryStore.filename)
            let here = MeetingSummarizer(store: MeetingSummaryStore(path: path)) { [date] in date }
            let elsewhere = MeetingSummarizer(store: MeetingSummaryStore(path: path)) { [date] in date }
            let job = UUID()
            let gate = AsyncGate()
            let held = StubSummaryGenerator(answer: .success("Old answer."), gate: gate)
            here.notesSaved(jobID: job, notes: .text(Self.withoutSection), title: "Sync") { held }
            while await !gate.hasWaiter {
                try await Task.sleep(for: .milliseconds(10))
            }

            switch change {
            case .newerSaveElsewhere:
                elsewhere.notesSaved(jobID: job, notes: .text(Self.withSection), title: "Sync") { nil }

            case .removalElsewhere:
                elsewhere.forget(jobID: job)

            case .clearedInTheSheet:
                here.store.update(jobID: job) { MeetingSummary.afterTyped($0, field: " \n", at: self.date) }
            }
            await gate.open()
            await here.awaitCalls()

            let expected = change == .newerSaveElsewhere ? saved("From the section.") : nil
            XCTAssertEqual(MeetingSummaryStore(path: path).summaries(for: job), expected, "\(change)")
        }
    }

    /// One call at a time: the second meeting's call starts once the first one ended.
    func testCallsRunOneAtATime() async throws {
        let summarizer = try makeSummarizer()
        let gate = AsyncGate()
        let first = StubSummaryGenerator(answer: .success("First."), gate: gate)
        let second = StubSummaryGenerator(answer: .success("Second."))
        let (one, two) = (UUID(), UUID())

        summarizer.notesSaved(jobID: one, notes: .text(Self.withoutSection), title: "One") { first }
        summarizer.notesSaved(jobID: two, notes: .text(Self.withoutSection), title: "Two") { second }
        while await !gate.hasWaiter {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(second.requests.count, 0, "the second call started while the first ran")

        await gate.open()
        await summarizer.awaitCalls()

        XCTAssertEqual(summarizer.store.summaries, [one: saved("First."), two: saved("Second.")])
    }

    /// The notes a re-run made current are read from their file; a file that is gone
    /// changes nothing.
    func testNotesSavedAsAFileAreReadOnceAndAGoneFileChangesNothing() async throws {
        let summarizer = try makeSummarizer()
        let folder = try makeTempDirectory(prefix: "meeting-summarizer-notes")
        let notes = folder.appendingPathComponent("notes.md")
        try Self.withSection.write(to: notes, atomically: true, encoding: .utf8)
        let (present, gone) = (UUID(), UUID())
        summarizer.store.update(jobID: gone) { _ in self.saved("Earlier") }

        summarizer.notesSaved(jobID: present, notes: .file(notes), title: "Sync") { nil }
        summarizer.notesSaved(jobID: gone, notes: .file(folder.appendingPathComponent("gone.md")), title: "Sync") { StubSummaryGenerator() }
        try await waitUntil { summarizer.store.summaries(for: present) != nil }

        XCTAssertEqual(summarizer.store.summaries, [present: saved("From the section."), gone: saved("Earlier")])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
