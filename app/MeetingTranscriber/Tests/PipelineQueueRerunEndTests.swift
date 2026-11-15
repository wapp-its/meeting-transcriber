import AudioTapLib
@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// Every end of a re-run but success leaves the meeting as it was (R6): its files
/// byte for byte, its record's outcome with no marker and the stamp noted as ended,
/// its finished entry and its audio, and no file of the re-run.
@MainActor
final class PipelineQueueRerunEndTests: XCTestCase {
    private typealias Fixture = PipelineQueueRerunFixture
    private typealias Naming = (PipelineQueue.SpeakerNamingData) async -> PipelineQueue.SpeakerNamingResult

    /// One way a re-run ends.
    private struct End {
        let name: String
        /// The row's line after it, as it begins; nil for none.
        let line: String?
        var parks = false
        var naming: Naming?
        /// Holds the notes back, so the re-run still runs when `end` acts.
        var holdsNotes = false
        /// Before the re-run is admitted.
        var arrange: @MainActor (Fixture) -> Void = { _ in }
        /// Once admitted, with the stem of its files, before it runs.
        var admitted: @MainActor (Fixture, String) throws -> Void = { _, _ in }
        /// What ends it once it went as far as it goes by itself.
        var end: @MainActor (PipelineQueue, UUID) -> Void = { _, _ in }
    }

    /// What the first run left, which every end must leave as it was.
    private struct Meeting {
        let job: PipelineJob
        let files: [String: Data]
        let history: Data?
        let record: MeetingFileRecord
        let audio: [String: Data]
    }

    private static let confirmed: Naming = { data in .confirmed(data.mapping.mapValues { _ in "Alice" }) }
    private static let skipped: Naming = { _ in .skipped }

    private static let failed = "Transcribe Again failed: "

    /// Notes that cannot be saved: a folder sits where the re-run's notes go.
    private static let notesPathTaken: @MainActor (Fixture, String) throws -> Void = { fixture, stem in
        let taken = fixture.protocolsDir.appendingPathComponent("\(stem).md/held")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
    }

    // Each row names the closure it sets: as a trailing closure, which of an
    // End's several closures it is would be left for the reader to work out.
    // swiftlint:disable trailing_closure
    private static let ends: [End] = [
        End(name: "a transcription failure", line: failed, arrange: { $0.engine.shouldThrow = true }),
        End(name: "speaker identification failing", line: failed + RerunFailure.speakersFailed, arrange: { fixture in
            fixture.diarization.throwOnPathSuffix = "_16k.wav"
        }),
        End(name: "speaker identification not available", line: failed + RerunFailure.speakersNotAvailable, arrange: { fixture in
            fixture.diarization.isAvailable = false
        }),
        End(name: "a failing call-audio track", line: failed + RerunFailure.callAudioSpeakersFailed, arrange: { fixture in
            fixture.diarization.throwOnPathSuffix = "app_16k.wav"
        }),
        End(name: "a failing microphone track", line: failed + RerunFailure.microphoneSpeakersFailed, arrange: { fixture in
            fixture.diarization.throwOnPathSuffix = "mic_16k.wav"
        }),
        End(
            name: "notes not made after a confirmed naming",
            line: failed + RerunFailure.notesNotMade,
            parks: true,
            naming: confirmed,
            arrange: { $0.protocolGen.shouldThrow = true },
        ),
        End(
            name: "notes not made after a skipped naming",
            line: failed + RerunFailure.notesNotMade,
            parks: true,
            naming: skipped,
            arrange: { $0.protocolGen.shouldThrow = true },
        ),
        End(
            name: "notes not saved after a confirmed naming",
            line: failed + RerunFailure.notesNotSaved,
            parks: true,
            naming: confirmed,
            admitted: notesPathTaken,
        ),
        End(
            name: "notes not saved after a skipped naming",
            line: failed + RerunFailure.notesNotSaved,
            parks: true,
            naming: skipped,
            admitted: notesPathTaken,
        ),
        End(name: "Cancel", line: nil, holdsNotes: true, end: { $0.cancelJob(id: $1) }),
        End(name: "Dismiss", line: nil, parks: true, end: { $0.removeJob(id: $1) }),
        End(
            name: "a naming left past the wait",
            line: "Transcribe Again ended: the speakers were not named in time",
            parks: true,
            end: { queue, _ in queue.cleanupStalePending(maxAge: 0) },
        ),
    ]
    // swiftlint:enable trailing_closure

