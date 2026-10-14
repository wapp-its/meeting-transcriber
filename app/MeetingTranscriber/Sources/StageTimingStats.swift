import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "StageTimingStats")

/// A pipeline stage whose wall-clock duration we track. The raw values are the
/// `stage_timing.jsonl` wire contract; map from a `JobState` via the
/// `init?(jobState:)` below.
enum StageKind: String, Codable, CaseIterable {
    case transcribing
    case diarizing
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case generatingProtocol

    var label: String {
        switch self {
        case .transcribing: "Transcribing"
        case .diarizing: "Diarizing"
        case .generatingProtocol: "Protocol"
        }
    }

    /// The timed stage a `JobState` corresponds to, or nil for non-timed states
    /// (`.waiting`, `.speakerNamingPending`, `.done`, `.error`). The speaker-
    /// naming wait is its own state, so its human-paced duration is never
    /// attributed to diarization.
    init?(jobState: JobState) {
        switch jobState {
        case .transcribing: self = .transcribing
        case .diarizing: self = .diarizing
        case .generatingProtocol: self = .generatingProtocol
        default: return nil
        }
    }
}

/// One row in the JSONL stage-timing log: how long a single pipeline stage of a
/// single job took, plus the audio length it processed so a real-time factor is
/// derivable. `engine` / `diarizerMode` are context tags that make averages
/// comparable (a Sortformer diarization is not the same cost as an offline one).
struct StageTimingEvent: Codable, Equatable {
    let ts: Date
    let jobID: UUID
    let stage: StageKind
    let wallClockSeconds: Double
    /// Seconds of audio the stage processed (last segment end). 0 when unknown.
    let audioSeconds: Double
    let engine: String?
    let diarizerMode: String?
}

/// Identifies one configuration whose timings are comparable. Averages only
/// mean something within a config: a Parakeet transcription is ~10x a WhisperKit
/// one, and a Sortformer diarization is far slower than an offline one — so the
/// norm must be per (stage, engine, diarizer-mode).
struct StageConfig: Hashable {
    let stage: StageKind
    let engine: String?
    let diarizerMode: String?
}

/// A job's running stage as its menu line reads it: when the stage started
/// and, once it can be computed, when it should be ready. Holds no clock of
/// its own, so the line it renders is the same however much time passes.
struct StageClock: Equatable {
    /// The history the expected finish is read from: the run's own engine,
    /// and for diarization and protocol generation the mode the run diarizes
    /// with.
    let config: StageConfig
    let startedAt: Date
    /// Nil until the stage has an audio length and a usable speed; once set,
    /// unchanged until the stage ends.
    var expectedFinish: Date?
}

enum StageTimingStats {
    /// Aggregate of one stage over a set of events. Returned keyed by stage, so
    /// the stage itself is the dictionary key, not a field here.
    struct StageAggregate: Equatable {
        let count: Int
        /// Mean wall-clock duration — the intuitive "how long does it usually
        /// take" number shown in Settings.
        let avgWallClockSeconds: Double
        /// Average real-time factor = processing-seconds per second of audio,
        /// computed as a ratio of totals (sum of wall-clock over sum of audio)
        /// so a long meeting weighs more than a short one — the right basis for
        /// "how long will THIS meeting take". `nil` when no event carried a
        /// positive audio duration (can't normalise).
        let avgRTF: Double?
    }

    /// Compute the count / average wall-clock / average RTF for one group of
    /// events. Events whose `audioSeconds <= 0` still count toward `count` and
    /// `avgWallClockSeconds` but are excluded from the RTF ratio so they neither
    /// divide by zero nor skew throughput.
    private static func aggregateGroup(_ events: [StageTimingEvent]) -> StageAggregate {
        let count = events.count
        let avgWall = events.reduce(0.0) { $0 + $1.wallClockSeconds } / Double(count)
        let withAudio = events.filter { $0.audioSeconds > 0 }
        let avgRTF: Double?
        if withAudio.isEmpty {
            avgRTF = nil
        } else {
            let totalWall = withAudio.reduce(0.0) { $0 + $1.wallClockSeconds }
            let totalAudio = withAudio.reduce(0.0) { $0 + $1.audioSeconds }
            avgRTF = totalWall / totalAudio
        }
        return StageAggregate(count: count, avgWallClockSeconds: avgWall, avgRTF: avgRTF)
    }

