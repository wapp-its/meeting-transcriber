import Foundation

/// A finished meeting's word timings (R7): its transcript segments file, kept
/// beside its raw transcript and listed in its record, and what Identify Speakers
/// Again reads from it in place of a transcription (R10).
extension PipelineQueue {
    /// Whether `job`'s transcript segments file stays when its naming files go:
    /// for a meeting whose record lists it, so Move Meeting to Trash finds it, and
    /// whose raw transcript is kept separately. With that option off it goes when
    /// the speakers are named, as before.
    func keepsWordTimings(of job: PipelineJob) -> Bool {
        meetingFileStore?.record(for: job.id) != nil && transcriptOutputOptions(of: job).saveRawTranscriptSeparately
    }

    func keepsWordTimings(jobID: UUID) -> Bool {
        job(withID: jobID).map(keepsWordTimings(of:)) ?? false
    }

    /// The segments an Identify Speakers Again run labels again: the meeting's
    /// current segments file, while it is the file its record names. Nil for any
    /// other run, and for a file gone, replaced, unreadable or empty, which the run
    /// then transcribes again.
    func keptWordTimings(for job: PipelineJob) -> [TimestampedSegment]? { // swiftlint:disable:this discouraged_optional_collection
        guard job.rerun?.mode == .identifySpeakersAgain, let record = meetingFileStore?.record(for: job.id) else { return nil }
        return Self.keptWordTimings(of: record)
    }

    /// `record`'s word timings, read as `keptWordTimings(for:)` reads them.
    static func keptWordTimings(of record: MeetingFileRecord) -> [TimestampedSegment]? { // swiftlint:disable:this discouraged_optional_collection
        guard let file = record.keptWordTimings,
              MeetingFileRemover.isTheRecordedFile(file),
              let data = try? Data(contentsOf: URL(filePath: file.path)),
              let segments = try? JSONDecoder().decode([TimestampedSegment].self, from: data),
              !segments.isEmpty
        else { return nil }
        return segments
    }

    /// A two-track meeting's kept segments with the microphone's tagged by this
    /// queue's label, which the labelling splits them by
    /// (`DiarizationProcess.labelSegments`): Settings' mic name may have changed
    /// since the meeting ran. Every segment not tagged as the call audio's is the
    /// microphone's, as the mic name never reads as the call audio's tag.
    /// A run on the microphone's track alone, the call audio and the mix being gone,
    /// diarizes it with `micDelay` of silence before it: the kept words are on the
    /// meeting's timeline, which starts that much before the microphone's, and a
    /// diarization on the track's own would put each voice that much early.
    func moveOntoTheMeetingsTimeline(_ mix16k: URL, of source: URL, jobID: UUID, micDelay: TimeInterval) throws {
        guard micDelay != 0, meetingFileStore?.record(for: jobID)?.rerunSourceTracks.mic?.path == source.path else { return }
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: mix16k)
        let offset = Int((micDelay * Double(AudioConstants.targetSampleRate)).rounded())
        let moved = offset > 0 ? [Float](repeating: 0, count: offset) + samples : Array(samples.dropFirst(-offset))
        try AudioMixer.saveWAV(samples: moved, sampleRate: AudioConstants.targetSampleRate, url: mix16k)
    }

    /// `labeled` by start, and the segments that start at the same moment in the
    /// order of `kept`, the segments they were labelled from. The labelling breaks
    /// such a tie by its topology (the one for a failed call audio puts the
    /// microphone first), so a run that labels a meeting's kept words again
    /// would otherwise swap two of their lines.
    static func inKeptOrder(_ labeled: [TimestampedSegment], kept: [TimestampedSegment]) -> [TimestampedSegment] {
        func key(_ segment: TimestampedSegment) -> String {
            "\(segment.start)|\(segment.end)|\(segment.text)"
        }
        var rank: [String: Int] = [:]
        for (index, segment) in kept.enumerated() where rank[key(segment)] == nil {
            rank[key(segment)] = index
        }
        return labeled.enumerated().sorted { lhs, rhs in
            (lhs.element.start, rank[key(lhs.element)] ?? .max, lhs.offset) < (rhs.element.start, rank[key(rhs.element)] ?? .max, rhs.offset)
        }.map(\.element)
    }

    /// `segments`, each run of them that starts at the same moment in the order the
    /// meeting's current transcript has their words, where it has them all. An
    /// earlier build rendered such a tie by the labelling's topology rather than
    /// by the kept order (`inKeptOrder`), so its transcript may have them the
    /// other way round. The words of each run are looked for only after those of
    /// the runs before it, so the same words said earlier in the meeting are never
    /// taken for a later line. A segment left out of the transcript as the
    /// loudspeaker coming back is not looked for and keeps its place in its run.
    func inTheTranscriptsOrder(_ segments: [TimestampedSegment], jobID: UUID) -> [TimestampedSegment] {
        guard let file = meetingFileStore?.record(for: jobID)?.files.last(where: { $0.role == .transcript && $0.state != .gone }),
              let transcript = try? String(contentsOf: URL(filePath: file.path), encoding: .utf8)
        else { return segments }
        var ordered: [TimestampedSegment] = []
        var cursor = transcript.startIndex
        var first = segments.startIndex
        while first < segments.endIndex {
            let end = segments[first...].firstIndex { $0.start != segments[first].start } ?? segments.endIndex
            let tie = segments[first ..< end]
            let rendered = tie.filter { !$0.suppressed }
            let places = Self.places(of: rendered, in: transcript, from: cursor)
            if rendered.count > 1, let places {
                var inPlace = zip(rendered, places).enumerated()
                    .sorted { ($0.element.1.lowerBound, $0.offset) < ($1.element.1.lowerBound, $1.offset) }
                    .map(\.element.0).makeIterator()
                ordered += tie.map { $0.suppressed ? $0 : inPlace.next() ?? $0 }
            } else {
                ordered += tie
            }
            cursor = places?.map(\.upperBound).max() ?? cursor
            first = end
        }
        return ordered
    }

    /// Where the words of each of `segments` are in `transcript` from `cursor` on,
    /// no two in one place, so two lines with the same words each find their own;
    /// nil when the words of one are not there.
    private static func places(
        of segments: [TimestampedSegment], in transcript: String, from cursor: String.Index,
    ) -> [Range<String.Index>]? { // swiftlint:disable:this discouraged_optional_collection
        var taken: [Range<String.Index>] = []
        for segment in segments {
            var from = cursor
            var place: Range<String.Index>?
            while let found = transcript.range(of: segment.text, range: from ..< transcript.endIndex) {
                guard let claimed = taken.first(where: { $0.overlaps(found) }) else {
                    place = found
                    break
                }
                from = claimed.upperBound
            }
            guard let place else { return nil }
            taken.append(place)
        }
        return taken
    }

    func retaggedForThisQueue(_ segments: [TimestampedSegment]) -> [TimestampedSegment] {
        segments.map { segment in
            guard segment.speaker != DiarizationProcess.remoteSpeakerLabel else { return segment }
            var mic = segment
            mic.speaker = micLabel
            return mic
        }
    }
}

extension MeetingFileRecord {
    /// The meeting's word timings: its current segments file, nil when the record
    /// lists none or that one is gone.
    var keptWordTimings: MeetingFile? {
        files.last { $0.role == .segments }.flatMap { $0.state == .gone ? nil : $0 }
    }
}
