@testable import AudioTapLib
import XCTest

/// Both capture tracks, with different rates, buffer sizes and phases, cut the
/// same host-time span out of their files when the session pauses, and write
/// what is left back to back. Each track is compared with its own run without
/// pauses, which cancels the resampler and converter latency out of every
/// comparison: a marker captured at host time `t` must sit where the
/// unpaused run puts it, minus the paused time before `t`.
@available(macOS 14.2, *)
final class CapturePauseAlignmentTests: XCTestCase {
    /// Host second all buffer times count from.
    private static let base = 1000.0
    /// A marker every 100 ms, captured by both tracks at the same host times.
    private static let markers = (0 ..< 29).map { 0.05 + 0.1 * Double($0) }
    private static let pauses: [(start: Double, end: Double)] = [
        (0.7351, 0.7649), // shorter than one microphone buffer, around the marker at 0.75
        (1.2, 1.9), // long: seven markers inside
        (2.31, 2.33), (2.4, 2.46), (2.52, 2.5613), // repeated, the last two around a marker each
    ]

    /// One 16 kHz frame, the tolerance the alignment is held to.
    private static let oneFrame = 1.0

    func testBothTracksDropTheSameSpanAndStayAligned() throws {
        let unpaused = try run(pauses: [])
        let paused = try run(pauses: Self.pauses)
        let pausedSeconds = Self.pauses.reduce(0) { $0 + $1.end - $1.start }
        let kept = Self.markers.filter { marker in !Self.pauses.contains { marker >= $0.start && marker < $0.end } }

        for (name, whole, cut) in [("app", unpaused.app, paused.app), ("microphone", unpaused.mic, paused.mic)] {
            let wholeMarkers = Self.markerPositions(in: whole.file)
            let cutMarkers = Self.markerPositions(in: cut.file)
            XCTAssertEqual(wholeMarkers.count, Self.markers.count, "\(name): every marker in the unpaused run")
            XCTAssertEqual(cutMarkers.count, kept.count, "\(name): markers inside a pause are not written")
            guard wholeMarkers.count == Self.markers.count, cutMarkers.count == kept.count else { continue }

            var worst = 0.0
            for (marker, position) in zip(kept, cutMarkers) {
                let pausedBefore = Self.pauses.filter { $0.end <= marker }.reduce(0) { $0 + $1.end - $1.start }
                let unpausedPosition = try XCTUnwrap(zip(Self.markers, wholeMarkers).first { $0.0 == marker }?.1)
                let deviation = position - (unpausedPosition - pausedBefore * speechSampleRate)
                worst = max(worst, abs(deviation))
                XCTAssertEqual(deviation, 0, accuracy: Self.oneFrame, "\(name): marker at \(marker) s")
            }
            let lengthDeviation = Double(cut.file.count) - (Double(whole.file.count) - pausedSeconds * speechSampleRate)
            XCTAssertEqual(lengthDeviation, 0, accuracy: Self.oneFrame, "\(name): file shorter by exactly the paused time")

            // The live sink gets what the file gets, minus the gap fill: no
            // paused frame, so the same markers and the same loss.
            let sinkDeviation = Double(cut.sink.count) - (Double(whole.sink.count) - pausedSeconds * speechSampleRate)
            XCTAssertEqual(sinkDeviation, 0, accuracy: Self.oneFrame, "\(name): the live sink loses the paused time too")
            XCTAssertEqual(Self.markerPositions(in: cut.sink).count, kept.count, "\(name): no paused marker reaches the sink")

            // The measurement behind the early proof point, kept in the log.
            print("pause alignment \(name): worst marker deviation \(worst) frames, length deviation \(lengthDeviation) frames")
        }
    }

    // MARK: - Driving both tracks through one gate

    private struct Outputs {
        let app: PauseTrackOutput
        let mic: PauseTrackOutput
    }

    /// Deliver both tracks' buffers in the order a capture would, each one
    /// after its last frame was captured, applying every pause and resume
    /// that happened by then to the gate both share.
    private func run(pauses: [(start: Double, end: Double)]) throws -> Outputs {
        let gate = CapturePauseGate()
        let app = AppPauseTrackDriver(gate: gate)
        let mic = try MicPauseTrackDriver(gate: gate)
        // 10 ms app buffers from 0 s; 3750-frame (85 ms) microphone buffers from 3 ms.
        let appBuffers = (0 ..< 300).map { (driver: app as any PauseTrackDriver, start: Double($0) * 0.01, frames: 480) }
        let micBuffers = (0 ..< 36).map { index in
            (driver: mic as any PauseTrackDriver, start: 0.003 + Double(index * 3750) / 44100, frames: 3750)
        }
        let schedule = (appBuffers + micBuffers).map { buffer in
            (buffer.driver, buffer.start, buffer.frames, end: buffer.start + Double(buffer.frames) / buffer.driver.inputRate)
        }.sorted { $0.end < $1.end }

        var events = pauses.flatMap { [(time: $0.start, pause: true), (time: $0.end, pause: false)] }
        for (driver, start, frames, end) in schedule {
            while let event = events.first, event.time <= end {
                if event.pause {
                    gate.pause(atHostSeconds: Self.base + event.time)
                } else {
                    gate.resume(atHostSeconds: Self.base + event.time)
                }
                events.removeFirst()
            }
            try driver.deliver(Self.signal(start: start, frames: frames, rate: driver.inputRate), atHostSeconds: Self.base + start)
        }
        return try Outputs(app: app.finish(), mic: mic.finish())
    }

    /// Silence with a single-sample pulse at every marker time in the buffer.
    private static func signal(start: Double, frames: Int, rate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for marker in markers {
            let index = Int(((marker - start) * rate).rounded())
            if samples.indices.contains(index) { samples[index] = 0.9 }
        }
        return samples
    }

    /// Where the resampled pulses sit in 16 kHz frames, to a fraction of a
    /// frame: the peak of each pulse refined by a parabola through it and its
    /// two neighbours.
    private static func markerPositions(in samples: [Float]) -> [Double] {
        var positions: [Double] = []
        var index = 1
        while index < samples.count - 1 {
            guard samples[index] >= 0.1 else {
                index += 1
                continue
            }
            let window = index ..< min(index + 40, samples.count - 1)
            guard let peak = window.max(by: { samples[$0] < samples[$1] }) else { break }
            let (before, top, after) = (Double(samples[peak - 1]), Double(samples[peak]), Double(samples[peak + 1]))
            let curvature = before - 2 * top + after
            positions.append(Double(peak) + (curvature == 0 ? 0 : 0.5 * (before - after) / curvature))
            index = peak + 160
        }
        return positions
    }
}
