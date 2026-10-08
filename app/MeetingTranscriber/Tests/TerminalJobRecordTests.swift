@testable import MeetingTranscriber
import XCTest

/// The finished-job history's element, as `terminal_jobs.json` stores it.
///
/// The file outlives the build that wrote it in both directions: an update
/// reads what an older build wrote, and a downgrade reads what this one wrote.
/// The store decodes the file as one array, so a record either direction
/// cannot decode costs the whole history, not one entry.
@MainActor
final class TerminalJobRecordTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "terminal_job_record_test")
    }

    private var storePath: URL {
        tmpDir.appendingPathComponent("terminal_jobs.json")
    }

    /// The keys this change adds next to the status fields.
    private static let historyKeys: Set = [
        "appName", "meetingStartTime", "enqueuedAt", "audioDuration", "participants",
    ]

    /// A finished job with every field the history carries set.
    private func finishedJob() -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Design Review", appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/rec/design_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
            participants: ["Anna Müller", "Ben Okafor"],
            meetingStartTime: Date(timeIntervalSinceReferenceDate: 780_000_000),
        )
        job.state = .done
        job.transcriptPath = URL(fileURLWithPath: "/out/design.txt")
        job.protocolPath = URL(fileURLWithPath: "/out/design.md")
        job.warnings = ["Diarization failed — speakers not identified"]
        job.audioDuration = 1834.5
        return job
    }

    // MARK: - Reading what an older build wrote

    func testAHistoryWrittenBeforeTheExtraFieldsLoadsEveryRecord() throws {
        // Exactly what the store wrote while its element was the status shape.
        let legacy = [
            JobStatusDTO(
                jobID: UUID().uuidString, state: .done, meetingTitle: "Standup",
                transcriptPath: "/out/standup.txt", protocolPath: "/out/standup.md",
                error: nil, warnings: [],
            ),
            JobStatusDTO(
                jobID: UUID().uuidString, state: .error, meetingTitle: "Retro",
                transcriptPath: nil, protocolPath: nil,
                error: "Empty transcript", warnings: ["Raw transcript retained because the job did not complete"],
            ),
        ]
        try JSONEncoder().encode(legacy).write(to: storePath)

        let store = TerminalJobStore(path: storePath)

        XCTAssertEqual(store.records.map(\.status), legacy, "a legacy record was lost or changed")
        for record in store.records {
            XCTAssertNil(record.appName)
            XCTAssertNil(record.meetingStartTime)
            XCTAssertNil(record.enqueuedAt)
            XCTAssertNil(record.audioDuration)
            XCTAssertEqual(record.participants, [])
        }
    }

    // MARK: - Round trip

    func testARecordWithEveryFieldSurvivesARestart() {
        let record = TerminalJobRecord(job: finishedJob())
        TerminalJobStore(path: storePath).record(record)

        XCTAssertEqual(TerminalJobStore(path: storePath).records, [record])
    }

    // MARK: - The wire shape stays as it was

    func testTheStatusALookupReturnsCarriesNoneOfTheHistoryFields() throws {
        let job = finishedJob()
        let store = TerminalJobStore(path: storePath)
        store.record(TerminalJobRecord(job: job))

        let status = try XCTUnwrap(TerminalJobStore(path: storePath).lookup(jobID: job.id))
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any],
        )

        XCTAssertEqual(status, JobStatusDTO(job: job))
        XCTAssertTrue(
            Self.historyKeys.isDisjoint(with: encoded.keys),
            "the /v1 status gained \(Self.historyKeys.intersection(encoded.keys).sorted())",
        )
    }

    // MARK: - Reading what this build wrote, as the previous build does

    func testAHistoryWrittenNowStaysReadableAsTheStatusShape() throws {
        let job = finishedJob()
        TerminalJobStore(path: storePath).record(TerminalJobRecord(job: job))

        // The previous build decodes the file as `[JobStatusDTO]`.
        let decoded = try JSONDecoder().decode([JobStatusDTO].self, from: Data(contentsOf: storePath))

        XCTAssertEqual(decoded, [JobStatusDTO(job: job)])
    }
}