    func testEachEndLeavesTheMeetingAsItWas() async throws {
        for end in Self.ends {
            let fixture = try makeFixture()
            let notes = GatedProtocolGenerator()
            var generator: any ProtocolGenerating = fixture.protocolGen
            // The fixture takes several closures; the label says which one this is.
            // swiftlint:disable:next trailing_closure
            let queue = fixture.makeQueue(completedJobLifetime: 0, protocolGenerator: { generator })
            let meeting = try await finishedMeeting(fixture, in: queue)
            end.arrange(fixture)
            fixture.parkForNaming(end.parks)
            queue.speakerNamingHandler = end.naming
            if end.holdsNotes { generator = notes }

            XCTAssertEqual(queue.rerunJob(id: meeting.job.id, mode: .transcribeAgain), .queued, end.name)
            let stamp = try fixture.marker(meeting.job.id, in: queue).stamp
            try end.admitted(fixture, fixture.rerunStem(of: meeting.job, in: queue))
            try await fixture.poll("\(end.name): the re-run to go as far as it goes") {
                let job = queue.job(withID: meeting.job.id)
                return job == nil || job?.state == .speakerNamingPending || notes.started
            }
            end.end(queue, meeting.job.id)
            await notes.release()
            try await fixture.poll("\(end.name): the re-run to end") { queue.job(withID: meeting.job.id) == nil }
            await queue.awaitProcessing()

            try assertLeftAsItWas(meeting, fixture, stamp: stamp, end.name)
            let line = queue.rerunWarnings[meeting.job.id].map(TranscriptionsView.rerunWarningLine)
            if let expected = end.line {
                XCTAssertEqual(line?.hasPrefix(expected), true, "\(end.name): \(line ?? "no line")")
            } else {
                XCTAssertNil(line, end.name)
            }
        }
    }

    func testAFileTheRecordMissedIsRemovedAtTheEnd() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        let meeting = try await finishedMeeting(fixture, in: queue)
        fixture.parkForNaming(true)
        XCTAssertEqual(queue.rerunJob(id: meeting.job.id, mode: .transcribeAgain), .queued)
        try await fixture.poll("the names") { queue.job(withID: meeting.job.id)?.state == .speakerNamingPending }
        await queue.awaitProcessing()
        let stamp = try fixture.marker(meeting.job.id, in: queue).stamp
        // A record update that failed: the job lists the transcript, the record does not.
        XCTAssertTrue(fixture.store.update(jobID: meeting.job.id) { $0.rerun?.files.removeAll { $0.role == .transcript } })
        XCTAssertTrue(try fixture.marker(meeting.job.id, in: queue).files.contains { $0.role == .transcript }, "test premise")

        queue.removeJob(id: meeting.job.id)

