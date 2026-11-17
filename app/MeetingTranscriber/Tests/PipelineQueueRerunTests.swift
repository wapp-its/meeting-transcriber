import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Admitting a finished meeting again (`PipelineQueue.rerunJob`): what the
/// re-run job is rebuilt from, the settings it runs with, the finished job it
/// takes over, and every refusal. `PipelineQueueRerunRunTests` covers the run.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueRerunTests: XCTestCase {
    private func makeFixture() throws -> PipelineQueueRerunFixture {
        try PipelineQueueRerunFixture(tmpDir: makeTempDirectory(prefix: "rerun_admission"))
    }

    // MARK: - The rebuilt job

    func testARerunIsRebuiltFromItsFinishedEntryAndRecordAndQueuesBehindAWaitingImport() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue()
        let start = fixture.meetingStart
        let pause = RecordingPause(startedAt: start.addingTimeInterval(0.1), endedAt: start.addingTimeInterval(60), offsetSeconds: 0.1)
        let tracks = try fixture.makeRecording()
        let meeting = PipelineJob(
            meetingTitle: "Standup", appName: "Microsoft Teams",
            mixPath: tracks.mixPath, appPath: tracks.appPath, micPath: tracks.micPath, micDelay: 0.25,
            micMuteIntervals: [MicMuteInterval(start: 0.1, end: 0.3)], participants: ["Alice", "Bob"],
            meetingStartTime: start, pauses: [pause], protocolTemplate: .file(name: "Board"), protocolBackground: "Budget review",
        )
        try await fixture.finishedMeeting(in: queue, meeting)
        // What an earlier export of the meeting left in the record.
        fixture.store.update(jobID: meeting.id) { record in
            record.runInputs?.notionPageID = "page-1"
            record.runInputs?.notionDatabaseID = "database-1"
        }
        let sources = try fixture.record(meeting.id).rerunSourceTracks
        let waitingImport = try PipelineJob(
            meetingTitle: "Import", appName: "File",
            mixPath: createTestAudioFile(in: fixture.tmpDir), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(waitingImport, origin: .imported)

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)

        XCTAssertEqual(queue.pendingJobs.map(\.id), [waitingImport.id, meeting.id], "the re-run is not behind the waiting import")
        let rerun = try XCTUnwrap(queue.job(withID: meeting.id))
        XCTAssertEqual(rerun.meetingTitle, "Standup")
        XCTAssertEqual(rerun.appName, "Microsoft Teams")
        XCTAssertEqual(rerun.meetingStartTime, start)
        XCTAssertEqual(rerun.participants, ["Alice", "Bob"])
        XCTAssertEqual(rerun.enqueuedAt.timeIntervalSince1970, meeting.enqueuedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(rerun.micDelay, 0.25)
        XCTAssertEqual(rerun.pauses, [pause])
        XCTAssertEqual(rerun.micMuteIntervals, [MicMuteInterval(start: 0.1, end: 0.3)])
        XCTAssertEqual(rerun.protocolTemplate, .file(name: "Board"))
        XCTAssertEqual(rerun.protocolBackground, "Budget review")
        XCTAssertEqual(rerun.notionPageID, "page-1")
        XCTAssertEqual(rerun.notionDatabaseID, "database-1")
        XCTAssertEqual([rerun.mixPath, rerun.appPath, rerun.micPath], [sources.mix, sources.app, sources.mic])
        await queue.awaitProcessing()
    }

    /// An engine of another type than the queue's, as the stage timings tell engines apart.
    private final class OtherKindEngine: MockEngine {}

    func testARerunRunsWithTheSettingsNamedAtItsAdmissionOverTheQueuesOwn() async throws {
        let fixture = try makeFixture()
        let parakeet = OtherKindEngine()
        parakeet.segmentsToReturn = fixture.engine.segmentsToReturn
        var named = PipelineJob.RerunSettings(engine: .whisperKit, diarize: false, numSpeakers: 0, vadThreshold: nil)
        let whisperKit = fixture.engine
        let timings = StageTimingLog(path: fixture.tmpDir.appendingPathComponent("stage_timings.jsonl"))
        let queue = fixture.makeQueue(
            diarizeEnabled: false,
            engineForKind: { $0 == .parakeet ? parakeet : whisperKit },
            rerunSettings: { named },
            stageTimingLog: timings,
        )
        let meeting = try await fixture.finishedMeeting(in: queue)
        let firstRunCalls = fixture.engine.transcribeCallCount
        XCTAssertEqual(fixture.diarization.runCount, 0, "test premise: the queue identifies no speakers")

        named = .init(engine: .parakeet, diarize: true, numSpeakers: 3, vadThreshold: 0.4)
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        XCTAssertEqual(queue.job(withID: meeting.id)?.rerun?.settings, named)
        XCTAssertNil(queue.vadConfig, "test premise: the queue runs no VAD")
        XCTAssertEqual(queue.vadThreshold(meeting.id), 0.4)
        await queue.awaitProcessing()

        XCTAssertEqual(fixture.engine.transcribeCallCount, firstRunCalls, "the queue's engine transcribed the re-run")
        XCTAssertEqual(parakeet.transcribeCallCount, 2, "the engine Settings name did not transcribe both tracks")
        XCTAssertEqual(fixture.diarization.runCount, 2, "speakers were not identified on both tracks")
        XCTAssertTrue(fixture.diarization.receivedNumSpeakers.contains(3), "\(fixture.diarization.receivedNumSpeakers)")

        // Each run's transcription is timed under the engine it ran on.
        let engines = {
            timings.loadRecentNow(within: 3600).filter { $0.jobID == meeting.id && $0.stage == .transcribing }.map(\.engine)
        }
        try await fixture.poll("both runs' transcription timings") { engines().count == 2 }
        XCTAssertEqual(engines(), [String(describing: MockEngine.self), String(describing: OtherKindEngine.self)])
    }

    /// Settings name the engine kind; the controller hands out that kind's instance
    /// for as long as a re-run may need it, also after Settings switched away.
    func testTheControllerKeepsAnEngineKindsInstanceAndHandsTheQueueTheCurrentSettings() throws {
        let tmpDir = try makeTempDirectory(prefix: "rerun_controller")
        let suite = "PipelineQueueRerunTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: tmpDir)
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let (whisperKit, parakeet) = (MockEngine(), MockEngine())
        let controller = PipelineController(
            settings: settings, notifier: RecordingNotifier(), queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir),
        )
        controller.activate { [settings] in settings.transcriptionEngine == .parakeet ? parakeet : whisperKit }
        settings.transcriptionEngine = .parakeet
        XCTAssertIdentical(controller.engine(ofKind: .parakeet), parakeet)

        settings.transcriptionEngine = .whisperKit
        XCTAssertIdentical(controller.engine(ofKind: .parakeet), parakeet, "the kind's instance was lost with the switch")
        XCTAssertIdentical(controller.engine(ofKind: .whisperKit), whisperKit)

        let queue = try XCTUnwrap(controller.makeQueue())
        (settings.diarize, settings.numSpeakers, settings.vadEnabled, settings.vadThreshold) = (true, 4, true, 0.6)
        XCTAssertEqual(
            queue.rerunSettingsProvider?(),
            .init(engine: .whisperKit, diarize: true, numSpeakers: 4, vadThreshold: 0.6),
            "the queue does not read Settings as they are now",
        )
        XCTAssertIdentical(queue.engineForKind?(.parakeet), parakeet)
    }

    // MARK: - A finished job still in the queue

    func testASettledFinishedJobStillInTheQueueIsTakenOver() async throws {
        let cases: [(name: String, failsExport: Bool, failsNotes: Bool)] = [
            ("in its last minute", false, false), ("after a failed export", true, false), ("with failed notes", false, true),
        ]
        for shape in cases {
            let fixture = try makeFixture()
            let notion = shape.failsExport
                ? NotionExportConfiguration(exporter: RetentionNotionExporter(fail: true), databaseID: "database-1") : nil
            let queue = fixture.makeQueue(completedJobLifetime: 1, notion: notion)
            // Held before its swap, so the re-run's own files can be read when it is done.
            queue.isRegenerationRunning = { true }
            fixture.protocolGen.shouldThrow = shape.failsNotes
            let meeting = try await fixture.finishedMeeting(in: queue)
            try await fixture.poll("\(shape.name): the export to end") { queue.notionExportTasks[meeting.id] == nil }
            let finished = try XCTUnwrap(queue.job(withID: meeting.id))
            XCTAssertEqual(finished.notionExportStatus == .failed, shape.failsExport, "\(shape.name): test premise")
            XCTAssertEqual(finished.notesFailure != nil, shape.failsNotes, "\(shape.name): test premise")
            fixture.protocolGen.shouldThrow = false
            let calls = fixture.engine.transcribeCallCount

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued, shape.name)

            XCTAssertNil(queue.completedJobRemovalTokens[meeting.id], "\(shape.name): the removal timer still runs")
            let rerun = try XCTUnwrap(queue.job(withID: meeting.id)?.rerun, shape.name)
            guard case let .job(held) = rerun.heldEntry else {
                XCTFail("\(shape.name): the finished job is not kept")
                continue
            }
            XCTAssertEqual(held.notionExportStatus, finished.notionExportStatus, shape.name)
            XCTAssertEqual(held.notesFailure, finished.notesFailure, shape.name)
            XCTAssertEqual(held.notesSpeakerNames, finished.notesSpeakerNames, shape.name)
            XCTAssertEqual(queue.jobs.count { $0.id == meeting.id }, 1, "\(shape.name): two entries of the meeting")
            let job = try XCTUnwrap(queue.job(withID: meeting.id))
            XCTAssertNil(job.generatesNotesOnly, shape.name)
            XCTAssertNil(job.notesFailure, shape.name)
            await queue.awaitProcessing()
            XCTAssertEqual(fixture.engine.transcribeCallCount, calls + 2, "\(shape.name): the re-run transcribed nothing")
            // Past the finished job's minute: the timer it had must not take the re-run.
            try await Task.sleep(for: .seconds(1.2))
            XCTAssertNotNil(queue.job(withID: meeting.id)?.rerun, "\(shape.name): the old removal timer took the re-run")
        }
    }

    func testAJobOfTheMeetingThatIsNotSettledIsRefused() async throws {
        for shape in ["a waiting notes retry", "a running notes retry", "waiting for names", "exporting"] {
            let fixture = try makeFixture()
            let gatedNotes = GatedProtocolGenerator()
            let exporter = GatedNotionExporter()
            var generator: any ProtocolGenerating = fixture.protocolGen
            let queue = fixture.makeQueue(
                notion: shape == "exporting" ? NotionExportConfiguration(exporter: exporter, databaseID: "database-1") : nil,
            ) { generator }
            fixture.protocolGen.shouldThrow = shape.contains("notes retry")
            fixture.parkForNaming(shape == "waiting for names")
            let meeting: PipelineJob
            if shape == "exporting" {
                // Draining the queue waits for the export too, which this one never ends.
                meeting = try fixture.makeRecording()
                queue.enqueue(meeting, origin: .recorded)
            } else {
                meeting = try await fixture.finishedMeeting(in: queue, allowingAnyEnd: true)
            }
            switch shape {
            case "a waiting notes retry":
                XCTAssertTrue(queue.retryMeetingNotes(id: meeting.id), "test premise")

            case "a running notes retry":
                generator = gatedNotes
                XCTAssertTrue(queue.retryMeetingNotes(id: meeting.id), "test premise")
                try await fixture.poll("the notes retry to run") { gatedNotes.started }

            case "exporting":
                try await fixture.poll("the export to run") { queue.notionExportTasks[meeting.id] != nil }

            default:
                XCTAssertEqual(queue.job(withID: meeting.id)?.state, .speakerNamingPending, "test premise")
            }
            let recordBefore = fixture.recordFileBytes

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .refused(.meetingBusy), shape)

            XCTAssertNil(queue.job(withID: meeting.id)?.rerun, shape)
            XCTAssertEqual(fixture.recordFileBytes, recordBefore, "\(shape): the record changed")
            await gatedNotes.release()
            await exporter.release()
            await queue.awaitProcessing()
        }
    }

    // MARK: - Refusals

    func testAdmissionRefusesAndChangesNothing() async throws {
        let cases: [(name: String, refusal: RerunRefusal, change: @MainActor (PipelineQueueRerunFixture, PipelineQueue, UUID) throws -> Void)] = [
            ("a record that is not finished", .notFinished, { fixture, _, id in
                fixture.store.update(jobID: id) { $0.outcome = .failed }
            }),
            ("a pending deletion", .deletionPending, { fixture, _, id in
                fixture.store.update(jobID: id) { $0.pending = .init(kind: .audioToTrash, paths: []) }
            }),
            ("an incomplete deletion", .deletionPending, { fixture, _, id in
                fixture.store.update(jobID: id) { $0.incomplete = .init(reason: "busy", paths: [], kind: .audioToTrash) }
            }),
            ("a marker the other build wrote", .alreadyRerunning, { fixture, _, id in
                let otherBuild = MeetingFileStore(path: fixture.storePath, bundleID: "other.build")
                otherBuild.update(jobID: id) { record in
                    record.rerun = .init(
                        stamp: Date(), outcomeBefore: record.outcome, bundleID: "other.build", process: .current, runID: UUID(),
                    )
                }
            }),
            ("audio another run holds", .audioHeldElsewhere, { fixture, queue, id in
                let mix = try XCTUnwrap(fixture.record(id).rerunSourceTracks.mix)
                queue.enqueue(PipelineJob(meetingTitle: "Again", appName: "File", mixPath: mix, appPath: nil, micPath: nil, micDelay: 0))
            }),
            ("audio gone", .audioGone, { fixture, _, id in
                let sources = try fixture.record(id).rerunSourceTracks
                for track in [sources.mix, sources.app, sources.mic].compactMap(\.self) {
                    try FileManager.default.removeItem(at: track)
                }
            }),
            ("audio on a drive that is not connected", .audioUnreachable, { fixture, _, _ in
                try FileManager.default.moveItem(at: fixture.recordingsDir, to: fixture.tmpDir.appendingPathComponent("unplugged"))
            }),
        ]
        for shape in cases {
            let fixture = try makeFixture()
            let queue = fixture.makeQueue(completedJobLifetime: 0)
            let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
            try shape.change(fixture, queue, meeting.id)
            let before = (record: fixture.recordFileBytes, entry: fixture.finishedEntry(meeting.id), jobs: queue.jobs.map(\.id))

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .refused(shape.refusal), shape.name)

            XCTAssertEqual(fixture.recordFileBytes, before.record, "\(shape.name): the record changed")
            XCTAssertEqual(fixture.finishedEntry(meeting.id), before.entry, "\(shape.name): the finished entry changed")
            XCTAssertEqual(queue.jobs.map(\.id), before.jobs, "\(shape.name): the queue changed")
            await queue.awaitProcessing()
        }
    }
}

/// Notes that wait until the test lets them through.
final class GatedProtocolGenerator: ProtocolGenerating, @unchecked Sendable {
    private let gate = AsyncGate()
    @MainActor private(set) var started = false

    func release() async {
        await gate.open()
    }

    func generate(
        transcript _: String, title _: String, diarized _: Bool, meetingStartTime _: Date?, instructions _: ProtocolInstructions,
    ) async -> String {
        await MainActor.run { started = true }
        await gate.wait()
        return "# Notes"
    }
}
