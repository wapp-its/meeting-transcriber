@testable import AudioTapLib
import Foundation
import XCTest

final class AudioCaptureResultTests: XCTestCase {
    func testFieldsStored() {
        let appURL = URL(fileURLWithPath: "/tmp/app.raw")
        let micURL = URL(fileURLWithPath: "/tmp/mic.wav")
        let result = AudioCaptureResult(
            appAudioFileURL: appURL,
            micAudioFileURL: micURL,
            actualSampleRate: 48000,
            actualChannels: 2,
            micDelay: 0.123,
        )

        XCTAssertEqual(result.appAudioFileURL, appURL)
        XCTAssertEqual(result.micAudioFileURL, micURL)
        XCTAssertEqual(result.actualSampleRate, 48000)
        XCTAssertEqual(result.actualChannels, 2)
        XCTAssertEqual(result.micDelay, 0.123, accuracy: 1e-9)
    }

    func testNilMicURL() {
        let result = AudioCaptureResult(
            appAudioFileURL: URL(fileURLWithPath: "/tmp/app.raw"),
            micAudioFileURL: nil,
            actualSampleRate: 16000,
            actualChannels: 2,
            micDelay: 0,
        )

        XCTAssertNil(result.micAudioFileURL)
        XCTAssertEqual(result.micDelay, 0)
    }

    func testMonoChannelCount() {
        let result = AudioCaptureResult(
            appAudioFileURL: URL(fileURLWithPath: "/tmp/app.raw"),
            micAudioFileURL: nil,
            actualSampleRate: 16000,
            actualChannels: 1,
            micDelay: 0,
        )

        XCTAssertEqual(result.actualChannels, 1)
    }

    // MARK: - AudioCaptureResult.make (stop() delay/rate/channel arithmetic)

    private static let appURL = URL(fileURLWithPath: "/tmp/app.raw")
    private static let micURL = URL(fileURLWithPath: "/tmp/mic.wav")

    private func make(
        appURL: URL? = AudioCaptureResultTests.appURL,
        micRecorded: Bool = true,
        appTicks: UInt64 = 1000,
        micTicks: UInt64 = 5000,
        appRate: Int = 16000,
        appChannels: Int = 1,
        configuredRate: Int = 48000,
        configuredChannels: Int = 2,
        pauses: CapturePauseTimeline = CapturePauseTimeline(),
    ) -> AudioCaptureResult {
        AudioCaptureResult.make(
            appOutputURL: appURL,
            micOutputURL: Self.micURL,
            configured: (sampleRate: configuredRate, channels: configuredChannels),
            app: .init(firstFrameTicks: appTicks, sampleRate: appRate, channels: appChannels),
            mic: .init(recorded: micRecorded, firstFrameTicks: micTicks),
            pauses: pauses,
        )
    }

    func testMakePositiveMicDelayWhenMicStartsLater() {
        // mic ticks > app ticks → mic started later → positive delay. Pins the
        // subtraction order (a sign flip is the #99 "mix.wav 2× duration" class).
        let result = make(appTicks: 1000, micTicks: 5000)
        XCTAssertGreaterThan(result.micDelay, 0)
        XCTAssertEqual(
            result.micDelay,
            machTicksToSeconds(5000) - machTicksToSeconds(1000),
            accuracy: 1e-12,
        )
    }

    func testMakeNegativeMicDelayWhenMicStartsEarlier() {
        XCTAssertLessThan(make(appTicks: 5000, micTicks: 1000).micDelay, 0)
    }

    func testMakeZeroDelayWhenAppNeverDeliveredAFrame() {
        // app tick 0 (no app frame) → the guard skips the delta, no bogus delay.
        XCTAssertEqual(make(appTicks: 0, micTicks: 5000).micDelay, 0)
    }

    func testMakeZeroDelayWhenMicNeverDeliveredAFrame() {
        XCTAssertEqual(make(appTicks: 1000, micTicks: 0).micDelay, 0)
    }

    func testMakeZeroDelayAndNilMicURLWhenMicNotRecorded() {
        // Valid ticks but no mic recorded → no delay and no mic URL.
        let result = make(micRecorded: false, appTicks: 1000, micTicks: 5000)
        XCTAssertEqual(result.micDelay, 0)
        XCTAssertNil(result.micAudioFileURL)
    }

    func testMakeIncludesMicURLWhenRecorded() {
        XCTAssertEqual(make(micRecorded: true).micAudioFileURL, Self.micURL)
    }

    func testMakeFallsBackToConfiguredRateWhenAppReportedZero() {
        XCTAssertEqual(make(appRate: 0, configuredRate: 48000).actualSampleRate, 48000)
    }

