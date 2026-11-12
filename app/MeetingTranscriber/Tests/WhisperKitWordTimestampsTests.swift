import Foundation
@testable import MeetingTranscriber
import WhisperKit
import XCTest

/// File transcription takes segment times from word timings; live captions do
/// not ask for them. On one track of a two-track recording the other side's
/// turns are silence, and with segment-level times only WhisperKit started a
/// turn after a long silence where the previous segment ended or at the start
/// of its 30-second window, up to about 30 s before it was spoken.
@MainActor
final class WhisperKitWordTimestampsTests: XCTestCase {
    // MARK: - Decoding options per flow (no model)

    func testFileTranscriptionRequestsWordTimestampsAndLiveCaptionsDoNot() async throws {
        let client = OptionsCapturingDecodingClient()
        let engine = WhisperKitEngine()
        engine.language = "de"
        engine.installDecodingClientForTesting(client)

        _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/tmp/word-timestamps-test.wav"))
        _ = try await engine.transcribeSamples([0])

        let file = try XCTUnwrap(client.fileOptions.first)
        let live = try XCTUnwrap(client.sampleOptions.first)
        XCTAssertTrue(file.wordTimestamps, "file transcription must take segment times from word timings")
        XCTAssertFalse(live.wordTimestamps, "live captions must keep their decoding options")
        // Only the timing source differs between the two flows.
        XCTAssertEqual(file.language, "de")
        XCTAssertEqual(live.language, "de")
        XCTAssertFalse(file.detectLanguage)
        XCTAssertFalse(live.detectLanguage)
    }

    // MARK: - A turn after a long silence (slow, needs model)

    /// `turn_after_silence_de.wav` is one track of a two-track call on which
    /// the other side speaks first: 12 s of digital silence, then a turn
    /// spoken at exactly 12.0 s. A 30-second window that begins in silence is
    /// what pulls the start early; a first turn inside the same window would
    /// not (WhisperKit splits that window at the timestamps between the two
    /// turns), and a first turn plus a second window needs over 30 s of audio.
    /// Made with
    ///
    ///     say -v Anna -o turn.aiff "Die Auswertung der Messungen ist fertig."
    ///     afconvert -f WAVE -d LEI16@16000 -c 1 turn.aiff turn.wav
    ///
    /// then the turn trimmed to its first and last sample above |100| (about
    /// -50 dBFS) and laid on zeros from 12.0 s to 14.4 s, with 1 s of silence
    /// after it (15.4 s, 16 kHz mono 16-bit). With segment-level times the
    /// turn started at 0.0 s.
    func testTurnAfterLongSilenceStartsWhenSpoken() async throws {
        // This test downloads a WhisperKit model (~0.5 GB) - skip in CI
        try skipIfCIWithoutE2EOptIn("requires WhisperKit model download")

        try await assertTurnTranscribedWhenSpoken(by: WhisperKitEngine())
    }

    /// The same track with the vocabulary prompt on. WhisperKit 1.1.1 drops the
    /// prompt from a decode's returned tokens but keeps the prompt's rows in its
    /// word-alignment weights, so uncorrected, every word is aligned against
    /// the attention of a token one prompt length earlier: this turn ended at
    /// about 29 s, and on tracks with two turns in one window a whole turn went
    /// missing.
    func testPromptedTurnAfterLongSilenceKeepsItsWordTimes() async throws {
        // This test downloads a WhisperKit model (~0.5 GB) - skip in CI
        try skipIfCIWithoutE2EOptIn("requires WhisperKit model download")

        let vocabularyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("word-timestamps-vocabulary-\(UUID().uuidString).txt")
        try [
            "Projektstand", "Auswertung", "Messungen", "Ordner", "Treffen", "Zusammenfassung",
            "Budget", "Termin", "Protokoll", "Kickoff", "Meilenstein", "Lieferant",
        ].joined(separator: "\n").write(to: vocabularyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vocabularyFile) }

        let engine = WhisperKitEngine()
        engine.customVocabularyPath = vocabularyFile.path
        engine.vocabularyPromptEnabled = true

        try await assertTurnTranscribedWhenSpoken(by: engine)
        XCTAssertGreaterThan(engine.vocabularyPromptTokenCount, 20, "the vocabulary prompt must reach the decoder")
    }

    /// Transcribes `turn_after_silence_de.wav` with `openai_whisper-small` and
    /// checks that its one turn starts and ends within 2 s of when it is spoken.
    private func assertTurnTranscribedWhenSpoken(by engine: WhisperKitEngine) async throws {
        let spokenFrom: TimeInterval = 12.0
        let spokenTo: TimeInterval = 14.44

        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded, "Model should be loaded")

        let segments = try await engine.transcribeSegments(audioPath: fixtureURL("turn_after_silence_de.wav"))

        let turn = try XCTUnwrap(
            segments.first { segment in
                segment.text.localizedCaseInsensitiveContains("Auswertung")
                    || segment.text.localizedCaseInsensitiveContains("Messung")
            },
            "no segment of the turn in \(segments.map { "\($0.start)-\($0.end) \($0.text)" })",
        )
        XCTAssertEqual(
            turn.start, spokenFrom, accuracy: 2.0,
            "the turn spoken at \(spokenFrom) s starts at \(turn.start) s in the transcript",
        )
        XCTAssertEqual(
            turn.end, spokenTo, accuracy: 2.0,
            "the turn spoken until \(spokenTo) s ends at \(turn.end) s in the transcript",
        )
    }
}

/// Records the options each engine flow hands to the decoder.
@MainActor
private final class OptionsCapturingDecodingClient: WhisperDecodingClient {
    let tokenizer: (any WhisperTokenizer)? = nil
    private(set) var fileOptions: [DecodingOptions] = []
    private(set) var sampleOptions: [DecodingOptions] = []

    func transcribeFile(
        audioPaths _: [String],
        decodeOptions: DecodingOptions,
        callback _: TranscriptionCallback,
    ) -> [Result<[TranscriptionResult], any Error>] {
        fileOptions.append(decodeOptions)
        return [.success([])]
    }

    func transcribeSamples(_: [Float], decodeOptions: DecodingOptions) -> [TranscriptionResult] {
        sampleOptions.append(decodeOptions)
        return []
    }
}
