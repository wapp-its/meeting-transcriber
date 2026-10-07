@testable import MeetingTranscriber
import XCTest

/// With the level-balance setting on, a naming-dialog voice sample is brought
/// to the target speech level on its own before it plays, so a quiet own-voice
/// sample and a loud far-end one play at a similar loudness. The helper gets
/// the whole decoded file and the range to cut from it; the rest of the file
/// carries speech at a contrasting level, which must not move the sample's gain.
/// A diarized sample is speech from start to end, so only the pauses around it
/// carry the file's −70 dBFS room tone.
final class SpeakerSampleLevelTests: XCTestCase {
    private typealias Signal = LevelBalanceSignal

    /// The sample spans 1.5 s from 3 s into a 10 s file, on frame boundaries:
    /// the shortest segment the dialog picks, between the 0.5 s sample minimum
    /// and the 5 s track minimum, so only the sample minimum makes it measurable.
    private let cutStart = 3.0
    private let cutSeconds = 1.5
    /// Room tone only, on each side of the cut.
    private let pauseSeconds = 1.0

    /// A 10 s file at `Signal.sampleRate` on a −70 dBFS noise bed: tone at
    /// `surroundingDBFS` everywhere but the cut and the pause on each side of
    /// it, and `speechSeconds` of tone at `speechDBFS` from the start of the
    /// cut, carrying `transients` single samples at ±0.15, one per frame (up to
    /// 8 in 1.5 s of speech).
    private func decodedFile(
        speechDBFS: Double,
        speechSeconds: Double,
        surroundingDBFS: Double,
        transients: Int = 0,
    ) -> [Float] {
        var samples = Signal.noise(dBFS: -70, seconds: 10, seed: 3)
        let before = cutStart - pauseSeconds
        let after = cutStart + cutSeconds + pauseSeconds
        Signal.place(Signal.tone(dBFS: surroundingDBFS, seconds: before), in: &samples, at: 0)
        Signal.place(Signal.tone(dBFS: surroundingDBFS, seconds: 10 - after), in: &samples, at: after)
        Signal.place(Signal.tone(dBFS: speechDBFS, seconds: speechSeconds), in: &samples, at: cutStart)
        let speech = Signal.sampleIndex(at: cutStart) ..< Signal.sampleIndex(at: cutStart + speechSeconds)
        for k in 0 ..< transients {
            samples[speech.lowerBound + 1000 + k * 2903] = k.isMultiple(of: 2) ? 0.15 : -0.15
        }
        return samples
    }

    private func cut(rate: Int) -> Range<Int> {
        Int(cutStart * Double(rate)) ..< Int((cutStart + cutSeconds) * Double(rate))
    }

    func testWithTheFlagASampleIsBroughtToTheTargetSpeechLevel() {
        let cases: [(name: String, speechDBFS: Double, surroundingDBFS: Double, transients: Int)] = [
            // +20 dB lifts the transients far beyond full scale; there are
            // fewer than the clip budget allows, so they are clamped instead
            // of lowering the boost.
            ("quiet own voice", -40, -8, 8),
            ("loud far end", -8, -40, 0),
        ]
        for c in cases {
            let file = decodedFile(
                speechDBFS: c.speechDBFS, speechSeconds: cutSeconds,
                surroundingDBFS: c.surroundingDBFS, transients: c.transients,
            )
            let played = SpeakerNamingView.playbackSnippet(
                of: file, range: cut(rate: Signal.sampleRate), sampleRate: Signal.sampleRate, balanced: true,
            )
            XCTAssertEqual(Signal.level(of: played, over: [0 ..< cutSeconds]), LevelBalance.targetDBFS, accuracy: 1, c.name)
            XCTAssertLessThanOrEqual(played.map(abs).max() ?? 0, 1, c.name)
            if c.transients > 0 {
                XCTAssertEqual(played.map(abs).max(), 1, "the transients must reach full scale: \(c.name)")
            }
        }
    }

    /// Flag off, the sample plays as cut. Flag on, a sample with under 0.5 s
    /// of measurable speech plays as cut too, including from a 48 kHz mix
    /// fallback, where the file's own rate decides how long 0.4 s is.
    func testThePlainCutPlaysWithTheFlagOffOrWithoutEnoughSpeech() {
        let cases: [(name: String, speechSeconds: Double, rate: Int, balanced: Bool)] = [
            ("flag off", cutSeconds, Signal.sampleRate, false),
            ("0.4 s of speech", 0.4, Signal.sampleRate, true),
            ("0.4 s of speech at 48 kHz", 0.4, 48000, true),
        ]
        for c in cases {
            let atSourceRate = decodedFile(speechDBFS: -40, speechSeconds: c.speechSeconds, surroundingDBFS: -8)
            // Holding each sample keeps every frame's level at the higher rate.
            let file = atSourceRate.flatMap { [Float](repeating: $0, count: c.rate / Signal.sampleRate) }
            let range = cut(rate: c.rate)
            let played = SpeakerNamingView.playbackSnippet(of: file, range: range, sampleRate: c.rate, balanced: c.balanced)
            XCTAssertEqual(played, Array(file[range]), c.name)
        }
    }
}
