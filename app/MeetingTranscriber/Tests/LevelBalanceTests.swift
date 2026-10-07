@testable import MeetingTranscriber
import XCTest

/// Deterministic signals at known levels for the level-balance tests: sine
/// bursts with whole periods per 100 ms frame, and noise from a seeded
/// generator (never an unseeded `Float.random`), so every run measures the
/// same numbers.
enum LevelBalanceSignal {
    static let sampleRate = 16000

    /// SplitMix64: a fixed seed gives the same noise on every run and machine.
    struct Generator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func sampleIndex(at seconds: Double) -> Int {
        Int((seconds * Double(sampleRate)).rounded())
    }

    /// 400 Hz sine: 40 whole periods per 100 ms frame at 16 kHz, so every
    /// frame of a burst measures exactly `dBFS`. A sine of amplitude A has
    /// RMS A/√2.
    static func tone(dBFS: Double, seconds: Double) -> [Float] {
        let amplitude = 2.0.squareRoot() * pow(10, dBFS / 20)
        return (0 ..< sampleIndex(at: seconds)).map { n in
            Float(amplitude * sin(2 * Double.pi * 400 * Double(n) / Double(sampleRate)))
        }
    }

    /// Uniform noise in ±a, which has RMS a/√3.
    static func noise(dBFS: Double, seconds: Double, seed: UInt64) -> [Float] {
        let amplitude = Float(3.0.squareRoot() * pow(10, dBFS / 20))
        var generator = Generator(seed: seed)
        return (0 ..< sampleIndex(at: seconds)).map { _ in
            Float.random(in: -amplitude ... amplitude, using: &generator)
        }
    }

    /// Positive noise with magnitudes in [a/2, a]: no sample is zero, even
    /// after a 16-bit round trip, and two such tracks never cancel when
    /// averaged. RMS a·√(7/12).
    static func positiveNoise(dBFS: Double, seconds: Double, seed: UInt64) -> [Float] {
        let amplitude = Float(pow(10, dBFS / 20) / (7.0 / 12).squareRoot())
        var generator = Generator(seed: seed)
        return (0 ..< sampleIndex(at: seconds)).map { _ in
            Float.random(in: amplitude / 2 ... amplitude, using: &generator)
        }
    }

    /// Overwrites `track` with `burst` from `start` seconds on.
    static func place(_ burst: [Float], in track: inout [Float], at start: Double) {
        let first = sampleIndex(at: start)
        track.replaceSubrange(first ..< first + burst.count, with: burst)
    }

    /// RMS in dBFS of `samples` over the given stretches (in seconds) together.
    static func level(of samples: [Float], over stretches: [Range<Double>]) -> Double {
        var sumOfSquares = 0.0
        var count = 0
        for stretch in stretches {
            for index in sampleIndex(at: stretch.lowerBound) ..< sampleIndex(at: stretch.upperBound) {
                sumOfSquares += Double(samples[index]) * Double(samples[index])
                count += 1
            }
        }
        return 10 * log10(sumOfSquares / Double(count))
    }
}

final class LevelBalanceTests: XCTestCase {
    private typealias Signal = LevelBalanceSignal
    private typealias Outcome = LevelBalance.Outcome

    private let rate = LevelBalanceSignal.sampleRate
    private let trackMinimum = LevelBalance.trackMinimumSpeechSeconds
    private let sampleMinimum = LevelBalance.sampleMinimumSpeechSeconds

    /// A −70 dBFS noise bed with `speechSeconds` of tone bursts at `dBFS`,
    /// spread evenly over the track in bursts of at most 1 s that start on a
    /// frame boundary. Returns the samples and the bursts' sample ranges.
    private func speechTrack(
        seconds: Double,
        speechSeconds: Double,
        dBFS: Double,
    ) -> (samples: [Float], speech: [Range<Int>]) {
        var samples = Signal.noise(dBFS: -70, seconds: seconds, seed: 1)
        let burstSeconds = min(1, speechSeconds)
        let bursts = Int((speechSeconds / burstSeconds).rounded())
        let spacing = seconds / Double(bursts)
        let speech = (0 ..< bursts).map { burst in
            let start = Double(burst) * spacing
            Signal.place(Signal.tone(dBFS: dBFS, seconds: burstSeconds), in: &samples, at: start)
            return Signal.sampleIndex(at: start) ..< Signal.sampleIndex(at: start + burstSeconds)
        }
        return (samples, speech)
    }

    // MARK: - Speech level estimate

    func testTheEstimateMatchesTheBurstLevelWhetherSpeechIsDenseOrSparse() throws {
        let cases: [(seconds: Double, speech: Double, minimum: Double)] = [
            (20, 10, trackMinimum), // speech fills 50 %
            (120, 6, trackMinimum), // speech fills 5 %, still above the 5 s minimum
            (2, 0.6, sampleMinimum), // a naming sample just above its 0.5 s minimum
        ]
        for c in cases {
            let samples = speechTrack(seconds: c.seconds, speechSeconds: c.speech, dBFS: -32).samples
            let level = LevelBalance.measure(samples, sampleRate: rate, minimumSpeechSeconds: c.minimum).speechLevelDBFS
            XCTAssertEqual(try XCTUnwrap(level, "\(c)"), -32, accuracy: 1, "\(c)")
        }
    }

