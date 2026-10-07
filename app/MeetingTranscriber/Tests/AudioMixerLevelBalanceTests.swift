@testable import MeetingTranscriber
import XCTest

/// `AudioMixer.mix(…, levelBalance:)`: the two tracks reach the mix at a
/// common speech level, the echo gate decides exactly as before, and with the
/// flag off nothing changes.
final class AudioMixerLevelBalanceTests: XCTestCase {
    private typealias Signal = LevelBalanceSignal

    private let rate = LevelBalanceSignal.sampleRate
    private let cycles = 8
    /// The target as it shows in the mix: `mixTracks` averages, so a track
    /// whose other side is silent lands 6 dB under its own level.
    private let targetInMix = LevelBalance.targetDBFS + 20 * log10(0.5)

    /// Far-end bursts in [3k, 3k + 1) s and own-voice bursts in
    /// [3k + 1.5, 3k + 2.5) s: alternating, with gaps of at least 0.5 s, so
    /// the gate's 200 ms hang never reaches an own-voice burst. Both tracks
    /// sit on a −70 dBFS noise bed, the room tone that makes speech measurable.
    private func appTrack(dBFS: Double) -> [Float] {
        var track = Signal.noise(dBFS: -70, seconds: Double(3 * cycles), seed: 11)
        for k in 0 ..< cycles {
            Signal.place(Signal.tone(dBFS: dBFS, seconds: 1), in: &track, at: Double(3 * k))
        }
        return track
    }

    private func micTrack(ownVoiceDBFS: Double, bleedDBFS: Double? = nil) -> [Float] {
        var track = Signal.noise(dBFS: -70, seconds: Double(3 * cycles), seed: 12)
        for k in 0 ..< cycles {
            if let bleedDBFS {
                Signal.place(Signal.tone(dBFS: bleedDBFS, seconds: 1), in: &track, at: Double(3 * k))
            }
            Signal.place(Signal.tone(dBFS: ownVoiceDBFS, seconds: 1), in: &track, at: Double(3 * k) + 1.5)
        }
        return track
    }

    /// The inside of each burst, clear of its edges.
    private var appBursts: [Range<Double>] {
        (0 ..< cycles).map { Double(3 * $0) + 0.1 ..< Double(3 * $0) + 0.9 }
    }

    private var ownVoiceBursts: [Range<Double>] {
        (0 ..< cycles).map { Double(3 * $0) + 1.6 ..< Double(3 * $0) + 2.4 }
    }

    /// The samples as the mixer reads them back from a 16-bit WAV.
    private func roundTrip(_ samples: [Float]) throws -> [Float] {
        let url = makeTempFile(suffix: ".wav")
        try AudioMixer.saveWAV(samples: samples, sampleRate: rate, url: url)
        return try AudioMixer.loadAudioFileAsFloat32(url: url)
    }

    private func mix(app: [Float], mic: [Float], levelBalance: Bool) throws -> [Float] {
        let appURL = makeTempFile(suffix: ".wav")
        let micURL = makeTempFile(suffix: ".wav")
        let outURL = makeTempFile(suffix: ".wav")
        try AudioMixer.saveWAV(samples: app, sampleRate: rate, url: appURL)
        try AudioMixer.saveWAV(samples: mic, sampleRate: rate, url: micURL)
        try AudioMixer.mix(
            appAudioPath: appURL,
            micAudioPath: micURL,
            outputPath: outURL,
            sampleRate: rate,
            levelBalance: levelBalance,
        )
        return try AudioMixer.loadAudioFileAsFloat32(url: outURL)
    }

    // MARK: - R1, R2

    func testBalancingBringsOwnVoiceAndFarEndWithinSixDecibelsInTheMix() throws {
        let mixed = try mix(app: appTrack(dBFS: -18), mic: micTrack(ownVoiceDBFS: -44), levelBalance: true)

        let farEnd = Signal.level(of: mixed, over: appBursts)
        let ownVoice = Signal.level(of: mixed, over: ownVoiceBursts)
        XCTAssertLessThanOrEqual(abs(farEnd - ownVoice), 6)
        XCTAssertEqual(farEnd, targetInMix, accuracy: 1)
        XCTAssertEqual(ownVoice, targetInMix, accuracy: 1)
        XCTAssertLessThanOrEqual(mixed.map(abs).max() ?? 0, 1)
    }

    func testWithoutTheFlagTheMixIsTodaysMixer() throws {
        let app = appTrack(dBFS: -18)
        let mic = micTrack(ownVoiceDBFS: -44)
        let mixed = try mix(app: app, mic: mic, levelBalance: false)

        let appRead = try roundTrip(app)
        var micRead = try roundTrip(mic)
        AudioMixer.suppressEcho(appSamples: appRead, micSamples: &micRead, sampleRate: rate)
        XCTAssertEqual(mixed, try roundTrip(AudioMixer.mixTracks(appRead, micRead)))
    }

    // MARK: - R3, A5

