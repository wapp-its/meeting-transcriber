#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// A re-run's notes go through the local model's gate under the re-run's own
    /// id, so that ending the re-run never refuses the meeting's id at the gate.
    @MainActor
    final class PipelineQueueRerunLocalModelTests: XCTestCase {
        func testARerunsNotesReachTheGateUnderTheMarkersRunID() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "rerun_local_model"))
            let fixture = try PipelineQueueRerunFixture(tmpDir: bench.scratch.appendingPathComponent("meeting"))
            let (block, started, release) = (
                bench.scratch.appendingPathComponent("block"), bench.scratch.appendingPathComponent("started"),
                bench.scratch.appendingPathComponent("release"),
            )
            let helper = try bench.helper("""
            if [ -e '\(block.path)' ]; then
              echo $$ > '\(started.path)'
              while [ ! -e '\(release.path)' ]; do sleep 0.05; done
            fi
            printf '\(LocalModelPipelineBench.protocolText)' > "$out"
            """)
            let generator = bench.generator(helper: helper)
            let localModel: () -> (any ProtocolGenerating)? = { generator }
            let queue = fixture.makeQueue(protocolGenerator: localModel)
            let meeting = try await fixture.finishedMeeting(in: queue)
            try Data().write(to: block)

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
            _ = try await bench.pid(writtenTo: started)

            let runID = try fixture.marker(meeting.id, in: queue).runID
            XCTAssertNotEqual(runID, meeting.id)
            XCTAssertEqual(bench.gate.ownerJobID, runID, "the re-run's notes went through the gate under another id")
            try Data().write(to: release)
            await queue.awaitProcessing()
            XCTAssertTrue(try fixture.marker(meeting.id, in: queue).files.contains { $0.role == .protocol }, "no notes saved")
        }
    }

#endif
