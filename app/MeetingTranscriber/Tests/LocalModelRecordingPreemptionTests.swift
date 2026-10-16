#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// A recording and the local model (spec R5, A8): every kind of recording
    /// reaches the gate through one recording-activity signal, a recording that
    /// starts ends the running helper, and the protocol it deferred runs again
    /// by itself once the recording ends, in its original place in line. The
    /// job stays in `.generatingProtocol` meanwhile, so a restart resumes only
    /// that stage.
    @MainActor
    final class LocalModelRecordingPreemptionTests: XCTestCase {
        private let failureWarning = "Protocol generation failed — transcript saved"

        // MARK: - The queue at the gate

        func testRecordingStartEndsTheHelperAndTheProtocolRunsAfterTheRecording() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelPreemption"))
            let run = try bench.blockingOnceHelper()
            let pipeline = try LocalModelPipelineBench(bench, helper: run.helper)
            let id = try pipeline.enqueue(title: "Weekly")
            let pid = try await bench.pid(writtenTo: run.started)

            let recordingStart = ContinuousClock.now
            bench.gate.setRecordingActive(true)
            try await waitUntil("the helper to end") { kill(pid, 0) != 0 }
            XCTAssertLessThan(ContinuousClock.now - recordingStart, .seconds(5))
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(id)) reason=recording", count: 1)
            XCTAssertEqual(pipeline.job(id)?.state, .generatingProtocol)
            XCTAssertEqual(try bench.contents(of: run.events), "-\n", "a helper started during the recording")

            bench.gate.setRecordingActive(false)
            try await pipeline.waitUntilDone([id])

            XCTAssertEqual(try bench.contents(of: run.events), "-\n-\n")
            let job = try XCTUnwrap(pipeline.job(id))
            let written = try String(contentsOf: XCTUnwrap(job.protocolPath), encoding: .utf8)
            XCTAssertTrue(written.contains(LocalModelPipelineBench.protocolText))
            XCTAssertFalse(job.warnings.contains(failureWarning), "the interrupted attempt's outcome was recorded: \(job.warnings)")
        }

        func testProtocolDueDuringARecordingWaitsForItsEnd() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelPreemption"))
            let events = bench.scratch.appendingPathComponent("events")
            let helper = try bench.helper(#"echo run >> '\#(events.path)'; printf '\#(LocalModelPipelineBench.protocolText)' > "$out""#)
            let pipeline = try LocalModelPipelineBench(bench, helper: helper)

            bench.gate.setRecordingActive(true)
            let id = try pipeline.enqueue(title: "Weekly")
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(id)) reason=recording", count: 1)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(pipeline.job(id)?.state, .generatingProtocol)
            XCTAssertFalse(FileManager.default.fileExists(atPath: events.path), "a helper started during the recording")

            bench.gate.setRecordingActive(false)
            try await pipeline.waitUntilDone([id])
            XCTAssertEqual(try bench.contents(of: events), "run\n")
        }

        /// The job whose helper the recording ended goes first, then the job
        /// that was already waiting, then one that arrived during the recording.
        func testJobsInLineWhenARecordingStartsRunInTheirOriginalOrderAfterIt() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelPreemption"))
            let run = try bench.blockingOnceHelper()
            let pipeline = try LocalModelPipelineBench(bench, helper: run.helper)
            let alice = try await pipeline.jobAtSpeakerNaming(title: "First")
            let bob = try await pipeline.jobAtSpeakerNaming(title: "Second")
            pipeline.confirm(alice, as: "Alice")
            _ = try await bench.pid(writtenTo: run.started)
            pipeline.confirm(bob, as: "Bob")
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(bob)) reason=busy", count: 1)

            bench.gate.setRecordingActive(true)
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(alice)) reason=recording", count: 1)
            let later = try pipeline.enqueue(title: "Later")
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(later)) reason=recording", count: 1)
            XCTAssertEqual([alice, bob, later].map { pipeline.job($0)?.state }, [.generatingProtocol, .generatingProtocol, .generatingProtocol])

            bench.gate.setRecordingActive(false)
            try await pipeline.waitUntilDone([alice, bob, later])
            XCTAssertEqual(try bench.contents(of: run.events), "A\nA\nB\n-\n")
        }

        func testSnapshotSavedWhileDeferredRestoresIntoAProtocolOnlyRun() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelPreemption"))
            let run = try bench.blockingOnceHelper()
            let pipeline = try LocalModelPipelineBench(bench, helper: run.helper)
            let id = try pipeline.enqueue(title: "Weekly")
            _ = try await bench.pid(writtenTo: run.started)
            bench.gate.setRecordingActive(true)
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(id)) reason=recording", count: 1)
            await pipeline.queue.awaitSnapshotFlush()
            XCTAssertEqual(try PipelineSnapshot.load(from: pipeline.logDir)?.map(\.state), [.generatingProtocol])

            // The app quits here, and the next launch finds this snapshot.
            let restartLog = bench.scratch.appendingPathComponent("restart-log", isDirectory: true)
            try FileManager.default.createDirectory(at: restartLog, withIntermediateDirectories: false)
            try FileManager.default.copyItem(
                at: pipeline.logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename),
                to: restartLog.appendingPathComponent(PipelineSnapshot.snapshotFilename),
            )
            pipeline.queue.cancelJob(id: id)
            await pipeline.queue.awaitProcessing()

            let restart = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelRestart"))
            let helper = try restart.helper(#"printf '\#(LocalModelPipelineBench.protocolText)' > "$out""#)
            let restarted = try LocalModelPipelineBench(restart, helper: helper, outputDir: pipeline.outputDir, logDir: restartLog)
            restarted.queue.loadSnapshot()
            await restarted.queue.awaitProcessing()

            XCTAssertEqual(restarted.engine.transcribeCallCount, 0, "the restore ran more than the protocol stage")
            let job = try XCTUnwrap(restarted.job(id))
            XCTAssertEqual(job.state, .done)
            let written = try String(contentsOf: XCTUnwrap(job.protocolPath), encoding: .utf8)
            XCTAssertTrue(written.contains(LocalModelPipelineBench.protocolText))
        }

        // MARK: - The recording-activity signal

        /// From the moment a manual start is registered, while it still waits
        /// for the microphone answer, through the recording and its pause,
        /// until it stops.
        func testAManualRecordingHoldsTheGateFromItsStartThroughAPauseUntilItStops() async throws {
            let micAnswer = AsyncStream<Void>.makeStream()
            let controller = try makeWatchingController(
                logDir: makeTempDirectory(prefix: "LocalModelSignal"),
                ensureMicAccess: {
                    for await _ in micAnswer.stream {}
                    return true
                },
                permissionHealth: .allHealthy,
            )
            let start = try XCTUnwrap(controller.beginManualRecording(.microphone))
            addTeardownBlock { controller.stopManualRecording() }
            let waiter = GateWaiter(at: controller.pipeline.localModelGate)
            try await assertWaiting(waiter, "while the start waited for the microphone")
            XCTAssertNil(controller.watchLoop, "precondition: the start has not created its loop yet")

            micAnswer.continuation.finish()
            let started = await start.value
            XCTAssertEqual(started, .started, "precondition")
            try await assertWaiting(waiter, "while recording")
            XCTAssertEqual(controller.pauseRecording(), .changed, "precondition")
            try await assertWaiting(waiter, "while paused")

            controller.stopManualRecording()
            try await waitUntil("the waiting job's admission") { waiter.end != nil }
            XCTAssertTrue(waiter.wasAdmitted, "ended without its turn: \(String(describing: waiter.end))")
        }

        func testADetectedMeetingHoldsTheGateUntilWatchingStops() async throws {
            let controller = try await recordingADetectedMeeting(with: makeMockRecorder())
            let waiter = GateWaiter(at: controller.pipeline.localModelGate)
            try await assertWaiting(waiter, "while the detected meeting recorded")

            _ = await controller.stopWatching()
            try await waitUntil("the waiting job's admission") { waiter.end != nil }
            XCTAssertTrue(waiter.wasAdmitted, "ended without its turn: \(String(describing: waiter.end))")
        }

        /// Stop Watching takes the loop out of `.recording` at once, while the
        /// cancelled loop stops the recorder in a later turn: the gate holds
        /// until that stop, and admits the waiting job after it.
        func testStopWatchingHoldsTheGateUntilTheMeetingsRecorderHasStopped() async throws {
            let recorder = StopProbingRecorder()
            let controller = try await recordingADetectedMeeting(with: recorder)
            let gate = controller.pipeline.localModelGate
            let waiter = GateWaiter(at: gate)
            try await assertWaiting(waiter, "while the detected meeting recorded")
            var heldAtStop = false
            recorder.duringStop = { heldAtStop = gate.ownerJobID == nil && waiter.end == nil }

            controller.toggleWatching()
            XCTAssertNotEqual(controller.watchLoop?.state, .recording, "precondition: the loop left the recording")
            XCTAssertFalse(recorder.stopCalled, "precondition: the recorder stops in a later turn")
            XCTAssertNil(gate.ownerJobID, "admitted while the recorder still captured")

            try await waitUntil("the recorder to stop") { recorder.stopCalled }
            XCTAssertTrue(heldAtStop, "the gate let the job in before the recorder stopped")
            try await waitUntil("the waiting job's admission") { waiter.end != nil }
            XCTAssertTrue(waiter.wasAdmitted, "ended without its turn: \(String(describing: waiter.end))")
        }

        func testRecordOnlyModeHoldsTheGateWhileItIsOn() async throws {
            let controller = try makeWatchingController(logDir: makeTempDirectory(prefix: "LocalModelSignal"))
            controller.settings.recordOnly = true
            // The settings observer tells the gate one main-actor turn later.
            try await Task.sleep(for: .milliseconds(100))
            let waiter = GateWaiter(at: controller.pipeline.localModelGate)
            try await assertWaiting(waiter, "in record-only mode")

            controller.settings.recordOnly = false
            try await waitUntil("the waiting job's admission") { waiter.end != nil }
            XCTAssertTrue(waiter.wasAdmitted, "ended without its turn: \(String(describing: waiter.end))")
        }

        /// A controller watching with `recorder`, its detected meeting recording.
        private func recordingADetectedMeeting(with recorder: MockRecorder) async throws -> WatchingController {
            let controller = try makeWatchingController(
                logDir: makeTempDirectory(prefix: "LocalModelSignal"), permissionHealth: .allHealthy,
                makeDetector: { FixedMeetingDetector() },
                makeRecorder: { recorder },
            )
            controller.settings.recordWithoutAskingApps = [testMeetingApp]
            let started = await controller.startWatching()
            addTeardownBlock { _ = await controller.stopWatching() }
            XCTAssertEqual(started, .changed, "precondition")
            try await waitUntil("the meeting to record") { controller.watchLoop?.state == .recording && recorder.startCalled }
            return controller
        }

        /// The waiter is still in line a while after it arrived: the gate holds.
        private func assertWaiting(_ waiter: GateWaiter, _ when: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(waiter.end, "admitted \(when)", file: file, line: line)
        }
    }

    /// A recorder that completes a stop and runs `duringStop` at its start, so
    /// a test can look at the gate at the moment the capture ends.
    @MainActor
    private final class StopProbingRecorder: MockRecorder {
        var duringStop: (() -> Void)?

        override init() {
            super.init()
            mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
        }

        override func stop() throws -> RecordingResult {
            duringStop?()
            return try super.stop()
        }
    }

    /// A generation waiting at a gate as its own job, one that never starts a
    /// helper: its weights exceed any memory, so once admitted it ends at the
    /// admission check (`lowMemory`), before a run directory or a process.
    @MainActor
    private final class GateWaiter {
        let jobID = UUID()
        private(set) var end: LocalModelTestEnd?

        var wasAdmitted: Bool {
            if case .outcome(.lowMemory) = end { return true }
            return false
        }

        init(at gate: LocalModelGate) {
            let job = LocalModelJob(
                helper: URL(fileURLWithPath: "/usr/bin/false"), modelFolder: FileManager.default.temporaryDirectory,
                systemPrompt: "", userPrompt: "", weightBytes: .max,
            )
            Task { [jobID] in
                do {
                    let text = try await LocalModelGate.$jobID.withValue(jobID) { try await gate.run(job) }
                    end = .written(text)
                } catch {
                    end = LocalModelTestEnd(.failure(error))
                }
            }
        }
    }

#endif
