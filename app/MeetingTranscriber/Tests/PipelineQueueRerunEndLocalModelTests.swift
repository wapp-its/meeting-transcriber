#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// Cancel reaches a re-run's notes at the local model's gate under the re-run's
    /// own id, so the meeting is restored and its id stays admitted: its next re-run
    /// and a Regenerate Meeting Notes of it generate in the same queue and gate.
    @MainActor
    final class PipelineQueueRerunEndLocalModelTests: XCTestCase {
        func testCancelEndsTheGenerationWaitingAtOrRunningInTheGate() async throws {
            for running in [false, true] {
                let name = running ? "running" : "waiting"
                let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "rerun_end_local_model"))
                let fixture = try PipelineQueueRerunFixture(tmpDir: bench.scratch.appendingPathComponent("meeting"))
                let (block, started) = (bench.scratch.appendingPathComponent("block"), bench.scratch.appendingPathComponent("started"))
                let helper = try bench.helper("""
                if [ -e '\(block.path)' ]; then
                  echo $$ > '\(started.path)'
                  while true; do sleep 0.05; done
                fi
                printf '\(LocalModelPipelineBench.protocolText)' > "$out"
                """)
                let generator = bench.generator(helper: helper)
                let localModel: () -> (any ProtocolGenerating)? = { generator }
                let queue = fixture.makeQueue(completedJobLifetime: 0, protocolGenerator: localModel)
                let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
                let files = try fixture.outputFiles()
                try Data().write(to: block)
                if !running { bench.gate.setRecordingActive(true) }

                XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued, name)
                let runID = try fixture.marker(meeting.id, in: queue).runID
                if running {
                    let pid = try await bench.pid(writtenTo: started)
                    XCTAssertEqual(bench.gate.ownerJobID, runID, name)
                    queue.cancelJob(id: meeting.id)
                    try await fixture.poll("\(name): the helper to end") { kill(pid, 0) != 0 }
                } else {
                    try await bench.waitForNotices("local_model_waiting", count: 1)
                    queue.cancelJob(id: meeting.id)
                    bench.gate.setRecordingActive(false)
                }
                await queue.awaitProcessing()

                XCTAssertEqual(
                    bench.diagnostics.lines(.notice, startingWith: "local_model_cancel").count, 1, "\(name): no cancel at the gate",
                )
                XCTAssertNil(queue.job(withID: meeting.id), name)
                XCTAssertNil(try fixture.record(meeting.id).rerun, name)
                XCTAssertEqual(try fixture.outputFiles(), files, "\(name): the meeting is not as it was")

                try FileManager.default.removeItem(at: block)
                // Held before its swap, so the re-run's own files can be read when it is done.
                queue.isRegenerationRunning = { true }
                XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued, "\(name): the next re-run")
                await queue.awaitProcessing()
                XCTAssertTrue(
                    try fixture.marker(meeting.id, in: queue).files.contains { $0.role == .protocol }, "\(name): the next re-run made no notes",
                )
                let regenerated = try await LocalModelGate.$jobID.withValue(meeting.id) {
                    try await generator.generate(
                        transcript: "Alice: hello", title: "Weekly", diarized: true, meetingStartTime: nil,
                        instructions: LocalModelTestBench.instructions,
                    )
                }
                XCTAssertFalse(regenerated.isEmpty, "\(name): Regenerate Meeting Notes made no notes")
            }
        }
    }

#endif
