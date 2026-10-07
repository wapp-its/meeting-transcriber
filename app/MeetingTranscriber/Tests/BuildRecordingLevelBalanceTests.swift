import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// A dual-source capture with the headset gap the balancing exists for: the
/// far end at −18 dBFS and the own voice at −44 dBFS, alternating with gaps
/// wide enough that the echo gate never reaches an own-voice burst, both on a
/// −70 dBFS room tone. Shared by the tests that follow the balance flag from
/// the setting to a saved mix.
enum HeadsetGapFixture {
    private typealias Signal = LevelBalanceSignal

    static let rate = LevelBalanceSignal.sampleRate
    private static let cycles = 8
    private static let farEndDBFS = -18.0
    private static let ownVoiceDBFS = -44.0

    /// How far apart the two sides are as recorded, and so in a mix that
    /// leaves them alone.
    static let recordedGap = farEndDBFS - ownVoiceDBFS

    /// Bursts in [3k, 3k + 1) s.
    static let farEnd: [Float] = {
        var track = Signal.noise(dBFS: -70, seconds: Double(3 * cycles), seed: 21)
        for k in 0 ..< cycles {
            Signal.place(Signal.tone(dBFS: farEndDBFS, seconds: 1), in: &track, at: Double(3 * k))
        }
        return track
    }()

    /// Bursts in [3k + 1.5, 3k + 2.5) s.
    static let ownVoice: [Float] = {
        var track = Signal.noise(dBFS: -70, seconds: Double(3 * cycles), seed: 22)
        for k in 0 ..< cycles {
            Signal.place(Signal.tone(dBFS: ownVoiceDBFS, seconds: 1), in: &track, at: Double(3 * k) + 1.5)
        }
        return track
    }()

    /// Far-end level minus own-voice level in `mix`, each read inside its
    /// bursts and clear of their edges.
    static func gap(in mix: [Float]) -> Double {
        let farEndBursts = (0 ..< cycles).map { Double(3 * $0) + 0.1 ..< Double(3 * $0) + 0.9 }
        let ownVoiceBursts = (0 ..< cycles).map { Double(3 * $0) + 1.6 ..< Double(3 * $0) + 2.4 }
        return Signal.level(of: mix, over: farEndBursts) - Signal.level(of: mix, over: ownVoiceBursts)
    }
}

/// `buildRecording(…, levelBalance:)`, the step every finished recording and
/// every crash rescue goes through: the flag reaches the mix and nothing else.
/// The track files are what transcription, diarization and speaker
/// recognition read, so they must come out byte for byte the same either way.
final class BuildRecordingLevelBalanceTests: XCTestCase {
    private typealias Fixture = HeadsetGapFixture

    private let stem = "20260311_140000"

    /// Stage a 16 kHz mono capture, as the in-IOProc resampler writes it, in a
    /// folder of its own (the build consumes the raw app temp) and build it.
    private func build(levelBalance: Bool) throws -> RecordingResult {
        let dir = try makeTempDirectory(prefix: "build_level_balance")
        let appTmp = dir.appendingPathComponent(stem + RecordingFileSuffix.appRaw)
        try writeRawFloat32(Fixture.farEnd, to: appTmp)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: Fixture.ownVoice, sampleRate: Fixture.rate, url: micWav)

        return try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: Fixture.rate, actualChannels: 1, micDelay: 0,
            ),
            recordingsDir: dir, timestamp: stem,
            recordingStartDate: Date(timeIntervalSince1970: 1000),
            format: CaptureFormat(requestedChannels: 1, requestedRate: Fixture.rate, targetRate: Fixture.rate),
            levelBalance: levelBalance,
        )
    }

    func testTheFlagBringsBothSidesOfTheMixWithinSixDecibels() throws {
        let mix = try AudioMixer.loadAudioFileAsFloat32(url: build(levelBalance: true).mixPath)

        XCTAssertLessThanOrEqual(abs(Fixture.gap(in: mix)), 6)
    }

    func testTheTrackFilesAreByteIdenticalWithTheFlagOnAndOff() throws {
        let off = try build(levelBalance: false)
        let on = try build(levelBalance: true)

        XCTAssertNotEqual(
            try Data(contentsOf: off.mixPath), try Data(contentsOf: on.mixPath),
            "test premise: the flag changed the mix",
        )
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(off.appPath)), try Data(contentsOf: XCTUnwrap(on.appPath)))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(off.micPath)), try Data(contentsOf: XCTUnwrap(on.micPath)))
    }

    /// Today's mixer, spelled out: the echo gate over the two track files as
    /// written, then the average, through the same 16-bit file round trip.
    func testWithoutTheFlagTheMixIsTodaysMixer() throws {
        let result = try build(levelBalance: false)

        let app = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(result.appPath))
        var mic = try AudioMixer.loadAudioFileAsFloat32(url: XCTUnwrap(result.micPath))
        AudioMixer.suppressEcho(appSamples: app, micSamples: &mic, sampleRate: Fixture.rate)
        let expected = makeTempFile(suffix: ".wav")
        try AudioMixer.saveWAV(samples: AudioMixer.mixTracks(app, mic), sampleRate: Fixture.rate, url: expected)

        XCTAssertEqual(
            try AudioMixer.loadAudioFileAsFloat32(url: result.mixPath),
            try AudioMixer.loadAudioFileAsFloat32(url: expected),
        )
    }
}
