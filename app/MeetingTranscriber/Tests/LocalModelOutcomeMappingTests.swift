#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// What each local outcome leaves a job with (spec R11), and the notices
    /// the pipeline posts for them (spec R4, R5, R8), through the controller's
    /// own callbacks: a fake provider plays each outcome, a spy notifier or the
    /// real one over a fake scheduler records what the person is told.
    @MainActor
    final class LocalModelOutcomeMappingTests: XCTestCase {
        private let failureWarning = "Protocol generation failed — transcript saved"
        private let lowMemory = LocalModelMemoryReading(pressure: .warning, availableBytes: 1 << 30)

        private struct Expectation {
            let outcome: LocalModelOutcome
            let warning: String
            /// The notification the job's end posts; nil when a notice replaces it.
            let doneTitle: String?
            let shortfall: LocalModelNotice.Shortfall?
        }

        func testEachLocalOutcomeEndsTheJobAsR11Says() async throws {
            let (incomplete, short) = (LocalModelNotice.incompleteWarning, LocalModelNotice.Shortfall.self)
            let expectations = [
                Expectation(outcome: .incomplete(text: "Partial minutes"), warning: incomplete, doneTitle: "Protocol Ready", shortfall: nil),
                Expectation(outcome: .lowMemory(lowMemory), warning: short.lowMemory.warning, doneTitle: nil, shortfall: .lowMemory),
                Expectation(outcome: .noModel, warning: short.noModel.warning, doneTitle: nil, shortfall: .noModel),
                Expectation(outcome: .promptTooLong, warning: failureWarning, doneTitle: "Transcript Saved", shortfall: nil),
                Expectation(outcome: .deadline(.noProgress), warning: failureWarning, doneTitle: "Transcript Saved", shortfall: nil),
                Expectation(outcome: .failure(.signal(SIGKILL)), warning: failureWarning, doneTitle: "Transcript Saved", shortfall: nil),
            ]
            for expected in expectations {
                let notifier = LocalModelNoticeSpy()
                let bench = try makeBench(notifier: notifier, outcome: .failure(expected.outcome))
                let id = try bench.enqueue(title: "Weekly")
                try await bench.waitUntilDone([id])

                let job = try XCTUnwrap(bench.job(id), "\(expected.outcome)")
                XCTAssertEqual(job.warnings, [expected.warning], "\(expected.outcome)")
                let transcript = try XCTUnwrap(job.transcriptPath, "\(expected.outcome)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), "\(expected.outcome): transcript not kept")
                XCTAssertEqual(notifier.notifications.map(\.title), expected.doneTitle.map { [$0] } ?? [], "\(expected.outcome)")
                if case let .incomplete(text) = expected.outcome {
                    let written = try String(contentsOf: XCTUnwrap(job.protocolPath), encoding: .utf8)
                    XCTAssertTrue(written.contains(text), "the incomplete protocol was not saved")
                    XCTAssertEqual(notifier.episodeEnds, 1, "an incomplete protocol is a written one")
                } else {
                    XCTAssertNil(job.protocolPath, "\(expected.outcome)")
                    XCTAssertEqual(notifier.episodeEnds, 0, "\(expected.outcome)")
                }
                XCTAssertEqual(notifier.notices.map(\.shortfall), expected.shortfall.map { [$0] } ?? [], "\(expected.outcome)")
                if let shortfall = expected.shortfall {
                    let meeting = try XCTUnwrap(notifier.notices.first?.meeting)
                    XCTAssertEqual(notifier.notices.first, .notWritten(shortfall, meeting))
                    XCTAssertEqual(meeting.jobID, id)
                    XCTAssertEqual(meeting.title, "Weekly")
                    XCTAssertEqual(meeting.transcriptURL.path, transcript.path)
                }
            }
        }

        func testAProviderThatIsNotLocalKeepsTheGenericFailure() async throws {
            let notifier = LocalModelNoticeSpy()
            let bench = try makeBench(notifier: notifier, outcome: .failure(ProtocolError.emptyProtocol))
            let id = try bench.enqueue(title: "Weekly")
            try await bench.waitUntilDone([id])

            XCTAssertEqual(bench.job(id)?.warnings, [failureWarning])
            XCTAssertEqual(notifier.notifications.map(\.title), ["Transcript Saved"])
            XCTAssertTrue(notifier.notices.isEmpty)
        }

        func testASpeakerNamingConfirmationHandlesTheOutcomeLikeTheQueue() async throws {
            let notifier = LocalModelNoticeSpy()
            let bench = try makeBench(notifier: notifier, outcome: .failure(LocalModelOutcome.lowMemory(lowMemory)))
            let id = try await bench.jobAtSpeakerNaming(title: "Review")
            bench.confirm(id, as: "Alice")
            try await bench.waitUntilDone([id])

            XCTAssertEqual(bench.job(id)?.warnings, [LocalModelNotice.Shortfall.lowMemory.warning])
            XCTAssertNil(bench.job(id)?.protocolPath)
            XCTAssertEqual(notifier.notices.map(\.shortfall), [.lowMemory])
            XCTAssertEqual(notifier.notices.first?.meeting?.jobID, id)
            XCTAssertFalse(notifier.notifications.map(\.title).contains("Transcript Saved"))
        }

        /// The acceptance case: one episode, three jobs, one notification on
        /// screen naming all three, and no "Transcript Saved" beside it.
        func testThreeQueuedJobsShortOfMemoryRaiseOneNotification() async throws {
            let scheduler = FakeNotificationScheduler()
            let manager = NotificationManager(scheduler: scheduler) { true }
            manager.setUp()
            let bench = try makeBench(notifier: manager, outcome: .failure(LocalModelOutcome.lowMemory(lowMemory)))
            var ids: [UUID] = []
            for title in ["First", "Second", "Third"] {
                try ids.append(bench.enqueue(title: title))
            }
            try await bench.waitUntilDone(ids)

            XCTAssertEqual(Set(scheduler.added.map(\.identifier)).count, 1, "\(scheduler.added.map(\.identifier))")
            let shown = try XCTUnwrap(scheduler.added.last?.content)
            XCTAssertEqual(shown.categoryIdentifier, NotificationManager.localModelLowMemoryCategoryID)
            XCTAssertEqual(shown.title, "Protocol not written: low memory")
            XCTAssertEqual(
                shown.body,
                "Third and 2 more meetings: there was not enough free memory for the local model. The transcripts are saved.",
            )
            XCTAssertEqual(LocalModelNoticeMeeting.meetings(in: shown.userInfo).map(\.jobID), ids)
            XCTAssertFalse(manager.recentNotifications.contains { $0.title == "Transcript Saved" })
        }

        // MARK: - Paused for a recording (spec R5, A19, A21)

        /// The first deferral of the job's protocol stage tells the person;
        /// the second deferral of the same job tells nothing new.
        func testARecordingPausesTheProtocolWithOneNoticePerStage() async throws {
            let (bench, release, helper) = try blockingHelperBench()
            let pipeline = try LocalModelPipelineBench(bench, helper: helper)
            let notifier = LocalModelNoticeSpy()
            try install(notifier, on: pipeline)
            let id = try pipeline.enqueue(title: "Standup")

            for round in 1 ... 2 {
                try await bench.waitForNotices("local_model_started", count: round)
                bench.gate.setRecordingActive(true)
                try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(id)) reason=recording", count: round)
                XCTAssertEqual(notifier.notices, [.paused(jobID: id, title: "Standup")], "round \(round)")
                bench.gate.setRecordingActive(false)
            }
            try await bench.waitForNotices("local_model_started", count: 3)
            try Data().write(to: release)
            try await pipeline.waitUntilDone([id])

            XCTAssertEqual(notifier.notices, [.paused(jobID: id, title: "Standup")])
            XCTAssertEqual(notifier.notifications.map(\.title), ["Protocol Ready"])
            XCTAssertEqual(notifier.episodeEnds, 1)
        }

        /// Record-only mode holds the gate like a recording (A19) but posts
        /// no notice (A21): the job waits in its protocol state.
        func testARecordOnlyHoldPostsNoNotice() async throws {
            let (bench, release, helper) = try blockingHelperBench()
            let pipeline = try LocalModelPipelineBench(bench, helper: helper)
            let notifier = LocalModelNoticeSpy()
            let settings = try install(notifier, on: pipeline)
            let id = try pipeline.enqueue(title: "Standup")
            try await bench.waitForNotices("local_model_started", count: 1)

            settings.recordOnly = true
            bench.gate.setRecordingActive(true)
            try await bench.waitForNotices("local_model_waiting \(LocalModelGate.logTag(id)) reason=recording", count: 1)
            XCTAssertEqual(pipeline.job(id)?.state, .generatingProtocol)

            try Data().write(to: release)
            settings.recordOnly = false
            bench.gate.setRecordingActive(false)
            try await pipeline.waitUntilDone([id])
            XCTAssertEqual(notifier.notices, [])
        }

        // MARK: - Helpers

        private func makeSettings() throws -> AppSettings {
            let suite = "LocalModelOutcomeMappingTests-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            return try AppSettings(
                defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
                defaultOutputDir: makeTempDirectory(prefix: "LocalModelOutcomeOutput"),
            )
        }

        private func makeBench(notifier: any AppNotifying, outcome: Result<String, any Error>) throws -> LocalModelOutcomeBench {
            try LocalModelOutcomeBench(
                scratch: makeTempDirectory(prefix: "LocalModelOutcome"), settings: makeSettings(), notifier: notifier,
                generator: OutcomeProtocolGenerator(outcome),
            )
        }

        /// The controller's callbacks over `pipeline`'s queue, posting to `notifier`.
        @discardableResult
        private func install(_ notifier: any AppNotifying, on pipeline: LocalModelPipelineBench) throws -> AppSettings {
            let settings = try makeSettings()
            let controller = PipelineController(
                settings: settings, notifier: notifier,
                queueEnvironment: IsolatedQueueEnvironment.make(logDir: pipeline.logDir, initialQueue: pipeline.queue),
            )
            controller.configureCallbacks()
            return settings
        }

        /// A bench whose helper blocks on every run until `release` exists.
        private func blockingHelperBench() throws -> (LocalModelTestBench, URL, URL) {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelOutcome"))
            let release = bench.scratch.appendingPathComponent("release")
            let helper = try bench.helper("""
            trap 'exit 13' TERM
            while [ ! -e '\(release.path)' ]; do sleep 0.05; done
            printf '\(LocalModelPipelineBench.protocolText)' > "$out"
            """)
            return (bench, release, helper)
        }
    }

    // MARK: - Shared with the other local-model notice suites

    /// Records the notifications and local-model notices it is given.
    final class LocalModelNoticeSpy: AppNotifying {
        private(set) var notifications: [(title: String, body: String)] = []
        private(set) var notices: [LocalModelNotice] = []
        private(set) var episodeEnds = 0
        private(set) weak var responder: (any LocalModelNoticeResponding)?

        func notify(title: String, body: String, urgency _: NotificationUrgency) {
            notifications.append((title: title, body: body))
        }

        func postLocalModelNotice(_ notice: LocalModelNotice) {
            notices.append(notice)
        }

        func endLocalModelNoticeEpisodes() {
            episodeEnds += 1
        }

        func setLocalModelNoticeResponder(_ responder: any LocalModelNoticeResponding) {
            self.responder = responder
        }
    }

    extension LocalModelNotice {
        var shortfall: Shortfall? {
            if case let .notWritten(shortfall, _) = self { return shortfall }
            return nil
        }

        var meeting: LocalModelNoticeMeeting? {
            if case let .notWritten(_, meeting) = self { return meeting }
            return nil
        }
    }

    /// A provider that ends every generation with `result`: this text, or this error.
    final class OutcomeProtocolGenerator: ProtocolGenerating {
        private let result: Result<String, any Error>

        init(_ result: Result<String, any Error>) {
            self.result = result
        }

        func generate(
            transcript _: String,
            title _: String,
            diarized _: Bool,
            meetingStartTime _: Date?,
            instructions _: ProtocolInstructions,
        ) throws -> String {
            try result.get()
        }
    }

    /// A pipeline queue whose protocols `generator` writes, over a mock engine
    /// and diarizer, with the controller's callbacks posting to `notifier`.
    @MainActor
    final class LocalModelOutcomeBench {
        let queue: PipelineQueue
        private let diarization: MockDiarization
        private let scratch: URL

        init(scratch: URL, settings: AppSettings, notifier: any AppNotifying, generator: OutcomeProtocolGenerator) throws {
            self.scratch = scratch
            let (outputDir, logDir, staging, templates) = (
                scratch.appendingPathComponent("output", isDirectory: true),
                scratch.appendingPathComponent("log", isDirectory: true),
                scratch.appendingPathComponent("staging", isDirectory: true),
                scratch.appendingPathComponent("templates", isDirectory: true),
            )
            for folder in [outputDir, logDir, staging, templates] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let engine = MockEngine()
            engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
            let diarization = MockDiarization()
            self.diarization = diarization
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
            // The callbacks it installs on the queue outlive the controller.
            PipelineController(
                settings: settings, notifier: notifier,
                queueEnvironment: IsolatedQueueEnvironment.make(logDir: logDir, initialQueue: queue),
            ).configureCallbacks()
        }

        func enqueue(title: String) throws -> UUID {
            try enqueue(title: title, withEmbedding: false)
        }

        /// An unknown voice with an embedding parks the job at speaker naming.
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

        private func enqueue(title: String, withEmbedding: Bool) throws -> UUID {
            diarization.resultToReturn = DiarizationResult(
                segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
                speakingTimes: ["SPEAKER_0": 5],
                autoNames: [:],
                embeddings: withEmbedding ? ["SPEAKER_0": [1, 0, 0]] : nil,
            )
            let job = try PipelineJob(
                meetingTitle: title, appName: "Teams",
                mixPath: createTestAudioFile(in: scratch), appPath: nil, micPath: nil, micDelay: 0,
            )
            queue.enqueue(job)
            return job.id
        }
    }

#endif
