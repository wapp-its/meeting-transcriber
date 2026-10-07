import Foundation

/// Brings one audio track to a common speech level, for what a person listens
/// to: the mixed recording and the naming-dialog voice samples. Pure: no I/O,
/// no settings, no actor.
///
/// Why: in a headset meeting the own voice reached the mix 20 to 25 dB under
/// the far end. Nothing the pipeline analyses passes through here: the
/// per-track files, and everything transcription, diarization and the echo
/// detectors compute from them, stay exactly as recorded.
///
/// **Speech level.** The samples are cut into consecutive 100 ms frames and
/// each frame's RMS is taken in dBFS (`AudioMixer.rmsDecibels`). Frames at or
/// below −90 dBFS (digital silence, gated stretches, alignment padding) are
/// ignored. The noise floor is the 10th percentile of the remaining frames, and
/// a frame is speech when it reaches the larger of −60 dBFS and noise floor
/// + 10 dB. The level is the power mean of the speech frames. Not the peak and
/// not a whole-file RMS: both move with how much of the track is speech, and
/// this does not; a track measures the same whether speech fills half of it or
/// a twentieth. Less speech than the minimum (5 s for
/// a track, 0.5 s for a naming sample) is not measurable, and such a track
/// keeps its recorded level. Energy-based: typing near a built-in microphone
/// can be taken for speech and raised with it; the switch turns balancing off.
///
/// **Gain.** Target −20 dBFS, boost capped at +24 dB so the noise of a nearly
/// silent track is not pumped up without bound, no lower bound because a cut
/// is always safe. A boost is then lowered, never below 0 dB, until at most
/// 0.1 % of the samples inside the speech frames would exceed full scale, and
/// every sample that still would is clamped to ±1.0.
///
/// A trailing partial frame is not measured; the gain still applies to it.
enum LevelBalance {
    static let frameSeconds = 0.1
    static let silenceFloorDBFS = -90.0
    static let absoluteSpeechFloorDBFS = -60.0
    static let noiseMarginDB = 10.0
    static let noiseFloorPercentile = 0.10
    static let targetDBFS = -20.0
    static let maxBoostDB = 24.0
    /// Share of the speech-frame samples a boost may push beyond full scale.
    static let clipBudget = 0.001
    /// Resolution of the clip-budget search: when the budget binds, the
    /// applied gain is within this much of the largest gain it allows, and
    /// never above it.
    static let clipSearchStepDB = 0.1
    static let trackMinimumSpeechSeconds = 5.0
    static let sampleMinimumSpeechSeconds = 0.5

    /// What lowered a gain below the one that reaches the target.
    enum Limit: Equatable {
        case boostCap
        case clipBudget
    }

    /// One track's balancing, as applied and as logged.
    struct Outcome: Equatable {
        /// Power mean of the speech frames in dBFS; nil when not measurable.
        let speechLevelDBFS: Double?
        /// 0 when not measurable.
        let gainDB: Double
        /// nil when neither limit lowered the gain.
        let limit: Limit?
    }

    struct Measurement {
        /// Nil when the speech frames add up to less than the minimum.
        let speechLevelDBFS: Double?
        fileprivate let frameLength: Int
        /// Frame `i` covers samples `i * frameLength ..< (i + 1) * frameLength`.
        fileprivate let speechFrames: [Int]
    }

    static func measure(_ samples: [Float], sampleRate: Int, minimumSpeechSeconds: Double) -> Measurement {
        let frameLength = Int((Double(sampleRate) * frameSeconds).rounded())
        let unmeasurable = Measurement(speechLevelDBFS: nil, frameLength: frameLength, speechFrames: [])
        guard frameLength > 0 else { return unmeasurable }

        let levels = (0 ..< samples.count / frameLength).map { frame in
            Double(AudioMixer.rmsDecibels(samples: samples[frame * frameLength ..< (frame + 1) * frameLength]))
        }
        let audible = levels.filter { $0 > silenceFloorDBFS }.sorted()
        guard !audible.isEmpty else { return unmeasurable }

        let noiseFloor = audible[min(audible.count - 1, Int(Double(audible.count) * noiseFloorPercentile))]
        let threshold = max(absoluteSpeechFloorDBFS, noiseFloor + noiseMarginDB)
        let speechFrames = levels.indices.filter { levels[$0] >= threshold }
        let speechSeconds = Double(speechFrames.count * frameLength) / Double(sampleRate)
        guard !speechFrames.isEmpty, speechSeconds >= minimumSpeechSeconds else { return unmeasurable }

        let meanSquare = speechFrames.reduce(0.0) { $0 + pow(10, levels[$1] / 10) } / Double(speechFrames.count)
        return Measurement(speechLevelDBFS: 10 * log10(meanSquare), frameLength: frameLength, speechFrames: speechFrames)
    }

