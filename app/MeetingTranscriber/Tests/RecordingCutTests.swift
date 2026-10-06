import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// `RecordingCut` against real WAV files: every track ends at the same point on
/// the recording's timeline, keeps exactly what it held before that point, and
/// a cut that fails anywhere leaves every original exactly as it was.
final class RecordingCutTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "recording-cut")
    }

    // MARK: - Helpers

    /// A 16 kHz track of `seconds`, holding a ramp so a kept prefix can be
    /// compared sample by sample.
    private func makeTrack(_ name: String, seconds: Double) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let samples = (0 ..< Int(seconds * 16000)).map { Float($0 % 1000) / 2000 }
        try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
        return url
    }

    private func recording(
        mix: URL, app: URL?, mic: URL?, micDelay: TimeInterval = 0,
    ) -> RecordingResult {
        RecordingResult(mixPath: mix, appPath: app, micPath: mic, micDelay: micDelay, recordingStartDate: Date())
    }

    private func contents(_ urls: [URL]) throws -> [Data] {
        try urls.map { try Data(contentsOf: $0) }
    }

    /// Files the cut may leave behind, which it must not.
    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).filter { $0.hasPrefix(".") }
    }

    // MARK: - Where each track sits

    /// The source tracks sit where the mixer placed them: shifted only when
    /// both exist, by the clamped delay, the late one later.
    func testTrackOffsetsFollowTheMixersAlignment() {
        let mix = URL(fileURLWithPath: "/r/mix.wav")
        let mic = URL(fileURLWithPath: "/r/mic.wav")
        let appURL = URL(fileURLWithPath: "/r/app.wav")
        let cases: [(app: URL?, delay: TimeInterval, appOffset: TimeInterval?, micOffset: TimeInterval)] = [
            (appURL, 0.5, 0, 0.5),
            (appURL, -0.5, 0.5, 0),
            (appURL, 45, 0, AudioMixer.maxMicDelay),
            (nil, 0.7, nil, 0),
        ]
        for (app, delay, appOffset, micOffset) in cases {
            let tracks = RecordingCut.tracks(of: recording(mix: mix, app: app, mic: mic, micDelay: delay))
            XCTAssertEqual(tracks.first, RecordingCut.Track(url: mix, offset: 0), "the mix is the timeline")
            XCTAssertEqual(tracks.first { $0.url == app }?.offset, appOffset, "app, delay \(delay)")
            XCTAssertEqual(tracks.first { $0.url == mic }?.offset, micOffset, "mic, delay \(delay)")
        }
    }

    // MARK: - The cut

    /// Kept at 4 s with the microphone starting 0.5 s late: mix and app keep
    /// 4 s, the microphone 3.5 s, and every kept frame is the original's.
    func testEveryTrackEndsAtTheSamePointAndKeepsItsOwnAudio() throws {
        let mix = try makeTrack("r_mix.wav", seconds: 10)
        let app = try makeTrack("r_app.wav", seconds: 10)
        let mic = try makeTrack("r_mic.wav", seconds: 9.5)
        let before = try [mix, app, mic].map { try AudioMixer.loadAudioFileAsFloat32(url: $0) }

        try RecordingCut.apply(to: recording(mix: mix, app: app, mic: mic, micDelay: 0.5), keepingFirst: 4)

        let after = try [mix, app, mic].map { try AudioMixer.loadAudioFileAsFloat32(url: $0) }
        XCTAssertEqual(after.map(\.count), [64000, 64000, 56000])
        for (kept, original) in zip(after, before) {
            XCTAssertEqual(kept, Array(original.prefix(kept.count)), "a cut keeps the track's own first frames")
        }
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: mix.path)[.posixPermissions] as? Int, 0o600,
            "a cut track keeps the recording's owner-only permissions",
        )
        XCTAssertEqual(try leftovers(), [])
    }

    func testATrackAlreadyEndingBeforeTheCutIsLeftAsItIs() throws {
        let mix = try makeTrack("r_mix.wav", seconds: 10)
        let app = try makeTrack("r_app.wav", seconds: 3)
        let appBefore = try Data(contentsOf: app)

        try RecordingCut.apply(to: recording(mix: mix, app: app, mic: nil), keepingFirst: 4)

        XCTAssertEqual(try Data(contentsOf: app), appBefore)
        XCTAssertEqual(try AVAudioFile(forReading: mix).length, 64000)
    }

    // MARK: - Failures leave every original as it was

    /// An unreadable track fails the cut before anything is written.
    func testAnUnreadableTrackFailsTheCutAndTouchesNothing() throws {
        let mix = try makeTrack("r_mix.wav", seconds: 10)
        let app = try makeTrack("r_app.wav", seconds: 10)
        let mic = tmpDir.appendingPathComponent("r_mic.wav")
        try Data("not audio".utf8).write(to: mic)
        let before = try contents([mix, app, mic])

        XCTAssertThrowsError(try RecordingCut.apply(to: recording(mix: mix, app: app, mic: mic), keepingFirst: 4))

        XCTAssertEqual(try contents([mix, app, mic]), before)
        XCTAssertEqual(try leftovers(), [])
    }

    /// A rename that fails from the `failingFrom`th call on.
    private func renameFailing(from failingFrom: Int, only: Bool) -> (URL, URL) throws -> Void {
        var calls = 0
        return { source, destination in
            calls += 1
            if calls == failingFrom || (!only && calls > failingFrom) { throw POSIXError(.EIO) }
            try RecordingCut.rename(source, destination)
        }
    }

    /// The second track's swap fails after the first is in: the first is put
    /// back, so no track stays cut while another is not.
    func testAFailedSwapPutsEveryTrackBack() throws {
        let mix = try makeTrack("r_mix.wav", seconds: 10)
        let app = try makeTrack("r_app.wav", seconds: 10)
        let mic = try makeTrack("r_mic.wav", seconds: 10)
        let before = try contents([mix, app, mic])

        XCTAssertThrowsError(try RecordingCut.apply(
            to: recording(mix: mix, app: app, mic: mic), keepingFirst: 4, rename: renameFailing(from: 2, only: true),
        ))

        XCTAssertEqual(try contents([mix, app, mic]), before, "every track as recorded")
        XCTAssertEqual(try leftovers(), [])
    }

    /// Renames keep failing, so the mix, already swapped in, cannot be put
    /// back. Its original survives under its second name, the error names it,
    /// and the redirected recording reads every track as recorded.
    func testAnOriginalThatCannotBePutBackIsKeptAndNamed() throws {
        let mix = try makeTrack("r_mix.wav", seconds: 10)
        let app = try makeTrack("r_app.wav", seconds: 10)
        let mic = try makeTrack("r_mic.wav", seconds: 10)
        let before = try contents([mix, app, mic])
        let cut = recording(mix: mix, app: app, mic: mic)

        var uncut: [URL: URL] = [:]
        XCTAssertThrowsError(
            try RecordingCut.apply(to: cut, keepingFirst: 4, rename: renameFailing(from: 2, only: false)),
        ) { error in
            if case let RecordingCut.CutError.rollbackIncomplete(moved) = error { uncut = moved }
        }

        XCTAssertEqual(Array(uncut.keys), [mix], "only the swapped-in mix could not be put back")
        let redirected = RecordingCut.redirect(cut, to: uncut)
        let paths = try [redirected.mixPath, XCTUnwrap(redirected.appPath), XCTUnwrap(redirected.micPath)]
        XCTAssertEqual(try contents(paths), before, "the recording is processed uncut")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mix.path), "the cut copy is not left posing as the mix")
    }

    // MARK: - Where the cut falls

    /// The later of the two estimates wins, so neither a capture that started
    /// before the recorder returned nor a track that stopped delivering cuts
    /// into the meeting. Started at 0, cut at 10, stopped at 130 (s).
    func testTheCutPointIsTheLaterOfTheStartAndEndEstimates() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(mix: TimeInterval?, kept: TimeInterval)] = [
            (130, 10), // the two agree
            (140, 20), // audio began 10 s before capture reported running
            (60, 10), // a track stopped delivering, leaving the mix short
            (nil, 10), // no readable mix
        ]
        for (mix, kept) in cases {
            XCTAssertEqual(
                RecordingCut.keptSeconds(
                    cutAt: start.addingTimeInterval(10),
                    startedAt: start,
                    stoppedAt: start.addingTimeInterval(130),
                    mixDuration: mix,
                ),
                kept,
                "mix \(mix.map(String.init(describing:)) ?? "unreadable")",
            )
        }
    }

    func testACutAtOrBeforeTheStartIsRefused() throws {
        let mix = try makeTrack("r_mix.wav", seconds: 10)
        let before = try Data(contentsOf: mix)

        XCTAssertThrowsError(try RecordingCut.apply(to: recording(mix: mix, app: nil, mic: nil), keepingFirst: 0))

        XCTAssertEqual(try Data(contentsOf: mix), before)
    }
}
