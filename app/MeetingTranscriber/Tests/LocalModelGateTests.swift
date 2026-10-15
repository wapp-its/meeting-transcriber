#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// The gate against fake helpers (`LocalModelTestBench`): one helper at a
    /// time, cancellation per job, the memory guard's two decisions while a
    /// helper starts and runs, a recording's preemption, and the quit.
    @MainActor
    final class LocalModelGateTests: XCTestCase {
        func testConcurrentGenerationsNeverOverlap() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let events = bench.scratch.appendingPathComponent("events")
            let helper = try bench.helper("""
            echo start >> '\(events.path)'
            sleep 0.3
            echo end >> '\(events.path)'
            printf 'Protocol' > "$out"
            """)

            async let first = bench.end(helper)
            async let second = bench.end(helper)
            let ends = await [first, second]

            XCTAssertEqual(ends, [.written("Protocol"), .written("Protocol")])
            XCTAssertEqual(try bench.contents(of: events), "start\nend\nstart\nend\n")
            XCTAssertEqual(bench.diagnostics.lines(.notice, startingWith: "local_model_waiting job=none reason=busy").count, 1)
        }

        func testCancelEndsOnlyTheOwningJobsHelper() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let started = bench.scratch.appendingPathComponent("started")
            let helper = try bench.helper("trap 'exit 13' TERM; echo $$ > '\(started.path)'; while :; do sleep 0.05; done")
            let owner = UUID()
            let task = Task { await LocalModelGate.$jobID.withValue(owner) { await bench.end(helper) } }
            let pid = try await bench.pid(writtenTo: started)
            XCTAssertEqual(bench.gate.ownerJobID, owner)

            bench.gate.cancel(jobID: UUID())
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(kill(pid, 0), 0, "another job's cancel ended this helper")

            bench.gate.cancel(jobID: owner)
            let end = await task.value

            XCTAssertEqual(end, .cancelled)
            XCTAssertNil(bench.gate.ownerJobID)
        }

        /// Waiting by job id, waiting without one (the task is cancelled), and
        /// arriving only after the job was cancelled: none of them starts a helper.
        func testJobCancelledWhileWaitingOrBeforeArrivingNeverStartsAHelper() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let started = bench.scratch.appendingPathComponent("started")
            let spawned = bench.scratch.appendingPathComponent("spawned")
            let blocking = try bench.helper("trap 'exit 13' TERM; echo $$ > '\(started.path)'; while :; do sleep 0.05; done")
            let other = try bench.helper(#"touch '\#(spawned.path)'; printf 'Protocol' > "$out""#)
            let (running, waiting, late) = (UUID(), UUID(), UUID())
            let first = Task { await LocalModelGate.$jobID.withValue(running) { await bench.end(blocking) } }
            _ = try await bench.pid(writtenTo: started)
            let second = Task { await LocalModelGate.$jobID.withValue(waiting) { await bench.end(other) } }
            let third = Task { await bench.end(other) }
            try await bench.waitForNotices("local_model_waiting", count: 2)

            bench.gate.cancel(jobID: waiting)
            third.cancel()
            bench.gate.cancel(jobID: late)
            let lateEnd = await LocalModelGate.$jobID.withValue(late) { await bench.end(other) }
            bench.gate.cancel(jobID: running)
            let ends = await [first.value, second.value, third.value, lateEnd]

            XCTAssertEqual(ends, [.cancelled, .cancelled, .cancelled, .cancelled])
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawned.path))
            let next = await bench.end(other)
            XCTAssertEqual(next, .written("Protocol"))
        }

        func testHelperIgnoringSigtermIsKilledAfterTheGraceAndTheGateIsFreeAgain() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let started = bench.scratch.appendingPathComponent("started")
            let stubborn = try bench.helper("trap '' TERM; echo $$ > '\(started.path)'; exec sleep 30")
            let job = UUID()
            let task = Task { await LocalModelGate.$jobID.withValue(job) { await bench.end(stubborn) } }
            let pid = try await bench.pid(writtenTo: started)

            let cancelledAt = ContinuousClock.now
            bench.gate.cancel(jobID: job)
            let end = await task.value
            let waited = ContinuousClock.now - cancelledAt

            XCTAssertEqual(end, .cancelled)
            XCTAssertGreaterThanOrEqual(waited, LocalModelLimits.fast().killGrace)
            XCTAssertLessThan(waited, .seconds(5))
            XCTAssertEqual(bench.diagnostics.lines(.notice, startingWith: "local_model_killed").count, 1)
            XCTAssertNotEqual(kill(pid, 0), 0, "the helper still runs")
            XCTAssertEqual(bench.runDirectoryNames, [])
            let next = try await bench.end(bench.helper(#"printf 'Protocol' > "$out""#))
            XCTAssertEqual(next, .written("Protocol"))
        }

        func testAdmissionNeedsNormalPressureAndTheWeightsPlusHeadroom() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let spawned = bench.scratch.appendingPathComponent("spawned")
            let helper = try bench.helper(#"touch '\#(spawned.path)'; printf 'Protocol' > "$out""#)
            let needed = LocalModelTestBench.weightBytes + LocalModelMemoryGuard.admissionHeadroomBytes
            let refused = [
                LocalModelMemoryReading(pressure: .normal, availableBytes: needed - 1),
                LocalModelMemoryReading(pressure: .warning, availableBytes: 64 << 30),
            ]

            for reading in refused {
                bench.probe.reading = reading
                let end = await bench.end(helper)
                XCTAssertEqual(end, .outcome(.lowMemory(reading)))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawned.path))

            bench.probe.reading = LocalModelMemoryReading(pressure: .normal, availableBytes: needed)
            let end = await bench.end(helper)
            XCTAssertEqual(end, .written("Protocol"))
        }

        func testWatchdogEndsARunningHelperOnWarningPressureOrBelowTheFloor() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let started = bench.scratch.appendingPathComponent("started")
            let helper = try bench.helper("trap 'exit 13' TERM; echo $$ > '\(started.path)'; while :; do sleep 0.05; done")
            let floor = LocalModelMemoryGuard.terminationFloorBytes
            let readings = [
                LocalModelMemoryReading(pressure: .warning, availableBytes: 64 << 30),
                LocalModelMemoryReading(pressure: .normal, availableBytes: floor - 1),
            ]

            for reading in readings {
                bench.probe.reading = .plenty
                try? FileManager.default.removeItem(at: started)
                let task = Task { await bench.end(helper) }
                _ = try await bench.pid(writtenTo: started)
                let stops = bench.diagnostics.lines(.notice, startingWith: "local_model_stopping").count
                // Exactly at the floor, at normal pressure, the helper keeps running.
                bench.probe.reading = LocalModelMemoryReading(pressure: .normal, availableBytes: floor)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(bench.diagnostics.lines(.notice, startingWith: "local_model_stopping").count, stops)

                bench.probe.reading = reading
                let end = await task.value

                XCTAssertEqual(end, .outcome(.lowMemory(reading)))
            }
        }

        func testRecordingEndsTheHelperAndDeferredJobsResumeInTheirOrder() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let (started, events) = (bench.scratch.appendingPathComponent("started"), bench.scratch.appendingPathComponent("events"))
            let slow = try bench.helper("trap 'exit 13' TERM; echo $$ > '\(started.path)'; while :; do sleep 0.05; done")
            let firstAgain = try bench.helper(#"echo first >> '\#(events.path)'; printf 'first' > "$out""#)
            let secondHelper = try bench.helper(#"echo second >> '\#(events.path)'; printf 'second' > "$out""#)
            let (first, second) = (UUID(), UUID())
            let deferred = Task { await LocalModelGate.$jobID.withValue(first) { await bench.end(slow) } }
            _ = try await bench.pid(writtenTo: started)

            bench.gate.setRecordingActive(true)
            let deferredEnd = await deferred.value
            XCTAssertEqual(deferredEnd, .outcome(.deferredForRecording))

            // Nothing is admitted while the recording runs; the deferred job,
            // back after a later one arrived, still goes first.
            let later = Task { await LocalModelGate.$jobID.withValue(second) { await bench.end(secondHelper) } }
            try await bench.waitForNotices("local_model_waiting", count: 1)
            let retry = Task { await LocalModelGate.$jobID.withValue(first) { await bench.end(firstAgain) } }
            try await bench.waitForNotices("local_model_waiting", count: 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: events.path))
            bench.gate.setRecordingActive(false)
            let ends = await [retry.value, later.value]

            XCTAssertEqual(ends, [.written("first"), .written("second")])
            XCTAssertEqual(try bench.contents(of: events), "first\nsecond\n")
        }

        func testQuitEndsTheHelperWithinTheQuitGrace() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGate"))
            let started = bench.scratch.appendingPathComponent("started")
            let stubborn = try bench.helper("trap '' TERM; echo $$ > '\(started.path)'; exec sleep 30")
            let task = Task { await bench.end(stubborn) }
            let pid = try await bench.pid(writtenTo: started)

            let quitAt = ContinuousClock.now
            bench.gate.terminateForQuit()
            let blocked = ContinuousClock.now - quitAt
            let end = await task.value

            XCTAssertLessThan(blocked, LocalModelLimits.fast().quitGrace + .seconds(1))
            XCTAssertEqual(end, .cancelled)
            XCTAssertNotEqual(kill(pid, 0), 0, "the helper still runs")
        }
    }

#endif