    /// The gain `measurement` calls for, with both limits applied.
    static func gain(for measurement: Measurement, in samples: [Float]) -> Outcome {
        guard let level = measurement.speechLevelDBFS else {
            return Outcome(speechLevelDBFS: nil, gainDB: 0, limit: nil)
        }
        let wanted = targetDBFS - level
        let capped = min(wanted, maxBoostDB)
        if capped > 0, let lowered = clipBudgetGain(samples, measurement, below: capped) {
            return Outcome(speechLevelDBFS: level, gainDB: lowered, limit: .clipBudget)
        }
        return Outcome(speechLevelDBFS: level, gainDB: capped, limit: wanted > maxBoostDB ? .boostCap : nil)
    }

    /// Measures `samples`, applies the gain in place and clamps every sample
    /// to ±1.0.
    static func balance(_ samples: inout [Float], sampleRate: Int, minimumSpeechSeconds: Double) -> Outcome {
        let measurement = measure(samples, sampleRate: sampleRate, minimumSpeechSeconds: minimumSpeechSeconds)
        let outcome = gain(for: measurement, in: samples)
        let factor = Float(pow(10, outcome.gainDB / 20))
        for index in samples.indices {
            samples[index] = min(max(samples[index] * factor, -1), 1)
        }
        return outcome
    }

    /// The one diagnostic line a balanced mix writes: each track's level (or
    /// that it was not measurable), its gain, and the limit that lowered it.
    /// Numbers only, never a file name, title or audio content.
    static func logLine(app: Outcome, mic: Outcome) -> String {
        "Level balance: \(describe(app, track: "app")); \(describe(mic, track: "mic"))"
    }

    private static func describe(_ outcome: Outcome, track: String) -> String {
        guard let level = outcome.speechLevelDBFS else {
            return "\(track) not measurable, gain 0 dB"
        }
        let text = "\(track) speech \(String(format: "%.1f", level)) dBFS gain \(String(format: "%+.1f", outcome.gainDB)) dB"
        switch outcome.limit {
        case nil: return text
        case .boostCap: return text + " (boost cap)"
        case .clipBudget: return text + " (clip budget)"
        }
    }

    /// The largest gain below `maxGain` that keeps at most `clipBudget` of the
    /// speech-frame samples beyond full scale, or nil when `maxGain` already
    /// does.
    ///
    /// Without sorting samples: only a sample above `-maxGain` dBFS can clip at
    /// any gain up to `maxGain`, so those few go into `clipSearchStepDB` level
    /// bins. At the gain `maxGain - j * step` every sample in bin `j` or above
    /// may clip and none below can, so walking down from the top bin finds the
    /// lowest `j` whose count still fits the budget. The count is an upper
    /// bound, so the budget always holds, and the result is at most one step
    /// below the exact optimum.
    private static func clipBudgetGain(_ samples: [Float], _ measurement: Measurement, below maxGain: Double) -> Double? {
        let frameLength = measurement.frameLength
        let allowed = Int(Double(measurement.speechFrames.count * frameLength) * clipBudget)
        let threshold = pow(10, -maxGain / 20)
        let binCount = Int((maxGain / clipSearchStepDB).rounded(.up))
        var bins = [Int](repeating: 0, count: binCount)
        var beyondFullScale = 0
        var clippingAtMax = 0
        for frame in measurement.speechFrames {
            for sample in samples[frame * frameLength ..< (frame + 1) * frameLength] {
                let magnitude = Double(abs(sample))
                guard magnitude > threshold else { continue }
                clippingAtMax += 1
                guard magnitude <= 1 else {
                    beyondFullScale += 1
                    continue
                }
                let bin = Int((20 * log10(magnitude) + maxGain) / clipSearchStepDB)
                bins[min(max(bin, 0), binCount - 1)] += 1
            }
        }
        guard clippingAtMax > allowed else { return nil }

        var clipping = beyondFullScale
        var step = binCount
        while step > 1, clipping + bins[step - 1] <= allowed {
            clipping += bins[step - 1]
            step -= 1
        }
        return step < binCount ? maxGain - Double(step) * clipSearchStepDB : 0
    }
}