        try assertLeftAsItWas(meeting, fixture, stamp: stamp, "a file the record missed")
    }

    // MARK: - Two tracks

    func testARerunWhoseMicrophoneHeldNoAudioGoesOnWithTheCallAudio() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        // Muted throughout, so the transcribe stage finds nothing to use on it.
        let recording = try fixture.makeRecording(micMuteIntervals: [MicMuteInterval(start: 0, end: 60)])
        let meeting = try await fixture.finishedMeeting(in: queue, recording, leavingTheQueue: true)
        fixture.diarization.throwOnPathSuffix = "mic_16k.wav"
        fixture.diarization.receivedAudioPaths = []
        // Held before its swap, so the re-run's own files can be read when it is done.
        queue.isRegenerationRunning = { true }

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()

        let rerun = try XCTUnwrap(queue.job(withID: meeting.id), "the re-run ended")
        XCTAssertEqual(rerun.trackViability?.carriesMicAudio, false, "test premise: the microphone held no audio")
        XCTAssertEqual(rerun.state, .done)
        XCTAssertNotNil(rerun.rerun)
        XCTAssertFalse(fixture.diarization.receivedAudioPaths.contains { $0.lastPathComponent.hasSuffix("mic_16k.wav") })
        XCTAssertTrue(fixture.diarization.receivedAudioPaths.contains { $0.lastPathComponent.hasSuffix("app_16k.wav") })
    }

    func testANewMeetingWithAFailingTrackStillFinishesWithItsWarning() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        fixture.diarization.throwOnPathSuffix = "mic_16k.wav"

        let meeting = try await fixture.finishedMeeting(in: queue)

        XCTAssertEqual(
            fixture.finishedEntry(meeting.id)?.status.warnings
                .contains("Mic track diarization failed — speaker labels reflect remote audio only"),
            true,
        )
    }

    // MARK: - A finished entry taken over

    func testATakenOverEntryComesBackAsItWasAfterEachEnd() async throws {
        let ends: [(name: String, parks: Bool, end: @MainActor (Fixture, PipelineQueue, UUID) -> Void)] = [
            ("a failure", false, { fixture, _, _ in fixture.engine.shouldThrow = true }),
            ("Cancel", false, { _, queue, id in queue.cancelJob(id: id) }),
            ("Dismiss", true, { _, queue, id in queue.removeJob(id: id) }),
            ("a naming left past the wait", true, { _, queue, _ in queue.cleanupStalePending(maxAge: 0) }),
        ]
        for held in ["a failed export", "failed notes"] {
            for end in ends {
                let name = "\(held), \(end.name)"
                let fixture = try makeFixture()
                let failsExport = held == "a failed export"
                let notion = failsExport
                    ? NotionExportConfiguration(exporter: RetentionNotionExporter(fail: true), databaseID: "database-1") : nil
                let queue = fixture.makeQueue(notion: notion)
                fixture.protocolGen.shouldThrow = !failsExport
                let meeting = try await fixture.finishedMeeting(in: queue)
                try await fixture.poll("\(name): the export to end") { queue.notionExportTasks[meeting.id] == nil }
                let before = try XCTUnwrap(queue.job(withID: meeting.id))
                XCTAssertTrue(before.isHeldAfterCompletion, "\(name): test premise")
                fixture.protocolGen.shouldThrow = false
                fixture.parkForNaming(end.parks)

                XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued, name)
                if end.parks {
                    try await fixture.poll("\(name): the names") { queue.job(withID: meeting.id)?.state == .speakerNamingPending }
                }
                end.end(fixture, queue, meeting.id)
                await queue.awaitProcessing()
                try await fixture.poll("\(name): the re-run to end") { queue.job(withID: meeting.id)?.rerun == nil }

                let after = try XCTUnwrap(queue.job(withID: meeting.id), name)
                XCTAssertEqual(after.state, .done, name)
                XCTAssertTrue(after.isHeldAfterCompletion, name)
                XCTAssertEqual(after.notionExportStatus, before.notionExportStatus, name)
                XCTAssertEqual(after.notesFailure, before.notesFailure, name)
                XCTAssertEqual(after.notesSpeakerNames, before.notesSpeakerNames, name)
                XCTAssertEqual(queue.canRetryNotionExport(id: meeting.id), failsExport, name)
                XCTAssertEqual(after.hasRetryableMeetingNotes, !failsExport, name)
            }
        }
    }

    // MARK: - Files the end could not remove (A27)

    func testAFileThatFailsTheCheckOrItsRemovalStaysUntilItIsGone() async throws {
        let shapes: [(name: String, spoil: (URL) throws -> Void, heal: (URL) throws -> Void)] = [
            ("replaced at its path", { file in
                try FileManager.default.removeItem(at: file)
                try Data("someone else's".utf8).write(to: file)
            }, { try FileManager.default.removeItem(at: $0) }),
            ("reached through a folder replaced by a symbolic link", { file in
                let folder = file.deletingLastPathComponent()
                let moved = folder.deletingLastPathComponent().appendingPathComponent("moved")
                try FileManager.default.moveItem(at: folder, to: moved)
                try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
            }, { try FileManager.default.removeItem(at: $0) }),
            ("whose removal fails", { file in
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: file.deletingLastPathComponent().path)
            }, { file in
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.deletingLastPathComponent().path)
            }),
        ]
        for shape in shapes {
            let fixture = try makeFixture()
            let queue = fixture.makeQueue(completedJobLifetime: 0)
            let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
            let outcome = try fixture.record(meeting.id).outcome
            fixture.parkForNaming(true)
            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued, shape.name)
            try await fixture.poll("\(shape.name): the names") { queue.job(withID: meeting.id)?.state == .speakerNamingPending }
            // The run lets go of the audio once it has parked.
            await queue.awaitProcessing()
            let transcript = try XCTUnwrap(
                fixture.marker(meeting.id, in: queue).files.first { $0.role == .transcript }, shape.name,
            )
            let file = URL(filePath: transcript.path)
            try shape.spoil(file)
            addTeardownBlock { try? shape.heal(file) }

            queue.removeJob(id: meeting.id)

            let record = try fixture.record(meeting.id)
            XCTAssertEqual(record.outcome, outcome, "\(shape.name): the outcome was not restored")
            XCTAssertEqual(record.rerun?.isEnding, true, shape.name)
            XCTAssertEqual(record.rerun?.files.map(\.path), [transcript.path], "\(shape.name): the marker lists other files")
            XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), "\(shape.name): the file was removed")

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .refused(.filesLeft), shape.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), shape.name)
            try shape.heal(file)
            fixture.parkForNaming(false)

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued, "\(shape.name): once it is gone")
            await queue.awaitProcessing()
        }
    }

    // MARK: - The row's line (A23)

    func testTheLineSaysHowTheRerunEnded() {
        XCTAssertEqual(
            TranscriptionsView.rerunWarningLine(.init(mode: .transcribeAgain, cause: .failed("the notes could not be made"))),
            "Transcribe Again failed: the notes could not be made",
        )
        XCTAssertEqual(
            TranscriptionsView.rerunWarningLine(.init(mode: .transcribeAgain, cause: .unnamed)),
            "Transcribe Again ended: the speakers were not named in time",
        )
    }

    func testTheRowShowsTheLineUntilTheNextRerunIsAdmitted() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let controller = try makeController(on: queue, fixture: fixture)
        fixture.diarization.isAvailable = false
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        let line = Self.failed + RerunFailure.speakersNotAvailable

        let view = TranscriptionsView(
            entries: controller.transcriptionEntries, query: .constant(""), actions: .noop,
            regenerateSheet: RegenerateSheetState(), regenerationPhase: .idle,
        )

        XCTAssertNoThrow(try view.inspect().find(ViewType.Text.self) { try $0.string().hasPrefix(line) })
        XCTAssertEqual(fixture.finishedEntry(meeting.id)?.status.warnings.contains(line), false, "the line reached the history")
        fixture.diarization.isAvailable = true
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        XCTAssertNil(queue.rerunWarnings[meeting.id])
        XCTAssertFalse(controller.transcriptionEntries.contains { $0.warnings.contains(line) })
        await queue.awaitProcessing()
    }

    // MARK: - Helpers

    private func makeFixture() throws -> Fixture {
        try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_end"))
    }

    /// A recorded call run to its end, out of the queue, with an additional report
    /// beside its notes.
    private func finishedMeeting(_ fixture: Fixture, in queue: PipelineQueue) async throws -> Meeting {
        let job = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        let notes = try XCTUnwrap(fixture.finishedEntry(job.id)?.status.protocolPath, "test premise: notes")
        let report = URL(filePath: notes).deletingPathExtension().path + " (Decisions).md"
        try Data("# Decisions".utf8).write(to: URL(filePath: report))
        let record = try fixture.record(job.id)
        let audio = try audioBytes(of: record)
        XCTAssertFalse(audio.isEmpty, "test premise: the meeting's audio")
        return try Meeting(
            job: job, files: fixture.outputFiles(), history: fixture.terminalFileBytes, record: record, audio: audio,
        )
    }

    /// The meeting's audio as its record lists it, by path, with its bytes.
    private func audioBytes(of record: MeetingFileRecord) throws -> [String: Data] {
        let tracks = record.rerunSourceTracks
        return try Dictionary(uniqueKeysWithValues: [tracks.mix, tracks.app, tracks.mic].compactMap(\.self).map { track in
            try (track.path, Data(contentsOf: track))
        })
    }

    private func assertLeftAsItWas(_ meeting: Meeting, _ fixture: Fixture, stamp: Date, _ name: String) throws {
        XCTAssertEqual(try fixture.outputFiles(), meeting.files, "\(name): a file of the meeting changed or one of the re-run stayed")
        XCTAssertEqual(fixture.terminalFileBytes, meeting.history, "\(name): the finished entry changed")
        var expected = meeting.record
        expected.rerunNote = .init(stamp: stamp, committed: false)
        XCTAssertEqual(try fixture.record(meeting.job.id), expected, "\(name): the record is not as it was")
        XCTAssertEqual(try audioBytes(of: fixture.record(meeting.job.id)), meeting.audio, "\(name): the audio changed")
    }

    private func makeController(on queue: PipelineQueue, fixture: Fixture) throws -> PipelineController {
        let suite = "PipelineQueueRerunEndTests-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: fixture.outputDir)
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return PipelineController(
            settings: settings, notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: fixture.tmpDir.appendingPathComponent("controller"), initialQueue: queue),
            terminalJobStore: fixture.terminal, meetingFileStore: fixture.store,
        )
    }
}
