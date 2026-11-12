import CoreML
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

    // MARK: - Prompt rows in the word alignment (no model)

    /// The rows match what WhisperKit prefills ahead of `<|startoftranscript|>`:
    /// `<|startofprev|>` plus the prompt tokens it keeps, none without a prompt.
    func testPromptRowCountMatchesWhatWhisperKitPrefills() {
        let specialTokenBegin = 50257
        func rows(_ promptTokens: [Int]?) -> Int { // swiftlint:disable:this discouraged_optional_collection
            PromptAlignedSegmentSeeker.promptRowCount(
                for: DecodingOptions(promptTokens: promptTokens),
                specialTokenBegin: specialTokenBegin,
            )
        }

        XCTAssertEqual(rows(nil), 0)
        XCTAssertEqual(rows([]), 0)
        XCTAssertEqual(rows([101, 102]), 3)
        XCTAssertEqual(rows([101, specialTokenBegin + 3, 102]), 3, "special tokens are not prefilled")
        XCTAssertEqual(rows([specialTokenBegin + 3]), 0, "a prompt with nothing left is not sent")
        XCTAssertEqual(
            rows(Array(repeating: 101, count: 300)), Constants.maxTokenContext / 2,
            "only the last maxTokenContext / 2 - 1 prompt tokens are prefilled",
        )
    }

    // MLMultiArray's subscript takes NSNumber indices and values.
    // swiftlint:disable legacy_objc_type
    func testDroppingLeadingRowsMovesRowsUpAndZeroFillsTheTail() throws {
        let weights = try MLMultiArray(shape: [4, 3], dataType: .float16)
        for row in 0 ..< 4 {
            for column in 0 ..< 3 {
                weights[[row, column] as [NSNumber]] = NSNumber(value: row * 10 + column + 1)
            }
        }

        let shifted = try XCTUnwrap(PromptAlignedSegmentSeeker.droppingLeadingRows(1, of: weights))
        let unshifted = try XCTUnwrap(PromptAlignedSegmentSeeker.droppingLeadingRows(0, of: weights))

        func values(_ array: MLMultiArray) -> [[Int]] {
            (0 ..< 4).map { row in (0 ..< 3).map { column in array[[row, column] as [NSNumber]].intValue } }
        }
        XCTAssertEqual(values(shifted), [[11, 12, 13], [21, 22, 23], [31, 32, 33], [0, 0, 0]])
        XCTAssertEqual(values(unshifted), [[1, 2, 3], [11, 12, 13], [21, 22, 23], [31, 32, 33]])
        XCTAssertEqual(values(weights)[0], [1, 2, 3], "the passed-in weights are reused by WhisperKit and stay as they were")
    }

    // swiftlint:enable legacy_objc_type

    func testDroppingLeadingRowsGivesUpOnAnUnexpectedLayout() throws {
        let weights = try MLMultiArray(shape: [2, 3, 4], dataType: .float16)
        XCTAssertNil(try PromptAlignedSegmentSeeker.droppingLeadingRows(1, of: weights))
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
