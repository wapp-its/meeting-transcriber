@testable import AudioTapLib
@preconcurrency import AVFoundation
import Foundation
import XCTest

/// `start()` refuses a session with nothing to record. This is the one arm of
/// the new optional-app-track shape that is reachable without a CATap or an
/// input device: the guard runs before either track's hardware is touched.
final class AudioCaptureSessionTracksTests: XCTestCase {
    /// A microphone engine that never touches hardware, for the session's
    /// microphone seam. It reports, as the device it is bound to, the one it
    /// was asked for (`Default` when asked for none), and can fail its bring-up.
    private final class FakeMicSession: MicEngineSessionProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var reported = "Default"
        private let shouldFail: Bool
        let notificationObject: AnyObject = NSObject()
        // swiftlint:disable:next force_unwrapping
        private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        init(shouldFail: Bool = false) {
            self.shouldFail = shouldFail
        }

        var boundInputDevice: MicInputDevice? {
            MicInputDevice(uid: lock.withLock { reported }, name: "Microphone")
        }

        func hardwareFormat(deviceUID: String?) throws -> AVAudioFormat {
            lock.withLock { reported = deviceUID ?? "Default" }
            if shouldFail { throw MicCaptureError.noInputDevice }
            return format
        }

        func installTap(format _: AVAudioFormat, block _: AVAudioNodeTapBlock) {}

        func start() {}

        func teardown() {}
    }

    /// A session whose two seams never reach hardware. The app seam returns no
    /// tap session, which only the seam can do.
    @available(macOS 14.2, *)
    private func makeSession(app: Bool, mic: Bool, micFails: Bool = false, micDeviceUID: String? = nil) -> AudioCaptureSession {
        let stem = FileManager.default.temporaryDirectory.appendingPathComponent("tracks-\(UUID().uuidString)")
        let appURL = stem.appendingPathExtension("app16k_raw.tmp")
        let micURL = stem.appendingPathExtension("mic.wav")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: appURL)
            try? FileManager.default.removeItem(at: micURL)
        }
        return AudioCaptureSession(
            AudioCaptureConfiguration(
                pids: [1], appOutputURL: app ? appURL : nil, micOutputURL: mic ? micURL : nil,
                sampleRate: 48000, channels: 2, micDeviceUID: micDeviceUID,
            ),
            appAttemptBody: { nil },
            micSessionFactory: { FakeMicSession(shouldFail: micFails) },
        )
    }

    /// Whether a microphone is actually being captured, which the configuration
    /// cannot say: a requested microphone that fails to start leaves the session
    /// running on the app track alone.
    func testTheMicrophoneTrackIsActiveOnlyWhileAMicrophoneCaptureRuns() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let cases: [(name: String, mic: Bool, micFails: Bool, active: Bool)] = [
            ("no microphone requested", false, false, false),
            ("microphone failed to start", true, true, false),
            ("microphone capturing", true, false, true),
        ]
        for testCase in cases {
            let session = makeSession(app: true, mic: testCase.mic, micFails: testCase.micFails)
            XCTAssertFalse(session.microphoneTrackActive, "before start: \(testCase.name)")

            try session.start()
            XCTAssertEqual(session.microphoneTrackActive, testCase.active, testCase.name)

            _ = session.stop()
            XCTAssertFalse(session.microphoneTrackActive, "after stop: \(testCase.name)")
        }
    }

    /// The selection and the device reported go to and come from the running
    /// microphone capture, and are inert without one.
    func testTheMicrophoneSelectionReachesTheRunningCaptureAndItsDeviceComesBack() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let appOnly = makeSession(app: true, mic: false)
        try appOnly.start()
        appOnly.selectMicrophone(deviceUID: "PinnedUID")
        XCTAssertNil(appOnly.micInputDevice)
        _ = appOnly.stop()

        let session = makeSession(app: true, mic: true, micDeviceUID: "PinnedUID")
        try session.start()
        defer { _ = session.stop() }
        XCTAssertEqual(session.micInputDevice, MicInputDevice(uid: "PinnedUID", name: "Microphone"))

        session.selectMicrophone(deviceUID: nil)
        let expected = MicInputDevice(uid: "Default", name: "Microphone")
        let deadline = Date().addingTimeInterval(5)
        while session.micInputDevice != expected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(session.micInputDevice, expected, "the restart on the system default was adopted")
    }

    func testAnUnopenedChannelReportsNoSignalAges() throws {
        // "Never opened" and "opened, then went quiet" are different faults and
        // must not collapse into one value. The levels cannot keep them apart,
        // both being -120; the ages can, by being absent rather than large.
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let session = AudioCaptureSession(AudioCaptureConfiguration(
            pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2,
        ))

        XCTAssertEqual(session.micSignalAges, .unknown)
        XCTAssertEqual(session.appSignalAges, .unknown)
    }

    func testStartRefusesASessionWithNeitherTrack() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let session = AudioCaptureSession(AudioCaptureConfiguration(pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2))

        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertEqual(error as? AudioCaptureSessionError, .noTracksRequested)
        }
    }

    /// What the session reads back out of its configuration, pinned where it is
    /// reachable without hardware.
    ///
    /// The session used to hold these as ten separate properties and now holds
    /// the configuration whole, so every read inside it was rewritten by hand.
    /// Three of those reads land in `stop()`'s result, and each has a same-typed
    /// neighbour it could have been swapped with: the two track URLs are both
    /// `URL?`, the rate and the channel count are both `Int`. Distinct values
    /// throughout, so a swap in either direction fails.
    ///
    /// A `stop()` with no `start()` touches nothing: both captures are nil, so
    /// the reported rate and channel count fall back to the configured ones and
    /// the app track is reported straight from the configuration.
    func testStopReportsTheTrackAndFormatItWasConfiguredWith() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        let app = URL(fileURLWithPath: "/tmp/stem_app16k_raw.tmp")
        let mic = URL(fileURLWithPath: "/tmp/stem_mic.wav")
        let session = AudioCaptureSession(AudioCaptureConfiguration(
            pids: [], appOutputURL: app, micOutputURL: mic, sampleRate: 44100, channels: 5,
        ))

        let result = session.stop()

        XCTAssertEqual(result.appAudioFileURL, app, "the app track, not the mic file")
        XCTAssertEqual(result.actualSampleRate, 44100, "the configured rate, not the channel count")
        XCTAssertEqual(result.actualChannels, 5)
        XCTAssertNil(result.micAudioFileURL, "no mic capture ran, so there is no mic track to report")
    }

    func testRefusalHappensBeforeAnyFileIsCreated() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("AudioCaptureSession requires macOS 14.2")
        }
        // A PID list without an output URL used to be impossible; assert the
        // guard keys on the URL, not on the PIDs, so a stray PID list cannot
        // talk the session into opening a tap it has nowhere to write.
        let session = AudioCaptureSession(AudioCaptureConfiguration(pids: [1, 2, 3], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2))

        XCTAssertThrowsError(try session.start())
    }
}
