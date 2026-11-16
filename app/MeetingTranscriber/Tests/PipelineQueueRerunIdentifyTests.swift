import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Identify Speakers Again (R10): with the meeting's word timings kept it labels the
/// kept segments again and transcribes nothing; without them it transcribes with the
/// current settings. Either way it diarizes with the chosen method and count, and it
/// ends as every re-run does (R5, R6).
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
final class PipelineQueueRerunIdentifyTests: XCTestCase {
    private typealias Fixture = PipelineQueueRerunFixture

    private static let failed = "Identify Speakers Again failed: "

    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture(tmpDir: makeTempDirectory(prefix: "rerun_identify"))
        // Two lines from the call audio around one from the microphone.
        fixture.engine.segmentsByPathSuffix = [
            "app_16k.wav": [
                TimestampedSegment(start: 0, end: 2, text: "Welcome to the call"),
                TimestampedSegment(start: 4, end: 6, text: "Any questions left"),
            ],
            "mic_16k.wav": [TimestampedSegment(start: 2, end: 4, text: "Thanks for having me")],
        ]
        return fixture
    }

    /// A two-speaker diarization of each track, with voices to name.
    private func diarizeTwoVoices(_ fixture: Fixture) {
        fixture.diarization.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 3, speaker: "SPEAKER_0"), .init(start: 3, end: 6, speaker: "SPEAKER_1")],
            speakingTimes: ["SPEAKER_0": 3, "SPEAKER_1": 3],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]],
        )
    }

    /// The meeting's current transcript, as its record lists it.
    private func currentTranscript(_ id: UUID, _ fixture: Fixture) throws -> String {
        let file = try XCTUnwrap(fixture.record(id).files.last { $0.role == .transcript && $0.state != .gone })
        return try String(contentsOf: URL(filePath: file.path), encoding: .utf8)
    }

    /// The transcript's words in order, without timestamps, speaker labels and mute
    /// lines, which a new turn grouping places between other words.
    private func words(of transcript: String) -> [String] {
        transcript.split(separator: "\n").flatMap { line -> [String] in
            guard !line.hasPrefix("[Mic muted") else { return [] }
            var text = Substring(line)
            if text.hasPrefix("["), let close = text.firstIndex(of: "]") { text = text[text.index(after: close)...] }
            if let label = text.range(of: ": ") { text = text[label.upperBound...] }
            return text.split(separator: " ").map(String.init)
        }
    }

    private func muteLines(of transcript: String) -> [String] {
        transcript.split(separator: "\n").filter { $0.hasPrefix("[Mic muted") }.map(String.init)
    }

    // MARK: - With the word timings kept

    /// Settings' mic name changed since the first run, which tags the microphone's
    /// segments: a labelling that split them by the new name would drop its words.
    func testItLabelsTheKeptWordsAgainWithoutTranscribingAndNamesTheNewSpeakers() async throws {
        let fixture = try makeFixture()
        let recording = try fixture.makeRecording(micMuteIntervals: [MicMuteInterval(start: 0.1, end: 0.2)])
        let first = fixture.makeQueue(completedJobLifetime: 0)
        let meeting = try await fixture.finishedMeeting(in: first, recording, leavingTheQueue: true)
        let before = try currentTranscript(meeting.id, fixture)
        XCTAssertFalse(muteLines(of: before).isEmpty, "test premise: a mute line")
        let segments = try XCTUnwrap(fixture.record(meeting.id).keptWordTimings, "test premise: word timings kept")
        let calls = fixture.engine.transcribeCallCount
        let queue = fixture.makeQueue(micLabel: "Tobias", completedJobLifetime: 0)
        diarizeTwoVoices(fixture)
        var named: PipelineQueue.SpeakerNamingData?
        queue.speakerNamingHandler = { data in
            named = data
            return .confirmed(data.mapping.mapValues { _ in "Alice" })
        }

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .identifySpeakersAgain), .queued)
        await queue.awaitProcessing()
        try await fixture.poll("the swap to end") { queue.job(withID: meeting.id)?.rerun == nil }

        XCTAssertEqual(fixture.engine.transcribeCallCount, calls, "the re-run transcribed")
        XCTAssertEqual(named?.mapping.keys.contains("R_SPEAKER_1"), true, "not named with the new speakers: \(named?.mapping ?? [:])")
        let after = try currentTranscript(meeting.id, fixture)
        XCTAssertEqual(words(of: after), words(of: before), "the words changed:\n\(before)\n---\n\(after)")
        XCTAssertEqual(muteLines(of: after), muteLines(of: before))
        XCTAssertNotEqual(after, before, "the speakers did not change")
        XCTAssertNil(queue.rerunWarnings[meeting.id])
        // The re-run's segments file took the current name; the earlier one is gone.
        let current = try XCTUnwrap(fixture.record(meeting.id).keptWordTimings)
        XCTAssertEqual(current.path, segments.path)
        XCTAssertNotEqual(current.identity, segments.identity, "the earlier segments file is still current")
        let kept = try JSONDecoder().decode([TimestampedSegment].self, from: Data(contentsOf: URL(filePath: current.path)))
        XCTAssertEqual(kept.map(\.speaker), ["Remote", "Tobias", "Remote"])
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.recordingsDir.path)
        XCTAssertFalse(names.contains { $0.contains("_segments.until-") }, "\(names)")
    }

    /// A meeting with its call audio gone runs on its mix, and with its mix gone too
    /// on the microphone's track alone, where a transcription keeps no mute times.
    /// The kept words keep their mute lines, and the microphone's track alone is
    /// diarized on the meeting's timeline, `micDelay` after its start.
    func testOnWhatIsLeftOfItsAudioItKeepsTheMuteLinesAndTheMeetingsTimeline() async throws {
        let rows: [(gone: Set<MeetingFile.Role>, frames: Int)] = [([.appTrack], 8000), ([.appTrack, .mix], 8000 + 4000)]
        for row in rows {
            let fixture = try makeFixture()
            let recording = try fixture.makeRecording(micMuteIntervals: [MicMuteInterval(start: 0.1, end: 0.2)], micDelay: 0.25)
            let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0), recording, leavingTheQueue: true)
            let before = try currentTranscript(meeting.id, fixture)
            XCTAssertFalse(muteLines(of: before).isEmpty, "test premise: a mute line")
            for file in try fixture.record(meeting.id).files where row.gone.contains(file.role) {
                try FileManager.default.removeItem(at: URL(filePath: file.path))
            }
            let queue = fixture.makeQueue(completedJobLifetime: 0)
            diarizeTwoVoices(fixture)

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .identifySpeakersAgain), .queued, "\(row.gone)")
            await queue.awaitProcessing()

            XCTAssertEqual(queue.job(withID: meeting.id)?.state, .speakerNamingPending, "\(row.gone)")
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.recordingsDir.path)
            let mix = try XCTUnwrap(names.first { $0.hasSuffix(SpeakerNamingStore.mixSuffix) && !$0.hasSuffix("app_16k.wav") && !$0.hasSuffix("mic_16k.wav") })
            XCTAssertEqual(AudioMixer.frameCount(of: fixture.recordingsDir.appendingPathComponent(mix)), row.frames, "\(row.gone)")
            let mapping = try XCTUnwrap(queue.speakerNamingDataByJob[meeting.id]?.mapping)
            XCTAssertNil(queue.completeSpeakerNaming(jobID: meeting.id, result: .confirmed(mapping.mapValues { _ in "Alice" })))
            try await fixture.poll("the swap to end") { queue.job(withID: meeting.id)?.rerun == nil }
            let after = try currentTranscript(meeting.id, fixture)
            XCTAssertEqual(words(of: after), words(of: before), "\(row.gone)")
            XCTAssertEqual(muteLines(of: after), muteLines(of: before), "\(row.gone)")
        }
    }

    /// A first run whose call audio's speakers failed kept the microphone's lines
    /// labelled apart; two lines that start at once keep their order when both
    /// tracks are labelled again.
    func testTwoLinesStartingAtOnceKeepTheirOrderWhenBothTracksAreLabelledAgain() async throws {
        let fixture = try makeFixture()
        fixture.engine.segmentsByPathSuffix = [
            "app_16k.wav": [TimestampedSegment(start: 0, end: 2, text: "Welcome to the call")],
            "mic_16k.wav": [TimestampedSegment(start: 0, end: 2, text: "Thanks for having me")],
        ]
        fixture.diarization.throwOnPathSuffix = "app_16k.wav"
        let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0), leavingTheQueue: true)
        let before = try currentTranscript(meeting.id, fixture)
        fixture.diarization.throwOnPathSuffix = nil
        diarizeTwoVoices(fixture)
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        queue.speakerNamingHandler = { .confirmed($0.mapping.mapValues { _ in "Alice" }) }

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .identifySpeakersAgain), .queued)
        await queue.awaitProcessing()
        try await fixture.poll("the swap to end") { queue.job(withID: meeting.id)?.rerun == nil }

        let after = try currentTranscript(meeting.id, fixture)
        XCTAssertEqual(words(of: after), words(of: before), "the words changed:\n\(before)\n---\n\(after)")
    }

    func testItDiarizesWithTheChosenMethodAndCountAndTranscribesOnlyWithoutKeptWordTimings() async throws {
        for keptTimings in [true, false] {
            let fixture = try makeFixture()
            let first = fixture.makeQueue(saveRawTranscriptSeparately: keptTimings, completedJobLifetime: 0)
            let meeting = try await fixture.finishedMeeting(in: first, leavingTheQueue: true)
            XCTAssertEqual(try fixture.record(meeting.id).keptWordTimings != nil, keptTimings, "test premise")
            var methods: [DiarizerMode] = []
            let queue = fixture.makeQueue(
                diarizationFactoryWithMode: { mode in
                    methods.append(mode)
                    return fixture.diarization
                },
                diarizeEnabled: false,
            )
            diarizeTwoVoices(fixture)
            let calls = fixture.engine.transcribeCallCount

            let speakers = RerunSpeakers(method: .sortformer, count: 3)
            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .identifySpeakersAgain, speakers: speakers), .queued)
            await queue.awaitProcessing()

            XCTAssertEqual(queue.job(withID: meeting.id)?.state, .speakerNamingPending, "kept \(keptTimings)")
            XCTAssertEqual(methods, [.sortformer], "kept \(keptTimings)")
            XCTAssertEqual(Array(fixture.diarization.receivedNumSpeakers.suffix(2)), [3, nil], "kept \(keptTimings): call audio, then microphone")
            XCTAssertEqual(fixture.engine.transcribeCallCount, keptTimings ? calls : calls + 2, "kept \(keptTimings)")
        }
    }

    // MARK: - Ends

    func testEachFailureEndsItWithItsLineAndLeavesTheMeetingAsItWas() async throws {
        let rows: [(name: String, line: String, arrange: @MainActor (Fixture) -> Void)] = [
            ("not available", Self.failed + "speaker diarization is not available right now", { $0.diarization.isAvailable = false }),
            ("no voices", Self.failed + "found no voices to name", { $0.parkForNaming(false) }),
            ("call audio failing", Self.failed + RerunFailure.callAudioSpeakersFailed, { $0.diarization.throwOnPathSuffix = "app_16k.wav" }),
            ("microphone failing", Self.failed + RerunFailure.microphoneSpeakersFailed, { $0.diarization.throwOnPathSuffix = "mic_16k.wav" }),
        ]
        for row in rows {
            let fixture = try makeFixture()
            let queue = fixture.makeQueue(completedJobLifetime: 0)
            let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
            let (files, record) = try (fixture.outputFiles(), fixture.record(meeting.id))
            diarizeTwoVoices(fixture)
            row.arrange(fixture)

            XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .identifySpeakersAgain), .queued, row.name)
            await queue.awaitProcessing()

            XCTAssertNil(queue.job(withID: meeting.id), row.name)
            XCTAssertEqual(queue.rerunWarnings[meeting.id].map(TranscriptionsView.rerunWarningLine), row.line, row.name)
            XCTAssertEqual(try fixture.outputFiles(), files, "\(row.name): the meeting's files changed")
            XCTAssertEqual(try fixture.record(meeting.id).files, record.files, row.name)
            XCTAssertEqual(try fixture.record(meeting.id).outcome, record.outcome, row.name)
        }
    }

    /// The naming dialog's Re-run inside a re-run, with one track failing: it fails
    /// as a whole and the dialog shows the labels it had, and the meeting's current
    /// files are never touched.
    func testTheDialogsRerunWithAFailingTrackKeepsTheLabelsItHad() async throws {
        let fixture = try makeFixture()
        let queue = fixture.makeQueue(completedJobLifetime: 0)
        let meeting = try await fixture.finishedMeeting(in: queue, leavingTheQueue: true)
        diarizeTwoVoices(fixture)
        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .identifySpeakersAgain), .queued)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.job(withID: meeting.id)?.state, .speakerNamingPending, "test premise")
        let labels = try XCTUnwrap(queue.speakerNamingDataByJob[meeting.id]?.mapping)
        let warnings = queue.job(withID: meeting.id)?.warnings
        let current = try fixture.record(meeting.id).files.filter { $0.state != .gone }.map(\.path)
        let bytes = try current.map { try Data(contentsOf: URL(filePath: $0)) }
        XCTAssertFalse(current.isEmpty, "test premise")
        fixture.diarization.throwOnPathSuffix = "_mic_16k.wav"

        XCTAssertNil(queue.completeSpeakerNaming(jobID: meeting.id, result: .rerun(2)))
        try await fixture.poll("the Re-run to come back") {
            queue.job(withID: meeting.id)?.state == .speakerNamingPending && queue.naming.lateWork[meeting.id] == nil
        }

        XCTAssertEqual(queue.naming.lateRerunFailures[meeting.id], .rerunFailed)
        XCTAssertEqual(queue.speakerNamingDataByJob[meeting.id]?.mapping, labels)
        XCTAssertEqual(queue.job(withID: meeting.id)?.warnings, warnings, "a one-side warning was added")
        XCTAssertEqual(try current.map { try Data(contentsOf: URL(filePath: $0)) }, bytes, "a file of the meeting changed")
    }

    // MARK: - The earlier word timings

    /// A re-run whose option is off keeps no segments file to rename in, so the
    /// current one is still the earlier run's, with words the new transcript no
    /// longer has: it goes at the commit, also with notes off.
    func testARerunThatKeptNoWordTimingsTakesTheEarlierOnesAlong() async throws {
        let fixture = try makeFixture()
        let meeting = try await fixture.finishedMeeting(in: fixture.makeQueue(completedJobLifetime: 0), leavingTheQueue: true)
        let earlier = try XCTUnwrap(fixture.record(meeting.id).keptWordTimings, "test premise: word timings kept")
        let noNotes: () -> (any ProtocolGenerating)? = { nil }
        let queue = fixture.makeQueue(saveRawTranscriptSeparately: false, protocolGenerator: noNotes)
        diarizeTwoVoices(fixture)
        queue.speakerNamingHandler = { data in .confirmed(data.mapping.mapValues { _ in "Alice" }) }

        XCTAssertEqual(queue.rerunJob(id: meeting.id, mode: .transcribeAgain), .queued)
        await queue.awaitProcessing()
        try await fixture.poll("the swap to end") { queue.job(withID: meeting.id)?.rerun == nil }

        XCTAssertNil(queue.rerunWarnings[meeting.id], "test premise: the re-run succeeded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlier.path), "the earlier word timings are left")
        XCTAssertTrue(try fixture.record(meeting.id).files.filter { $0.role == .segments }.allSatisfy { $0.state == .gone })
    }
}
