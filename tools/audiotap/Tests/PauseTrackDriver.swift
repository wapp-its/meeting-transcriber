@testable import AudioTapLib
@preconcurrency import AVFoundation
import Darwin
import XCTest

/// What one capture track wrote to its file and handed its live sink, both
/// as 16 kHz mono samples.
struct PauseTrackOutput {
    let file: [Float]
    let sink: [Float]
}

/// One capture track's real write path, fed buffers presented at chosen host
/// times, so the pause tests reach the code a recording runs without any
/// audio hardware: the app track through `resampleForwardAndWrite`, the
/// microphone through the tap block the handler installs on a fake engine.
protocol PauseTrackDriver: AnyObject {
    var name: String { get }
    var inputRate: Double { get }
    /// Deliver one buffer of mono samples (copied to every channel) whose
    /// first frame was captured at `hostSeconds`.
    func deliver(_ samples: [Float], atHostSeconds hostSeconds: Double) throws
    func finish() throws -> PauseTrackOutput
}

/// Collects what a live sink receives. Locked because the sink is `@Sendable`.
final class PauseSinkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Float] = []

    var samples: [Float] {
        lock.withLock { collected }
    }

    func receive(_ buffer: LiveAudioBuffer) {
        lock.withLock { collected += buffer.samples }
    }
}

/// The app-audio track: 48 kHz stereo into a raw float file, as the IOProc
/// hands it to `writeCapturedBuffer` once the rate is known.
@available(macOS 14.2, *)
final class AppPauseTrackDriver: PauseTrackDriver {
    let name = "app"
    let inputRate = 48000.0
    private let path = NSTemporaryDirectory() + "pause-app-\(UUID().uuidString).f32"
    private let fd: Int32
    private let sink = PauseSinkCollector()
    private let capture: AppAudioCapture

    init(gate: CapturePauseGate) {
        fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        let sink = sink
        capture = AppAudioCapture(
            pids: [],
            outputFileDescriptor: fd,
            sampleRate: 48000,
            channels: 2,
            liveSink: { sink.receive($0) },
            attemptBody: nil,
            pauseGate: gate,
        )
    }

    deinit {
        close(fd)
        unlink(path)
    }

    func deliver(_ samples: [Float], atHostSeconds hostSeconds: Double) {
        let stereo = samples.flatMap { [$0, $0] }
        capture.resampleForwardAndWrite(
            fd: fd, interleaved: stereo, inputRate: Int(inputRate), inputChannels: 2,
            hostTicks: secondsToMachTicks(hostSeconds),
        )
    }

    func finish() throws -> PauseTrackOutput {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let file = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return PauseTrackOutput(file: file, sink: sink.samples)
    }
}

/// Stands in for the microphone's engine: hands the handler's tap block back
/// to the test and never touches audio hardware.
final class PauseTestMicSession: MicEngineSessionProviding, @unchecked Sendable {
    let notificationObject: AnyObject = NSObject()
    let format: AVAudioFormat
    private(set) var tapBlock: AVAudioNodeTapBlock?

    init(format: AVAudioFormat) {
        self.format = format
    }

    func hardwareFormat(deviceUID _: String?) -> AVAudioFormat {
        format
    }

    func installTap(format _: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        tapBlock = block
    }

    func start() {}

    func teardown() {}
}

/// The microphone track: a 44.1 kHz mono input converted into the handler's
/// 16 kHz WAV, so the two tracks of a test also differ in rate.
final class MicPauseTrackDriver: PauseTrackDriver {
    let name = "microphone"
    let inputRate = 44100.0
    let handler: MicCaptureHandler
    private let session: PauseTestMicSession
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pause-mic-\(UUID().uuidString).wav")
    private let sink = PauseSinkCollector()

    init(gate: CapturePauseGate) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let session = PauseTestMicSession(format: format)
        let sink = sink
        self.session = session
        handler = MicCaptureHandler(
            outputURL: url,
            liveSink: { sink.receive($0) },
            sessionFactory: { session },
            pauseGate: gate,
        )
        try handler.start()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func deliver(_ samples: [Float], atHostSeconds hostSeconds: Double) throws {
        let block = try XCTUnwrap(session.tapBlock, "the handler must have installed its tap")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: session.format, frameCapacity: AVAudioFrameCount(samples.count),
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        block(buffer, AVAudioTime(hostTime: secondsToMachTicks(hostSeconds)))
    }

    func finish() throws -> PauseTrackOutput {
        handler.stop()
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return PauseTrackOutput(file: [], sink: sink.samples) }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length),
        ))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return PauseTrackOutput(
            file: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            sink: sink.samples,
        )
    }
}
