#if !APPSTORE

    import AppKit
    @testable import MeetingTranscriber
    import XCTest

    /// The gate wired into everything that runs a local generation (spec R6,
    /// R10): the queue and the speaker-naming paths share one helper at a
    /// time, a job's cancel reaches only the helper that job owns, a
    /// regeneration runs as its meeting's job, and quitting the app ends the
    /// helper. Fake helpers throughout (`LocalModelTestBench`).
    @MainActor
    final class LocalModelGateWiringTests: XCTestCase {
        private let failureWarning = "Protocol generation failed — transcript saved"

        func testTwoNamingConfirmationsAndAQueuedProtocolNeverRunTwoHelpers() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelWiring"))
            let events = bench.scratch.appendingPathComponent("events")
            let helper = try bench.helper("""
            echo start >> '\(events.path)'
            sleep 0.2
            echo end >> '\(events.path)'
            printf '\(LocalModelPipelineBench.protocolText)' > "$out"
            """)
            let pipeline = try LocalModelPipelineBench(bench, helper: helper)
            let first = try await pipeline.jobAtSpeakerNaming(title: "First")
            let second = try await pipeline.jobAtSpeakerNaming(title: "Second")

            pipeline.confirm(first, as: "Alice")
            pipeline.confirm(second, as: "Bob")
            let queued = try pipeline.enqueue(title: "Queued")
            try await pipeline.waitUntilDone([first, second, queued])

            XCTAssertEqual(try bench.contents(of: events), String(repeating: "start\nend\n", count: 3), "two helpers overlapped")
            for id in [first, second, queued] {
                XCTAssertNotNil(pipeline.job(id)?.protocolPath, "no protocol for one of the three jobs")
            }
        }

        func testCancellingANamingJobEndsItsHelperAndLeavesTheQueuedJobAlone() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelWiring"))
            let run = try bench.blockingOnceHelper()
            let pipeline = try LocalModelPipelineBench(bench, helper: run.helper)
            let named = try await pipeline.jobAtSpeakerNaming(title: "Named")
            pipeline.confirm(named, as: "Alice")
            let pid = try await bench.pid(writtenTo: run.started)
            let queued = try pipeline.enqueue(title: "Queued")
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(queued))", count: 1)

            pipeline.queue.cancelJob(id: named)

            try await waitUntil("the cancelled job's helper to end") { kill(pid, 0) != 0 }
            try await pipeline.waitUntilDone([queued])
            XCTAssertNil(pipeline.job(named), "the cancelled job is still queued")
            let other = try XCTUnwrap(pipeline.job(queued))
            XCTAssertNotNil(other.protocolPath)
            XCTAssertFalse(other.warnings.contains(failureWarning), "the other job's generation failed: \(other.warnings)")
        }

        /// The naming task's cancel must not reach the queue's own run either:
        /// cancelling the queue's processing task there would end the helper of
        /// the job that runs, which is not the job cancelled.
        func testCancellingAJobThatDoesNotOwnTheHelperLeavesItRunning() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelWiring"))
            let (started, release) = (bench.scratch.appendingPathComponent("started"), bench.scratch.appendingPathComponent("release"))
            let helper = try bench.helper("""
            echo $$ > '\(started.path)'
            while [ ! -e '\(release.path)' ]; do sleep 0.05; done
            printf '\(LocalModelPipelineBench.protocolText)' > "$out"
            """)
            let pipeline = try LocalModelPipelineBench(bench, helper: helper)
            let named = try await pipeline.jobAtSpeakerNaming(title: "Named")
            let running = try pipeline.enqueue(title: "Running")
            let pid = try await bench.pid(writtenTo: started)
            pipeline.confirm(named, as: "Alice")
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(named))", count: 1)

            pipeline.queue.cancelJob(id: named)
            try await Task.sleep(for: .milliseconds(300))

            XCTAssertEqual(kill(pid, 0), 0, "another job's cancel ended this helper")
            XCTAssertEqual(bench.gate.ownerJobID, running)
            try Data().write(to: release)
            try await pipeline.waitUntilDone([running])
            XCTAssertNotNil(pipeline.job(running)?.protocolPath)
            XCTAssertEqual(bench.diagnostics.lines(.notice, startingWith: "local_model_started").count, 1, "the cancelled job started a helper")
        }

        func testRegenerationRunsAsItsMeetingsJob() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelWiring"))
            let (started, release) = (bench.scratch.appendingPathComponent("started"), bench.scratch.appendingPathComponent("release"))
            let helper = try bench.helper("""
            echo $$ > '\(started.path)'
            while [ ! -e '\(release.path)' ]; do sleep 0.05; done
            printf '\(LocalModelPipelineBench.protocolText)' > "$out"
            """)
            let (folder, templates) = (bench.scratch.appendingPathComponent("meeting"), bench.scratch.appendingPathComponent("templates"))
            for directory in [folder, templates] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let basename = "20261015_0900_standup"
            try Data("Alice: hello".utf8).write(to: folder.appendingPathComponent("\(basename).txt"))
            let jobID = UUID()
            let target = ProtocolRegenerationTarget(
                folder: folder, basename: basename, title: "Standup", meetingStartTime: nil, jobID: jobID.uuidString,
                files: ProtocolRegenerationTarget.readFiles(folder: folder, basename: basename) { try? Data(contentsOf: $0) },
            )
            let generator = bench.generator(helper: helper)
            let regenerator = ProtocolRegenerator(environment: .init(
                generatorFactory: { generator },
                templateStore: ProtocolTemplateStore(directory: templates),
                includeFullTranscript: { false },
                recordOnly: { false },
                queuedJobs: { [] },
                records: { [] },
                outputDir: { folder },
                notifier: RecordingNotifier(),
                fileOperations: .live,
                now: Date.init,
            ))
            let regeneration = Task {
                await regenerator.regenerate(target, options: MeetingProtocolOptions(template: .builtIn, rawBackground: ""))
            }
            _ = try await bench.pid(writtenTo: started)

            XCTAssertEqual(bench.gate.ownerJobID, jobID)
            try Data().write(to: release)
            await regeneration.value
            XCTAssertEqual(regenerator.phase, .succeeded(target.protocolURL, warnings: []))
        }

        /// The observer runs inside the notification's delivery, before
        /// `terminate` would call `exit`: the post itself blocks until the
        /// helper, which ignores SIGTERM, is killed after the quit grace.
        func testQuitEndsTheRunningHelperBeforeTheAppExits() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelWiring"))
            let started = bench.scratch.appendingPathComponent("started")
            let stubborn = try bench.helper("trap '' TERM; echo $$ > '\(started.path)'; exec sleep 30")
            let center = NotificationCenter()
            AppState.endLocalModelOnQuit(bench.gate, center: center)
            let generation = Task { await bench.end(stubborn) }
            let pid = try await bench.pid(writtenTo: started)

            let quitAt = ContinuousClock.now
            center.post(name: NSApplication.willTerminateNotification, object: nil)
            let blocked = ContinuousClock.now - quitAt
            let end = await generation.value

            XCTAssertGreaterThanOrEqual(blocked, LocalModelLimits.fast().quitGrace, "the post returned before the helper was ended")
            XCTAssertLessThan(blocked, LocalModelLimits.fast().quitGrace + .seconds(1))
            XCTAssertEqual(end, .cancelled)
            XCTAssertNotEqual(kill(pid, 0), 0, "the helper still runs")
        }
    }

    // MARK: - Shared with LocalModelRecordingPreemptionTests

    extension LocalModelTestBench {
        /// The local generator over this bench's gate and model folder, with `helper`.
        func generator(helper: URL) -> LocalModelProtocolGenerator {
            LocalModelProtocolGenerator(
                folder: LocalModelFolderSelection(path: modelFolder.path, bookmark: nil),
                language: Self.language,
                gate: gate,
            ) { helper }
        }

        /// A helper whose first run blocks until it is ended, its pid in
        /// `started`, and whose later runs write a protocol. Every run first
        /// appends to `events` whose transcript it was given: `A` for one
        /// naming Alice, `B` for Bob, `-` for any other.
        func blockingOnceHelper() throws -> (helper: URL, started: URL, events: URL) {
            let (block, started, events) = (
                scratch.appendingPathComponent("block"),
                scratch.appendingPathComponent("started"),
                scratch.appendingPathComponent("events"),
            )
            try Data().write(to: block)
            let url = try helper("""
            case "$req" in *Alice*) who=A ;; *Bob*) who=B ;; *) who=- ;; esac
            echo "$who" >> '\(events.path)'
            if [ -e '\(block.path)' ]; then
              rm '\(block.path)'
              trap 'exit 13' TERM
              echo $$ > '\(started.path)'
              while :; do sleep 0.05; done
            fi
            printf '\(LocalModelPipelineBench.protocolText)' > "$out"
            """)
            return (url, started, events)
        }
    }

    /// A pipeline queue whose protocols a bench's gate writes with one fake
    /// helper, over a mock engine and diarizer. Every transcript says "Hello
    /// world"; a job parked at speaker naming gets its speaker's name from the
    /// confirmation, which is how a helper tells two jobs apart.
    @MainActor
    final class LocalModelPipelineBench {
        static let protocolText = "Written by the fake helper"

        let engine: MockEngine
        let queue: PipelineQueue
        let outputDir: URL
        let logDir: URL
        private let diarization: MockDiarization
        private let scratch: URL

        init(_ bench: LocalModelTestBench, helper: URL, outputDir: URL? = nil, logDir: URL? = nil) throws {
            scratch = bench.scratch
            let outputDir = outputDir ?? bench.scratch.appendingPathComponent("output", isDirectory: true)
            let logDir = logDir ?? bench.scratch.appendingPathComponent("log", isDirectory: true)
            let staging = bench.scratch.appendingPathComponent("staging", isDirectory: true)
            let templates = bench.scratch.appendingPathComponent("templates", isDirectory: true)
            for folder in [outputDir, logDir, staging, templates] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let (engine, diarization, generator) = (MockEngine(), MockDiarization(), bench.generator(helper: helper))
            engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
            (self.engine, self.diarization, self.outputDir, self.logDir) = (engine, diarization, outputDir, logDir)
            queue = PipelineQueue(
                engine: engine,
                diarizationFactory: { diarization },
                protocolGeneratorFactory: { generator },
                outputDir: outputDir,
                logDir: logDir,
                stagingDir: staging,
                diarizeEnabled: true,
                protocolTemplateStore: ProtocolTemplateStore(directory: templates),
                inFlightRuns: InFlightRunRegistry(),
            )
        }

        /// Enqueues a job that runs straight through to its protocol.
        func enqueue(title: String) throws -> UUID {
            try enqueue(title: title, withEmbedding: false)
        }

        /// Enqueues a job and returns once it waits for its speaker's name: an
        /// unknown voice with an embedding parks it there.
        func jobAtSpeakerNaming(title: String) async throws -> UUID {
            let id = try enqueue(title: title, withEmbedding: true)
            try await waitUntil("\(title) at speaker naming") { job(id)?.state == .speakerNamingPending }
            return id
        }

        func confirm(_ id: UUID, as name: String) {
            queue.completeSpeakerNaming(jobID: id, result: .confirmed(["SPEAKER_0": name]), source: .dialog)
        }

        func job(_ id: UUID) -> PipelineJob? {
            queue.jobs.first { $0.id == id }
        }

        func waitUntilDone(_ ids: [UUID]) async throws {
            try await waitUntil("\(ids.count) job(s) done") { ids.allSatisfy { job($0)?.state == .done } }
        }

        /// The diarization is read when the job reaches that stage, so a caller
        /// enqueueing another job afterwards first waits for this one's.
        private func enqueue(title: String, withEmbedding: Bool) throws -> UUID {
            diarization.resultToReturn = Self.diarization(withEmbedding: withEmbedding)
            let job = try PipelineJob(
                meetingTitle: title, appName: "Teams",
                mixPath: createTestAudioFile(in: scratch), appPath: nil, micPath: nil, micDelay: 0,
            )
            queue.enqueue(job)
            return job.id
        }

        private static func diarization(withEmbedding: Bool) -> DiarizationResult {
            DiarizationResult(
                segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
                speakingTimes: ["SPEAKER_0": 5],
                autoNames: [:],
                embeddings: withEmbedding ? ["SPEAKER_0": [1, 0, 0]] : nil,
            )
        }
    }

    /// Polls `condition` every 10 ms until it holds, or throws after 15 s.
    @MainActor
    func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LocalModelBenchTimeout(waitingFor: what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

#endif
