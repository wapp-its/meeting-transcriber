@testable import MeetingTranscriber
import XCTest

/// The one list the Transcriptions window and the menu both read: the live
/// jobs merged with the finished-job history, in order, searched, and cut down
/// to the menu's share. Plus the status wording and the file opener both
/// views use.
final class TranscriptionListTests: XCTestCase {
    private static let start = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private static func at(minute: Double) -> Date {
        start.addingTimeInterval(minute * 60)
    }

    /// A job added `minute` minutes after `start`. Forged through its coding,
    /// the way a snapshot restores one, because `enqueuedAt` is set at init.
    private func job(
        _ title: String, addedAt minute: Double, state: JobState = .waiting,
        participants: [String] = [], meetingStartedAt meetingMinute: Double? = nil,
    ) throws -> PipelineJob {
        let fresh = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/\(title)_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
            participants: participants, meetingStartTime: meetingMinute.map { Self.at(minute: $0) },
        )
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        encoded["enqueuedAt"] = Self.at(minute: minute).timeIntervalSinceReferenceDate
        encoded["state"] = state.rawValue
        return try JSONDecoder().decode(PipelineJob.self, from: JSONSerialization.data(withJSONObject: encoded))
    }

    /// The history record a finished job leaves.
    private func record(_ title: String, addedAt minute: Double, state: JobState = .done) throws -> TerminalJobRecord {
        try TerminalJobRecord(job: job(title, addedAt: minute, state: state))
    }

    /// A record written before the history kept enqueue times.
    private func legacyRecord(_ title: String) -> TerminalJobRecord {
        TerminalJobRecord(status: JobStatusDTO(
            jobID: UUID().uuidString, state: .done, meetingTitle: title,
            transcriptPath: nil, protocolPath: nil, error: nil, warnings: [],
        ))
    }

    private func titles(_ entries: [TranscriptionEntry]) -> [String] {
        entries.map(\.title)
    }

    // MARK: - Merge and order

    /// A finished job is live for a while and in the history from the moment
    /// it finished, and a retried one is live again; either way it is one job.
    func testAJobBothLiveAndInTheHistoryIsListedOnceWithItsLiveState() throws {
        let failed = try job("Retro", addedAt: 0, state: .error)
        var retried = failed
        retried.state = .waiting
        let unidentifiable = TerminalJobRecord(status: JobStatusDTO(
            jobID: "not-a-uuid", state: .done, meetingTitle: "Broken",
            transcriptPath: nil, protocolPath: nil, error: nil, warnings: [],
        ))

        let entries = TranscriptionList.entries(
            liveJobs: [retried], records: [TerminalJobRecord(job: failed), unidentifiable],
        )

        XCTAssertEqual(entries.count, 1, "the job was listed twice, or a record without a job id was listed")
        XCTAssertEqual(entries.first?.id, failed.id)
        XCTAssertEqual(entries.first?.state, .waiting, "the history's outcome won over the live job")
        XCTAssertEqual(entries.first?.isLive, true)
    }

    /// Newest first by when the job was added, not by when the meeting took
    /// place, so a retried job, which keeps its enqueue time, stays where it
    /// was. Records written before the history knew that time go last, the
    /// newest stored first. The date shown is the meeting start, else the
    /// enqueue time.
    func testDatedEntriesComeNewestFirstThenUndatedNewestStoredFirst() throws {
        var retried = try job("Retried", addedAt: 10, state: .error)
        retried.state = .waiting
        let live = try [job("Latest", addedAt: 30, meetingStartedAt: -100), retried]
        let records = try [
            legacyRecord("Oldest stored"),
            record("Middle", addedAt: 20),
            legacyRecord("Newer stored"),
        ]

        let entries = TranscriptionList.entries(liveJobs: live, records: records)

        XCTAssertEqual(titles(entries), ["Latest", "Middle", "Retried", "Newer stored", "Oldest stored"])
        XCTAssertEqual(entries.map(\.date), [Self.at(minute: -100), Self.at(minute: 20), Self.at(minute: 10), nil, nil])
    }

    // MARK: - Status wording

    /// The window and the menu say the same thing about a job, whether it is
    /// live or known only from the history.
    func testEveryStateReadsTheWayTheMenuSaysIt() {
        let progress = "Transcribing... 1:05"
        let expected: [(JobState, Bool, String, String)] = [
            (.waiting, false, "Waiting...", "clock"),
            (.transcribing, false, progress, "waveform"),
            (.diarizing, false, progress, "person.2"),
            (.generatingProtocol, false, progress, "doc.text"),
            (.speakerNamingPending, false, "Speaker names needed", "person.crop.circle.badge.questionmark"),
            (.done, false, "Done", "checkmark.circle"),
            (.done, true, "Done, with warnings", "exclamationmark.triangle"),
            (.error, false, "Failed", "xmark.octagon"),
            (.error, true, "Failed", "xmark.octagon"),
        ]
        for (state, hasWarnings, status, symbol) in expected {
            XCTAssertEqual(
                JobMenuSummary.status(state: state, hasWarnings: hasWarnings, progress: progress), status,
                "\(state), warnings: \(hasWarnings)",
            )
            XCTAssertEqual(
                JobMenuSummary.symbol(state: state, hasWarnings: hasWarnings), symbol,
                "\(state), warnings: \(hasWarnings)",
            )
        }
    }

    // MARK: - Search

    func testSearchFindsATitleOrParticipantIgnoringCaseAndDiacritics() throws {
        let entries = try TranscriptionList.entries(
            liveJobs: [
                job("Müller Sync", addedAt: 2),
                job("Budget Review", addedAt: 1, participants: ["Ana Pérez", "Ben Okafor"]),
                job("Standup", addedAt: 0),
            ],
            records: [],
        )

        XCTAssertEqual(titles(TranscriptionList.matching(entries, query: "muller")), ["Müller Sync"])
        XCTAssertEqual(titles(TranscriptionList.matching(entries, query: "SYNC")), ["Müller Sync"])
        XCTAssertEqual(titles(TranscriptionList.matching(entries, query: " perez ")), ["Budget Review"])
        XCTAssertEqual(TranscriptionList.matching(entries, query: ""), entries)
        XCTAssertEqual(TranscriptionList.matching(entries, query: "  \n"), entries)
        XCTAssertEqual(TranscriptionList.matching(entries, query: "Quarterly"), [])
    }

    // MARK: - The menu's share

    /// Every unfinished job, and of the finished ones only the three that
    /// finished last, shown in the order the jobs were added. The history's
    /// order is the finish order, which here differs from the add order.
    func testTheMenuKeepsUnfinishedJobsAndTheThreeThatFinishedLast() throws {
        let finishedInOrder: [Double] = [0, 9, 1, 8, 3, 6, 5, 2, 7, 4]
        let records = try finishedInOrder.map { try record("Done \(Int($0))", addedAt: $0) }
        let unfinished = try [
            job("Waiting", addedAt: 5.5),
            job("Running", addedAt: 100, state: .transcribing),
        ]

        let menu = TranscriptionList.menuEntries(TranscriptionList.entries(liveJobs: unfinished, records: records))

        XCTAssertEqual(titles(menu), ["Done 2", "Done 4", "Waiting", "Done 7", "Running"])

        let none = TranscriptionList.menuEntries(TranscriptionList.entries(liveJobs: unfinished, records: []))

        XCTAssertEqual(titles(none), ["Waiting", "Running"])
    }

    /// A failed job is retried and finishes after jobs added later than it.
    /// Its record moves to the end of the history, so it has finished last
    /// although it was added first.
    func testARetriedJobThatFinishedLastIsAmongTheMenusFinishedJobs() throws {
        let failed = try job("Flaky", addedAt: 0, state: .error)
        var history = try [TerminalJobRecord(job: failed)]
            + [record("A", addedAt: 1), record("B", addedAt: 2), record("C", addedAt: 3)]
        var finished = failed
        finished.state = .done
        history = TerminalJobStore.upserting(history, with: TerminalJobRecord(job: finished), cap: 1000)

        let menu = TranscriptionList.menuEntries(TranscriptionList.entries(liveJobs: [finished], records: history))

        XCTAssertEqual(titles(menu), ["Flaky", "B", "C"])
    }

    /// The queue keeps a failed job until it is removed, while the history
    /// drops its oldest records at the cap. Such a job finished before every
    /// job still recorded, so it must not push those out of the menu; without
    /// any history (a queue with no store) the jobs still rank by when they
    /// were added.
    func testFailedJobsWhoseRecordsWereEvictedDoNotCrowdOutRecentCompletions() throws {
        let evicted = try (0 ..< 3).map { try job("Old failure \($0)", addedAt: Double($0), state: .error) }
        let records = try (10 ..< 14).map { try record("Recent \($0)", addedAt: Double($0)) }

        let menu = TranscriptionList.menuEntries(TranscriptionList.entries(liveJobs: evicted, records: records))

        XCTAssertEqual(titles(menu), ["Recent 11", "Recent 12", "Recent 13"])

        let unrecorded = try (0 ..< 5).map { index in
            try job("Finished \(index)", addedAt: Double(index), state: index.isMultiple(of: 2) ? .done : .error)
        }

        let noHistory = TranscriptionList.menuEntries(TranscriptionList.entries(liveJobs: unrecorded, records: []))

        XCTAssertEqual(titles(noHistory), ["Finished 2", "Finished 3", "Finished 4"])
    }

    // MARK: - Opening a file

    /// Open takes the protocol, or the transcript when there is none, and a
    /// history entry gets both from the paths its record stored.
    func testOpenTakesTheProtocolElseTheTranscript() throws {
        var both = try job("Both", addedAt: 2, state: .done)
        both.protocolPath = URL(fileURLWithPath: "/out/both.md")
        both.transcriptPath = URL(fileURLWithPath: "/out/both.txt")
        var transcriptOnly = try job("Transcript only", addedAt: 1, state: .error)
        transcriptOnly.transcriptPath = URL(fileURLWithPath: "/out/transcript only.txt")
        let neither = try job("Neither", addedAt: 0, state: .error)

        let entries = TranscriptionList.entries(
            liveJobs: [], records: [both, transcriptOnly, neither].map(TerminalJobRecord.init(job:)),
        )

        XCTAssertEqual(entries.map(\.fileToOpen), [
            URL(fileURLWithPath: "/out/both.md"), URL(fileURLWithPath: "/out/transcript only.txt"), nil,
        ])
    }

    func testTheFileOpenerActsOnlyOnAFileThatExists() throws {
        let folder = try makeTempDirectory(prefix: "transcription_file_opener")
        let existing = folder.appendingPathComponent("standup.md")
        try Data("# Standup".utf8).write(to: existing)
        let missing = folder.appendingPathComponent("moved.md")
        var opened: [URL] = []

        XCTAssertFalse(TranscriptionFileOpener.perform(missing, scopeRoot: folder) { opened.append($0) })
        XCTAssertEqual(opened, [], "the action ran for a file that is not there")

        XCTAssertTrue(TranscriptionFileOpener.perform(existing, scopeRoot: folder) { opened.append($0) })
        XCTAssertEqual(opened, [existing])
    }
}