    func testMakeUsesAppReportedRateWhenNonZero() {
        XCTAssertEqual(make(appRate: 16000, configuredRate: 48000).actualSampleRate, 16000)
    }

    func testMakeFallsBackToConfiguredChannelsWhenAppReportedZero() {
        XCTAssertEqual(make(appChannels: 0, configuredChannels: 2).actualChannels, 2)
    }

    func testMakeUsesAppReportedChannelsWhenNonZero() {
        XCTAssertEqual(make(appChannels: 1, configuredChannels: 2).actualChannels, 1)
    }

    // MARK: - Sessions with no app track (microphone-only recordings)

    func testMakeCarriesNoAppURLWhenNoAppTrackWasRequested() {
        // Distinct from "the tap ran and wrote nothing", which still yields a
        // URL to an empty file. Downstream reads the nil as "this recording
        // never had a second track", not as a capture failure.
        XCTAssertNil(make(appURL: nil).appAudioFileURL)
    }

    func testMakeStillCarriesTheMicURLWithoutAnAppTrack() {
        XCTAssertEqual(make(appURL: nil, micRecorded: true).micAudioFileURL, Self.micURL)
    }

    func testMakeFallsBackToConfiguredFormatWithoutAnAppTrack() {
        // No app capture ever reports a rate or a channel count, so the
        // configured values are all there is; a zero here would make
        // `buildRecording` divide by it downstream.
        let result = make(appURL: nil, appRate: 0, appChannels: 0, configuredRate: 48000, configuredChannels: 2)

        XCTAssertEqual(result.actualSampleRate, 48000)
        XCTAssertEqual(result.actualChannels, 2)
    }

    func testMakeReportsNoMicDelayWithoutAnAppTrack() {
        // There is no app first frame to measure the mic against, so the delay
        // must stay 0 rather than becoming the mic's own absolute timestamp.
        XCTAssertEqual(make(appURL: nil, appTicks: 0, micTicks: 5000).micDelay, 0)
    }

    // MARK: - Pauses (first frames and pause positions on the recording clock)

    /// Host seconds as the ticks `make` takes. One tick of rounding is far
    /// below the microsecond the assertions allow.
    private func ticks(_ seconds: Double) -> UInt64 {
        secondsToMachTicks(seconds)
    }

    private func pauses(_ spans: (start: Double, end: Double?)...) -> CapturePauseTimeline {
        var timeline = CapturePauseTimeline()
        for span in spans {
            timeline.pause(atHostSeconds: span.start)
            if let end = span.end { timeline.resume(atHostSeconds: end) }
        }
        return timeline
    }

    func testMakeReportsTheMicDelayWithoutThePauseBetweenTheFirstFrames() {
        // 3 s apart on the host clock, 2 s of it paused: the tracks lose the
        // same 2 s, so on the saved timeline the mic is 1 s late.
        let result = make(appTicks: ticks(100), micTicks: ticks(103), pauses: pauses((100.5, 102.5)))

        XCTAssertEqual(result.micDelay, 1, accuracy: 1e-6)
    }

    func testMakeWithoutAPauseReportsNoPauseOffsets() {
        XCTAssertEqual(make(appTicks: ticks(100), micTicks: ticks(101)).pauseOffsets, [])
    }

    func testMakePlacesEachPauseOnTheSavedTimeline() {
        typealias FirstFrames = (app: Double, mic: Double)
        let cases: [(String, FirstFrames, pauses: CapturePauseTimeline, offsets: [Double])] = [
            // Origin at the app, the mic started later; the second pause comes
            // 2 s earlier on the saved timeline than on the host clock.
            ("two pauses", (100, 100.25), pauses((110, 112), (120, 125)), [10, 18]),
            ("the mic started first", (100, 99.5), pauses((110, 112)), [10.5]),
            ("a pause before any first frame", (100, 100.25), pauses((90, 95)), [0]),
            ("a pause around the first frames", (100, 100.25), pauses((99, 101)), [0]),
            ("a pause still open at the stop", (100, 100.25), pauses((110, nil)), [10]),
        ]
        for (name, firstFrames, timeline, offsets) in cases {
            let result = make(appTicks: ticks(firstFrames.app), micTicks: ticks(firstFrames.mic), pauses: timeline)
            XCTAssertEqual(result.pauseOffsets.count, offsets.count, name)
            for (offset, expected) in zip(result.pauseOffsets, offsets) {
                XCTAssertEqual(offset, expected, accuracy: 1e-6, name)
            }
        }
    }

    func testMakeWithoutAnyFirstFramePutsEveryPauseAtZero() {
        let result = make(appTicks: 0, micTicks: 0, pauses: pauses((110, 112), (120, nil)))

        XCTAssertEqual(result.pauseOffsets, [0, 0])
    }
}
