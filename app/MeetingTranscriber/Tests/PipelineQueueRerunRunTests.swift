import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// A re-run admitted by `PipelineQueue.rerunJob` running through the pipeline:
/// its files carry a stem of their own, the meeting's files stay as they are, it
/// leaves the audio and the meeting's bookkeeping alone, and its success hook
/// gets its files. `PipelineQueueRerunTests` covers the admission.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueRerunRunTests: XCTestCase {
    private func makeFixture() throws -> PipelineQueueRerunFixture {
        try PipelineQueueRerunFixture(tmpDir: makeTempDirectory(prefix: "rerun_run"))
    }

    /// The files under the output folder that `before` did not have all carry
    /// `stem`, and the ones it had are there byte for byte.
    private func assertOnlyFilesOfItsOwn(
        stem: String, before: [String: Data], after: [String: Data], file: StaticString = #filePath, line: UInt = #line,
    ) {
        for (path, bytes) in before {
            XCTAssertEqual(after[path], bytes, "\(path) of the meeting changed", file: file, line: line)
        }
        for path in Set(after.keys).subtracting(before.keys) {
            XCTAssertTrue(
                URL(filePath: path).lastPathComponent.hasPrefix(stem), "\(path) does not carry the re-run's stem",
                file: file, line: line,
            )
        }
    }

    func testARecordedCallsRerunTranscribesItsTwoTracksAndParksForNamingUnderItsOwnStem() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue()
        let meeting = try await fixture.finishedMeeting(in: queue)
        let notes = try XCTUnwrap(queue.job(withID: meeting.id)?.protocolPath, "test premise: notes saved")
        let report = notes.deletingLastPathComponent()
            .appendingPathComponent("\(notes.deletingPathExtension().lastPathComponent) (Summary).md")
        try "A report of the meeting".write(to: report, atomically: true, encoding: .utf8)
        let (filesBefore, recordBefore) = try (fixture.outputFiles(), fixture.record(meeting.id))
        let entryBefore = fixture.finishedEntry(meeting.id)
        let (calls, diarizations) = (fixture.engine.transcribeCallCount, fixture.diarization.runCount)
        fixture.parkForNaming(true)

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()

        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .speakerNamingPending)
        XCTAssertEqual(fixture.engine.transcribeCallCount, calls + 2, "the two tracks were not transcribed separately")
        XCTAssertEqual(fixture.diarization.runCount, diarizations + 2, "speakers were not identified per track")
        XCTAssertEqual(Set(fixture.diarization.receivedAudioPaths.suffix(2)).count, 2, "one track was diarized twice")
        let stem = try fixture.rerunStem(of: meeting, in: queue)
        let marker = try fixture.marker(meeting.id, in: queue)
        XCTAssertTrue(
            Set(marker.files.map(\.role)).isSuperset(of: [.transcript, .segments, .naming, .app16k, .mic16k]),
            "\(marker.files.map(\.role))",
        )
        for written in marker.files {
            XCTAssertTrue(URL(filePath: written.path).lastPathComponent.hasPrefix(stem), "\(written.path)")
        }
        try assertOnlyFilesOfItsOwn(stem: stem, before: filesBefore, after: fixture.outputFiles())
        let recordNow = try fixture.record(meeting.id)
        XCTAssertEqual(recordNow.files, recordBefore.files, "the meeting's files list took a file of the re-run")

        // While it runs: the marker on both sides, the outcome before kept in it.
        XCTAssertEqual(recordNow.rerun, marker)
        XCTAssertEqual(marker.outcomeBefore, .finished(protocolExpected: true))
        XCTAssertEqual(recordNow.outcome, .inProgress)
        XCTAssertEqual(fixture.finishedEntry(meeting.id), entryBefore, "the finished entry changed")
        let controller = try makeController(on: queue, fixture: fixture)
        XCTAssertEqual(controller.jobStatus(forID: meeting.id)?.state, .speakerNamingPending, "not answered from the live job")
    }

    /// The meeting's audio sits in the folder this queue takes as its staging
    /// folder, which a first run moves from; a re-run must leave it there.
    func testARerunMovesNoAudioRegistersNothingMarksNoLedgerAndKeepsItsStem() async throws {
        let fixture = try makeFixture()
        let calls = fixture.tmpDir.appendingPathComponent("calls")
        let firstQueue = fixture.makeQueue(stagingDir: fixture.tmpDir.appendingPathComponent("inbox"))
        let meeting = try await fixture.finishedMeeting(in: firstQueue, fixture.makeRecording(in: calls))
        let sources = try fixture.record(meeting.id).rerunSourceTracks
        let audioBefore = try [sources.mix, sources.app, sources.mic].map { try Data(contentsOf: XCTUnwrap($0)) }
        let logDir = fixture.tmpDir.appendingPathComponent("logs-rerun")
        let retention = RecordingRetention(
            registry: RecordingRetentionRegistry(path: logDir.appendingPathComponent(RecordingRetentionRegistry.filename)),
        ) { RecordingRetentionSettings(enabled: false, days: 0) }
        fixture.protocolGen.headingTitle = "Budget Review"
        let queue = fixture.makeQueue(
            stagingDir: calls, logDir: logDir, useAITitleForFilenames: true, recordingRetention: retention,
        )
        let filesBefore = try fixture.outputFiles()

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()

        XCTAssertEqual(try fixture.record(meeting.id).rerunSourceTracks.mix, sources.mix)
        XCTAssertEqual(
            try [sources.mix, sources.app, sources.mic].map { try Data(contentsOf: XCTUnwrap($0)) }, audioBefore,
            "the audio moved",
        )
        XCTAssertTrue(retention.registry.entries.isEmpty, "a retention entry was written: \(retention.registry.entries)")
        XCTAssertTrue(ProcessedRecordingsLedger(logDir: logDir).load().isEmpty, "the processed-recordings ledger was marked")
        let stem = try fixture.rerunStem(of: meeting, in: queue)
        let marker = try fixture.marker(meeting.id, in: queue)
        XCTAssertTrue(marker.files.contains { $0.role == .protocol }, "test premise: the notes were saved")
        for written in marker.files {
            XCTAssertTrue(URL(filePath: written.path).lastPathComponent.hasPrefix(stem), "renamed: \(written.path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: written.path), "not where the marker lists it: \(written.path)")
        }
        try assertOnlyFilesOfItsOwn(stem: stem, before: filesBefore, after: fixture.outputFiles())
    }

    func testAConfirmedRerunHandsItsFilesToTheSuccessHookOnceAndSavesTheVoice() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue()
        let meeting = try await fixture.finishedMeeting(in: queue)
        var handed: [(id: UUID, files: [MeetingFile])] = []
        queue.onRerunSucceeded = { job, files in handed.append((job.id, files)) }
        fixture.parkForNaming(true)
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .speakerNamingPending, "test premise")
        XCTAssertTrue(handed.isEmpty, "the hook ran before the names were confirmed")

        // A recorded call's labels carry their track (`SpeakerKey`).
        let label = try XCTUnwrap(queue.speakerNamingData(forJobID: meeting.id)?.embeddings.keys.min(), "nothing to name")
        queue.completeSpeakerNaming(jobID: meeting.id, result: .confirmed([label: "Alice"]))
        try await fixture.poll("the success hook") { !handed.isEmpty }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(handed.map(\.id), [meeting.id], "the hook did not run exactly once")
        let files = try XCTUnwrap(handed.first?.files)
        XCTAssertTrue(Set(files.map(\.role)).isSuperset(of: [.transcript, .protocol]), "\(files.map(\.role))")
        let stem = try fixture.rerunStem(of: meeting, in: queue)
        for file in files {
            XCTAssertTrue(URL(filePath: file.path).lastPathComponent.hasPrefix(stem), file.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "handed a file that is gone: \(file.path)")
        }
        XCTAssertTrue(SpeakerMatcher(dbPath: fixture.speakersDB).allSpeakerNames().contains("Alice"), "the voice was not saved")
    }

    /// Without its mic track a recorded call runs on its mix, which holds the far
    /// end: the mic's mute times must not take the far end's words out of it.
    func testARecordedCallsRerunWithoutItsMicTrackKeepsWhatTheFarEndSaidDuringAMute() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue()
        let recording = try fixture.makeRecording(micMuteIntervals: [MicMuteInterval(start: 0, end: 5)])
        let meeting = try await fixture.finishedMeeting(in: queue, recording)
        let record = try fixture.record(meeting.id)
        XCTAssertFalse(record.runInputs?.micMuteIntervals.isEmpty ?? true, "test premise: no mute kept")
        try FileManager.default.removeItem(at: XCTUnwrap(record.rerunSourceTracks.mic))

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()

        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .done, "\(String(describing: queue.job(withID: meeting.id)?.error))")
        let transcript = try XCTUnwrap(fixture.marker(meeting.id, in: queue).files.first { $0.role == .transcript }, "no transcript")
        XCTAssertTrue(try String(contentsOfFile: transcript.path, encoding: .utf8).contains("Hello world"), "the far end's words went")
    }

    private func makeController(on queue: PipelineQueue, fixture: PipelineQueueRerunFixture) throws -> PipelineController {
        let suite = "PipelineQueueRerunRunTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: fixture.outputDir)
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: fixture.tmpDir.appendingPathComponent("controller"), initialQueue: queue),
            terminalJobStore: fixture.terminal, meetingFileStore: fixture.store,
        )
    }
}