    func testATrackWithoutEnoughMeasurableSpeechIsLeftAtItsLevel() {
        let cases: [(name: String, samples: [Float], minimum: Double)] = [
            ("digital zeros", [Float](repeating: 0, count: 20 * rate), trackMinimum),
            ("steady -50 dBFS noise", Signal.noise(dBFS: -50, seconds: 20, seed: 7), trackMinimum),
            ("3 s of speech in 60 s", speechTrack(seconds: 60, speechSeconds: 3, dBFS: -32).samples, trackMinimum),
            ("0.4 s of speech in a sample", speechTrack(seconds: 2, speechSeconds: 0.4, dBFS: -32).samples, sampleMinimum),
        ]
        for c in cases {
            var balanced = c.samples
            let outcome = LevelBalance.balance(&balanced, sampleRate: rate, minimumSpeechSeconds: c.minimum)
            XCTAssertEqual(outcome, Outcome(speechLevelDBFS: nil, gainDB: 0, limit: nil), c.name)
            XCTAssertEqual(balanced, c.samples, c.name)
        }
    }

    // MARK: - Gain

    func testTheGainReachesTheTargetStopsAtTheBoostCapAndCutsWithoutBound() {
        let cases: [(dBFS: Double, gain: Double, limit: LevelBalance.Limit?)] = [
            (-30, 10, nil),
            (-50, LevelBalance.maxBoostDB, .boostCap),
            // +6 dBFS: samples beyond full scale, cut by more than the boost cap allows upwards.
            (6, -26, nil),
        ]
        for c in cases {
            let track = speechTrack(seconds: 20, speechSeconds: 10, dBFS: c.dBFS)
            var samples = track.samples
            let outcome = LevelBalance.balance(&samples, sampleRate: rate, minimumSpeechSeconds: trackMinimum)
            XCTAssertEqual(outcome.gainDB, c.gain, accuracy: 0.05, "\(c)")
            XCTAssertEqual(outcome.limit, c.limit, "\(c)")
            let speechAfter = AudioMixer.rmsDecibels(samples: track.speech.flatMap { samples[$0] })
            XCTAssertEqual(Double(speechAfter), c.dBFS + c.gain, accuracy: 0.05, "\(c)")
            XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1, "\(c)")
        }
    }

    /// −40 dBFS speech wants about +17 dB, and its transients (magnitudes
    /// spread over 0.05…0.3) would put far more than 0.1 % of the speech-frame
    /// samples beyond full scale at that gain. The reference is computed the
    /// slow way, by sorting the speech-frame samples: the largest gain that
    /// keeps at most the budget beyond full scale is the one that lifts the
    /// (budget + 1)-th largest magnitude exactly to full scale.
    func testTheClipBudgetLowersABoostToTheLargestGainItAllows() throws {
        for (seconds, speechSeconds) in [(20.0, 10.0), (120.0, 6.0)] {
            let track = speechTrack(seconds: seconds, speechSeconds: speechSeconds, dBFS: -40)
            let speech = track.speech
            var samples = track.samples
            let transients = speech.flatMap { range in stride(from: range.lowerBound + 100, to: range.upperBound, by: 397) }
            for (k, index) in transients.enumerated() {
                let magnitude = 0.05 + 0.25 * Float(k) / Float(transients.count - 1)
                samples[index] = k.isMultiple(of: 2) ? magnitude : -magnitude
            }
            let speechSamples = speech.flatMap { samples[$0] }
            let budget = Int(Double(speechSamples.count) * LevelBalance.clipBudget)
            let magnitudes = speechSamples.map { Double(abs($0)) }.sorted(by: >)
            let largestAllowed = -20 * log10(magnitudes[budget])

            var balanced = samples
            let outcome = LevelBalance.balance(&balanced, sampleRate: rate, minimumSpeechSeconds: trackMinimum)

            let label = "\(seconds) s track, \(speechSeconds) s speech"
            let level = try XCTUnwrap(outcome.speechLevelDBFS, label)
            XCTAssertGreaterThan(LevelBalance.targetDBFS - level, largestAllowed, "the budget must bind: \(label)")
            XCTAssertEqual(outcome.limit, .clipBudget, label)
            XCTAssertLessThanOrEqual(outcome.gainDB, largestAllowed, label)
            XCTAssertGreaterThanOrEqual(outcome.gainDB, largestAllowed - LevelBalance.clipSearchStepDB, label)
            let factor = pow(10, outcome.gainDB / 20)
            XCTAssertLessThanOrEqual(magnitudes.prefix { $0 * factor > 1 }.count, budget, label)
            XCTAssertLessThanOrEqual(balanced.map(abs).max() ?? 0, 1, label)
        }
    }

    // MARK: - Log line

    func testTheLogLineCarriesOnlyLevelsGainsAndLimits() {
        let cases: [(app: Outcome, mic: Outcome, line: String)] = [
            (
                Outcome(speechLevelDBFS: -18.43, gainDB: -1.57, limit: nil),
                Outcome(speechLevelDBFS: -44.9, gainDB: 24, limit: .boostCap),
                "Level balance: app speech -18.4 dBFS gain -1.6 dB; mic speech -44.9 dBFS gain +24.0 dB (boost cap)",
            ),
            (
                Outcome(speechLevelDBFS: -30, gainDB: 9.96, limit: .clipBudget),
                Outcome(speechLevelDBFS: nil, gainDB: 0, limit: nil),
                "Level balance: app speech -30.0 dBFS gain +10.0 dB (clip budget); mic not measurable, gain 0 dB",
            ),
        ]
        for c in cases {
            XCTAssertEqual(LevelBalance.logLine(app: c.app, mic: c.mic), c.line)
        }
    }
}