    /// Group events by stage (blending all engines/modes).
    static func aggregate(events: [StageTimingEvent]) -> [StageKind: StageAggregate] {
        Dictionary(grouping: events, by: \.stage).mapValues(aggregateGroup)
    }

    /// Group events by full (stage, engine, diarizer-mode) configuration, so the
    /// Settings view can show comparable per-config numbers.
    static func aggregateByConfig(events: [StageTimingEvent]) -> [StageConfig: StageAggregate] {
        Dictionary(grouping: events) { event in
            StageConfig(stage: event.stage, engine: event.engine, diarizerMode: event.diarizerMode)
        }.mapValues(aggregateGroup)
    }

    /// Wall-clock seconds per second of audio for each configuration, keyed
    /// the way `PipelineQueue` stamps its events and looks a running stage up:
    /// transcription by engine alone, since the diarizer mode plays no part in
    /// it, diarization and protocol generation by engine and diarizer mode. A
    /// configuration none of whose events carried an audio length is absent.
    static func speedByConfig(events: [StageTimingEvent]) -> [StageConfig: Double] {
        Dictionary(grouping: events) { event in
            StageConfig(
                stage: event.stage, engine: event.engine,
                diarizerMode: event.stage == .transcribing ? nil : event.diarizerMode,
            )
        }.compactMapValues { aggregateGroup($0).avgRTF }
    }

    /// When a stage that started at `start` should be done: its start plus the
    /// recording's length times the stage's historical speed. Nil without a
    /// positive audio length and a positive speed, so a missing or broken
    /// history never yields a time before the start or a zero-length estimate.
    static func expectedFinish(start: Date, audioSeconds: Double?, secondsPerAudioSecond: Double?) -> Date? {
        guard let audioSeconds, audioSeconds > 0, audioSeconds.isFinite,
              let speed = secondsPerAudioSecond, speed > 0, speed.isFinite
        else { return nil }
        return start.addingTimeInterval(audioSeconds * speed)
    }
}

/// Append-only JSONL writer for stage-timing events. One file per app install,
/// owner-readable (chmod 0600 on first creation). Production callers use the
/// no-arg `init()`; tests pass an explicit `path:` to avoid polluting the real
/// log. Mirrors `RecognitionStatsLog`.
actor StageTimingLog {
    static let defaultPath = AppPaths.dataDir.appendingPathComponent("stage_timing.jsonl")

    private let path: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(path: URL = StageTimingLog.defaultPath) {
        self.path = path
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ events: [StageTimingEvent]) {
        guard !events.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            )

            if !FileManager.default.fileExists(atPath: path.path) {
                FileManager.default.createFile(
                    atPath: path.path, contents: nil,
                    attributes: [.posixPermissions: 0o600],
                )
            }

            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            for event in events {
                let line = try encoder.encode(event) + Data([0x0A])
                try handle.write(contentsOf: line)
            }
            try handle.synchronize()
        } catch {
            logger.error("Failed to append stage-timing events: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load events with `ts` within the last `interval` seconds. Skips lines that
    /// fail to decode (forward-compat for future schema changes).
    func loadRecent(within interval: TimeInterval, now: Date = Date()) -> [StageTimingEvent] {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = now.addingTimeInterval(-interval)
        var out: [StageTimingEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(StageTimingEvent.self, from: lineData),
                  event.ts >= cutoff else { continue }
            out.append(event)
        }
        return out
    }
}