    /// The app track is exactly zero between its bursts, so wherever the gate
    /// silenced the microphone the mix is exactly zero, and the zeros of the
    /// mix are the gated windows. The −30 dBFS bursts close the gate; the
    /// −45 dBFS ones stay under its 0.01 RMS threshold, but balancing lifts
    /// them to about −35 dBFS, which would close it if the gate were decided
    /// on the balanced track.
    func testTheEchoGateSilencesTheSameMicWindowsWithTheFlagOnAndOff() throws {
        var app = [Float](repeating: 0, count: 12 * rate)
        for k in 0 ..< 6 {
            let start = Double(2 * k)
            Signal.place(Signal.positiveNoise(dBFS: -30, seconds: 1, seed: UInt64(k)), in: &app, at: start)
            Signal.place(Signal.positiveNoise(dBFS: -45, seconds: 0.4, seed: UInt64(100 + k)), in: &app, at: start + 1.4)
        }
        let mic = Signal.positiveNoise(dBFS: -40, seconds: 12, seed: 99)

        let appRead = try roundTrip(app)
        var gatedMic = try roundTrip(mic)
        AudioMixer.suppressEcho(appSamples: appRead, micSamples: &gatedMic, sampleRate: rate)
        let gatedZeros = appRead.indices.filter { appRead[$0] == 0 && gatedMic[$0] == 0 }
        XCTAssertFalse(gatedZeros.isEmpty)

        for levelBalance in [false, true] {
            let mixed = try mix(app: app, mic: mic, levelBalance: levelBalance)
            XCTAssertEqual(mixed.indices.filter { mixed[$0] == 0 }, gatedZeros, "levelBalance: \(levelBalance)")
        }
    }

    /// Loudspeakers: the microphone carries a −30 dBFS copy of the far end
    /// while it plays, and the own voice at −44 dBFS while it does not. The
    /// gate removes the copy before the microphone is measured, so the own
    /// voice is raised to the target. Measured with the copy, the level would
    /// read about −33 dBFS and the own voice would land some 11 dB short.
    func testFarEndBleedOnTheMicIsNotMeasuredAsOwnVoice() throws {
        let mixed = try mix(
            app: appTrack(dBFS: -18),
            mic: micTrack(ownVoiceDBFS: -44, bleedDBFS: -30),
            levelBalance: true,
        )

        XCTAssertEqual(Signal.level(of: mixed, over: ownVoiceBursts), targetInMix, accuracy: 1)
    }

    // MARK: - Limits

    func testAnAllZeroMicStaysZeroWhileTheAppIsBalanced() throws {
        let app = appTrack(dBFS: -30)
        let silence = [Float](repeating: 0, count: app.count)
        let mixed = try mix(app: app, mic: silence, levelBalance: true)

        var balancedApp = try roundTrip(app)
        let outcome = LevelBalance.balance(
            &balancedApp, sampleRate: rate, minimumSpeechSeconds: LevelBalance.trackMinimumSpeechSeconds,
        )
        XCTAssertEqual(outcome.gainDB, 10, accuracy: 0.1)
        XCTAssertEqual(mixed, try roundTrip(AudioMixer.mixTracks(balancedApp, silence)))
    }

    /// 200 transients at 0.08 in the own-voice bursts: the +23 dB the speech
    /// wants would put them all beyond full scale, far over the 0.1 % budget
    /// (128 of 128 000 speech-frame samples).
    func testAClipLimitedMicIsRaisedExactlyToTheLimitAndStaysBelowTheTarget() throws {
        let app = appTrack(dBFS: -18)
        var mic = micTrack(ownVoiceDBFS: -44)
        for burst in ownVoiceBursts {
            for n in 0 ..< 25 {
                mic[Signal.sampleIndex(at: burst.lowerBound) + 500 * n + 37] = 0.08
            }
        }
        let mixed = try mix(app: app, mic: mic, levelBalance: true)

        var balancedApp = try roundTrip(app)
        var balancedMic = try roundTrip(mic)
        AudioMixer.suppressEcho(appSamples: balancedApp, micSamples: &balancedMic, sampleRate: rate)
        let minimum = LevelBalance.trackMinimumSpeechSeconds
        _ = LevelBalance.balance(&balancedApp, sampleRate: rate, minimumSpeechSeconds: minimum)
        let micOutcome = LevelBalance.balance(&balancedMic, sampleRate: rate, minimumSpeechSeconds: minimum)

        XCTAssertEqual(micOutcome.limit, .clipBudget)
        let micLevel = try XCTUnwrap(micOutcome.speechLevelDBFS)
        XCTAssertLessThan(micOutcome.gainDB, LevelBalance.targetDBFS - micLevel)
        XCTAssertEqual(mixed, try roundTrip(AudioMixer.mixTracks(balancedApp, balancedMic)))
        XCTAssertLessThan(Signal.level(of: mixed, over: ownVoiceBursts), targetInMix)
        XCTAssertLessThanOrEqual(mixed.map(abs).max() ?? 0, 1)
    }
}
