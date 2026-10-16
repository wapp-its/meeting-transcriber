#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// A regeneration with the local model (spec R11) reports each local
    /// outcome as its own result, does not start while a recording runs and is
    /// not resumed after one ended it; Try Again on a notice (spec R4) is such
    /// a regeneration of that one meeting.
    @MainActor
    final class ProtocolRegenerationLocalModelTests: XCTestCase {
        private let basename = "20261016_0900_Standup"
        private let transcriptText = "Alice: the budget is final"

        func testEachLocalOutcomeIsTheRegenerationsOwnResult() async throws {
            let reading = LocalModelMemoryReading(pressure: .critical, availableBytes: 0)
            let failures: [(LocalModelOutcome, ProtocolRegenerationError)] = [
                (.lowMemory(reading), .lowMemory),
                (.noModel, .noLocalModel),
                (.deferredForRecording, .recording),
                (.promptTooLong, .generationFailed),
                (.deadline(.total), .generationFailed),
                (.failure(.helperMissing), .generationFailed),
            ]
            for (outcome, error) in failures {
                let world = try makeWorld()
                let notifier = LocalModelNoticeSpy()
                let regenerator = makeRegenerator(world, notifier: notifier) { OutcomeProtocolGenerator(.failure(outcome)) }
                try await regenerator.regenerate(world.target(), options: MeetingProtocolOptions(template: .builtIn, rawBackground: ""))

                let reason = try XCTUnwrap(error.errorDescription)
                XCTAssertEqual(regenerator.phase, .failed(reason), "\(outcome)")
                XCTAssertEqual(notifier.notifications.map(\.body), ["Standup: \(reason)"], "\(outcome)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: world.protocolFile.path), "\(outcome)")
            }
            XCTAssertEqual(ProtocolRegenerator.regenerationError(for: .deferredForRecording, recordOnly: true), .recordOnly)
        }

        func testAnIncompleteLocalProtocolIsSavedAndFlagged() async throws {
            let world = try makeWorld()
            let notifier = LocalModelNoticeSpy()
            let regenerator = makeRegenerator(world, notifier: notifier) {
                OutcomeProtocolGenerator(.failure(LocalModelOutcome.incomplete(text: "Partial minutes")))
            }
            try await regenerator.regenerate(world.target(), options: MeetingProtocolOptions(template: .builtIn, rawBackground: ""))

            XCTAssertEqual(regenerator.phase, try .succeeded(world.target().protocolURL, warnings: [LocalModelNotice.incompleteWarning]))
            XCTAssertTrue(try String(contentsOf: world.protocolFile, encoding: .utf8).contains("Partial minutes"))
            XCTAssertEqual(notifier.episodeEnds, 1)
        }

        /// Pressed during a recording, Try Again is refused with a visible
        /// reason and no helper starts; once the recording has ended it runs,
        /// and the local protocol it writes ends the notice episodes.
        func testTryAgainDuringARecordingIsRefusedAndRunsOnceItHasEnded() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelRegeneration"))
            let events = bench.scratch.appendingPathComponent("events")
            let helper = try bench.helper(#"echo run >> '\#(events.path)'; printf 'Local minutes' > "$out""#)
            let world = try makeWorld()
            let notifier = LocalModelNoticeSpy()
            let regenerator = makeRegenerator(world, notifier: notifier) { bench.generator(helper: helper) }

            bench.gate.setRecordingActive(true)
            let refused = await regenerator.tryAgain(world.meeting())
            let reason = try XCTUnwrap(ProtocolRegenerationError.recording.errorDescription)
            XCTAssertTrue(refused, "a refusal is an answer, not missing files")
            XCTAssertEqual(regenerator.phase, .failed(reason))
            XCTAssertEqual(notifier.notifications.map(\.title), [ProtocolRegenerator.failedTitle])
            XCTAssertFalse(FileManager.default.fileExists(atPath: events.path), "a helper started during the recording")

            bench.gate.setRecordingActive(false)
            _ = await regenerator.tryAgain(world.meeting())
            XCTAssertEqual(regenerator.phase, try .succeeded(world.target().protocolURL, warnings: []))
            XCTAssertEqual(notifier.episodeEnds, 1)
        }

        func testARecordingThatEndsTheHelperEndsTheRegenerationWithoutResumingIt() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelRegeneration"))
            let run = try bench.blockingOnceHelper()
            let world = try makeWorld()
            let regenerator = makeRegenerator(world, notifier: LocalModelNoticeSpy()) { bench.generator(helper: run.helper) }
            let regeneration = Task {
                try await regenerator.regenerate(world.target(), options: MeetingProtocolOptions(template: .builtIn, rawBackground: ""))
            }
            _ = try await bench.pid(writtenTo: run.started)

            bench.gate.setRecordingActive(true)
            try await regeneration.value
            bench.gate.setRecordingActive(false)
            try await Task.sleep(for: .milliseconds(300))

            XCTAssertEqual(regenerator.phase, try .failed(XCTUnwrap(ProtocolRegenerationError.recording.errorDescription)))
            XCTAssertEqual(bench.diagnostics.lines(.notice, startingWith: "local_model_started").count, 1, "the regeneration was resumed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.protocolFile.path))
        }

        /// The notice's Try Again, through the notification manager the
        /// regenerator registers with: only the protocol of that meeting is
        /// made, from its saved transcript, with its template and background.
        func testTryAgainOnANoticeMakesThatMeetingsProtocolWithItsTemplateAndBackground() async throws {
            let world = try makeWorld()
            try Data("Board minutes in {LANGUAGE}.".utf8).write(to: world.templates.appendingPathComponent("Board.md"))
            let manager = NotificationManager(scheduler: FakeNotificationScheduler()) { true }
            let generator = MockProtocolGen()
            let regenerator = makeRegenerator(world, notifier: manager) { generator }
            let meeting = world.meeting(template: .file(name: "Board"), background: "Budget cut for team X")
            manager.postLocalModelNotice(.notWritten(.lowMemory, meeting))

            await manager.respond(
                toCategory: NotificationManager.localModelLowMemoryCategoryID, requestID: "any",
                actionID: NotificationManager.localModelTryAgainActionID, userInfo: LocalModelNoticeMeeting.userInfo(for: [meeting]),
            )

            XCTAssertEqual(regenerator.phase, try .succeeded(world.target().protocolURL, warnings: []))
            XCTAssertEqual(generator.capturedTranscript, transcriptText)
            XCTAssertEqual(generator.capturedInstructions, ProtocolInstructions(template: "Board minutes in {LANGUAGE}.", background: "Budget cut for team X"))
            XCTAssertEqual(try String(contentsOf: world.transcriptFile, encoding: .utf8), transcriptText, "the transcript was rewritten")
        }

        /// Try Again while another protocol is being made is refused with its
        /// reason; that is an answer, so the notice does not fall back to the
        /// transcript.
        func testTryAgainWhileAnotherProtocolIsBeingMadeIsRefused() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelRegeneration"))
            let run = try bench.blockingOnceHelper()
            let world = try makeWorld()
            let notifier = LocalModelNoticeSpy()
            let regenerator = makeRegenerator(world, notifier: notifier) { bench.generator(helper: run.helper) }
            let regeneration = Task {
                try await regenerator.regenerate(world.target(), options: MeetingProtocolOptions(template: .builtIn, rawBackground: ""))
            }
            _ = try await bench.pid(writtenTo: run.started)

            let answered = await regenerator.tryAgain(world.meeting())

            let reason = try XCTUnwrap(ProtocolRegenerationError.regenerationRunning.errorDescription)
            XCTAssertTrue(answered)
            XCTAssertEqual(notifier.notifications.map(\.body), ["Standup: \(reason)"])
            bench.gate.setRecordingActive(true)
            try await regeneration.value
        }

        func testTryAgainIsRefusedInRecordOnlyMode() async throws {
            let world = try makeWorld()
            let notifier = LocalModelNoticeSpy()
            let generator = MockProtocolGen()
            let regenerator = makeRegenerator(world, notifier: notifier, recordOnly: true) { generator }

            let answered = await regenerator.tryAgain(world.meeting())

            XCTAssertTrue(answered)
            XCTAssertEqual(regenerator.phase, try .failed(XCTUnwrap(ProtocolRegenerationError.recordOnly.errorDescription)))
            XCTAssertFalse(generator.generateCalled)
            XCTAssertEqual(notifier.notifications.map(\.title), [ProtocolRegenerator.failedTitle])
        }

        func testTryAgainAnswersFalseWhenTheMeetingsFilesAreGone() async throws {
            let world = try makeWorld()
            try FileManager.default.removeItem(at: world.transcriptFile)
            let regenerator = makeRegenerator(world, notifier: LocalModelNoticeSpy()) { MockProtocolGen() }

            let answered = await regenerator.tryAgain(world.meeting())

            XCTAssertFalse(answered)
            XCTAssertEqual(regenerator.phase, .idle)
        }

        /// After a restart the notice still names the meeting, but its
        /// background info is gone with the process that held it.
        func testTryAgainAfterARestartSaysTheBackgroundWasNotUsed() async throws {
            let world = try makeWorld()
            let generator = MockProtocolGen()
            let regenerator = makeRegenerator(world, notifier: LocalModelNoticeSpy()) { generator }
            let posted = world.meeting(template: .builtIn, background: "Budget cut for team X")
            let readBack = try XCTUnwrap(LocalModelNoticeMeeting.meetings(in: LocalModelNoticeMeeting.userInfo(for: [posted])).first)

            _ = await regenerator.tryAgain(readBack)

            XCTAssertEqual(regenerator.phase, try .succeeded(world.target().protocolURL, warnings: [ProtocolRegenerator.backgroundLostNote]))
            XCTAssertNil(generator.capturedInstructions?.background)
        }

        // MARK: - Helpers

        /// A finished meeting's folder with its transcript, and a template folder.
        private struct World {
            let folder: URL
            let templates: URL
            let basename: String

            var transcriptFile: URL {
                folder.appendingPathComponent("\(basename).txt")
            }

            var protocolFile: URL {
                folder.appendingPathComponent("\(basename).md")
            }

            func target() throws -> ProtocolRegenerationTarget {
                try ProtocolRegenerationTarget.resolve(file: transcriptFile, records: []) { try? Data(contentsOf: $0) }
            }

            func meeting(template: ProtocolTemplateID = .builtIn, background: String? = nil) -> LocalModelNoticeMeeting {
                LocalModelNoticeMeeting(
                    jobID: UUID(), title: "Standup", folder: folder, basename: basename, template: template, background: background,
                )
            }
        }

        private func makeWorld() throws -> World {
            let scratch = try makeTempDirectory(prefix: "LocalModelRegeneration")
            let world = World(
                folder: scratch.appendingPathComponent("meeting", isDirectory: true),
                templates: scratch.appendingPathComponent("templates", isDirectory: true),
                basename: basename,
            )
            for folder in [world.folder, world.templates] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            try Data(transcriptText.utf8).write(to: world.transcriptFile)
            return world
        }

        private func makeRegenerator(
            _ world: World, notifier: any AppNotifying, recordOnly: Bool = false,
            generator: @escaping @MainActor () -> (any ProtocolGenerating)?,
        ) -> ProtocolRegenerator {
            ProtocolRegenerator(environment: .init(
                generatorFactory: generator,
                templateStore: ProtocolTemplateStore(directory: world.templates),
                includeFullTranscript: { false },
                recordOnly: { recordOnly },
                queuedJobs: { [] },
                records: { [] },
                outputDir: { world.folder },
                notifier: notifier,
                fileOperations: .live,
                now: Date.init,
            ))
        }
    }

#endif
