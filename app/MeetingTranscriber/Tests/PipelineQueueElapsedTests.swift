@testable import MeetingTranscriber
import XCTest

/// Each job's stage clock is its own: another job entering or leaving a timed
/// stage neither restarts nor ends it.
@MainActor
final class PipelineQueueElapsedTests: XCTestCase {
    func testStartingAnotherTimedStageDoesNotResetFirstJobsClock() throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        queue.updateJobState(id: first, to: .transcribing)
        let before = try XCTUnwrap(queue.stageClock(forJobID: first))

        queue.updateJobState(id: second, to: .diarizing)

        XCTAssertEqual(queue.stageClock(forJobID: first), before)
        XCTAssertEqual(queue.stageClock(forJobID: second)?.config.stage, .diarizing)
    }

    func testEndingAnotherTimedStageDoesNotEndFirstJobsClock() throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        queue.updateJobState(id: first, to: .transcribing)
        queue.updateJobState(id: second, to: .diarizing)
        let before = try XCTUnwrap(queue.stageClock(forJobID: first))

        queue.updateJobState(id: second, to: .speakerNamingPending)

        XCTAssertEqual(queue.stageClock(forJobID: first), before)
        XCTAssertNil(queue.stageClock(forJobID: second))
    }

    func testStageChangeRestartsOnlyThatJobsClock() async throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        queue.updateJobState(id: first, to: .transcribing)
        queue.updateJobState(id: second, to: .transcribing)
        let secondBefore = try XCTUnwrap(queue.stageClock(forJobID: second))
        let firstBefore = try XCTUnwrap(queue.stageClock(forJobID: first))
        try await Task.sleep(for: .milliseconds(50))

        queue.updateJobState(id: first, to: .diarizing)

        let firstAfter = try XCTUnwrap(queue.stageClock(forJobID: first))
        XCTAssertEqual(firstAfter.config.stage, .diarizing)
        XCTAssertGreaterThan(firstAfter.startedAt.timeIntervalSince(firstBefore.startedAt), 0.03)
        XCTAssertEqual(queue.stageClock(forJobID: second), secondBefore)
    }

    func testPendingTerminalAndCancelledJobsHaveNoClock() throws {
        let (queue, first, second) = try makeQueueWithTwoJobs()
        XCTAssertNil(queue.stageClock(forJobID: first))

        queue.updateJobState(id: first, to: .diarizing)
        XCTAssertNotNil(queue.stageClock(forJobID: first))
        queue.updateJobState(id: first, to: .speakerNamingPending)
        XCTAssertNil(queue.stageClock(forJobID: first))
        queue.updateJobState(id: first, to: .done)
        XCTAssertNil(queue.stageClock(forJobID: first))

        queue.updateJobState(id: second, to: .transcribing)
        queue.cancelJob(id: second)
        XCTAssertNil(queue.stageClock(forJobID: second))
    }

    private func makeQueueWithTwoJobs() throws -> (PipelineQueue, UUID, UUID) {
        let dir = try makeTempDirectory(prefix: "pipeline_elapsed_test")
        let queue = PipelineQueue(logDir: dir)
        let first = PipelineJob(
            meetingTitle: "First", appName: "Teams",
            mixPath: dir.appendingPathComponent("first.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let second = PipelineJob(
            meetingTitle: "Second", appName: "Zoom",
            mixPath: dir.appendingPathComponent("second.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(first)
        queue.enqueue(second)
        return (queue, first.id, second.id)
    }
}
