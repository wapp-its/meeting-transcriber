@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// `AudioCaptureSession.pause()` / `resume()` reach the microphone handler the
/// session built, through the session's microphone seam, so nothing here
/// touches an audio device.
@available(macOS 14.2, *)
final class AudioCaptureSessionPauseTests: XCTestCase {
    func testPauseAndResumeActOnTheMicrophoneTheSessionBuilt() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let micSession = PauseTestMicSession(format: format)
        let micURL = FileManager.default.temporaryDirectory.appendingPathComponent("session-pause-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: micURL) }
        let session = AudioCaptureSession(
            AudioCaptureConfiguration(pids: [1], appOutputURL: nil, micOutputURL: micURL, sampleRate: 48000, channels: 2),
            appAttemptBody: { nil },
            micSessionFactory: { micSession },
        )
        try session.start()
        let block = try XCTUnwrap(micSession.tapBlock)
        // A tenth of a second of tone captured `secondsAgo` before now.
        func deliver(capturedSecondsAgo secondsAgo: Double) throws -> Int {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
            buffer.frameLength = 4410
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0 ..< 4410 {
                samples[frame] = Float(sin(Double(frame) * 0.05)) * 0.5
            }
            block(buffer, AVAudioTime(hostTime: mach_absolute_time() - secondsToMachTicks(secondsAgo)))
            return try Data(contentsOf: micURL).count
        }

        let beforePause = try deliver(capturedSecondsAgo: 0.5)
        XCTAssertFalse(session.isPaused)

        session.pause()
        XCTAssertTrue(session.isPaused)
        XCTAssertEqual(try deliver(capturedSecondsAgo: 0), beforePause, "a buffer captured while paused is not written")

        session.resume()
        XCTAssertFalse(session.isPaused)
        XCTAssertGreaterThan(try deliver(capturedSecondsAgo: 0), beforePause, "a buffer captured after the resume is")

        XCTAssertEqual(session.stop().pauseOffsets.count, 1, "the result places the one pause")
    }
}
