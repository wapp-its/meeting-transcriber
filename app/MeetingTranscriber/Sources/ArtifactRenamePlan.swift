import Foundation

/// Plans the rename of one job's on-disk artifacts from one stem to another
/// (the "use the AI title for filenames" feature). Pure: every filesystem fact
/// comes in through `exists`, nothing is touched here, so the decisions can be
/// tested without a queue and the executor only has to run what this returns.
///
/// The artifacts are enumerated from the closed suffix lists the pipeline writes
/// with, never found by scanning a directory for a prefix. Once a stem has been
/// replaced by a bare title it carries no short id any more, and a prefix match
/// on `weekly_sync` would also pick up `weekly_sync_ab12cd34_mix.wav` and
/// `weekly_sync_retro_mix.wav`, which belong to other jobs. The one exception is
/// the meeting's additional reports, which no list names: the ownership rule
/// (`AdditionalReport`) finds them by their whole name before ` (`, so
/// `weekly_sync_retro (Short).md` is never a report of `weekly_sync`.
enum ArtifactRenamePlan {
    struct Move: Equatable {
        let from: URL
        let to: URL
    }

    /// The two output folders a job's artifacts live in.
    struct Directories {
        let protocols: URL
        let recordings: URL
    }

    /// Every file a job can own under `stem`, in both output directories.
    static func artifactURLs(stem: String, in dirs: Directories) -> [URL] {
        let recordingSuffixes = [
            RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic,
        ] + SpeakerNamingStore.sidecarSuffixes + [SpeakerNamingStore.namingJSONSuffix]
        return ["\(stem).md", "\(stem).txt"].map { dirs.protocols.appendingPathComponent($0) }
            + recordingSuffixes.map { dirs.recordings.appendingPathComponent("\(stem)\($0)") }
    }

    /// The stem a job should carry for `titleSlug`, or `nil` when no free one
    /// exists. A stem is free only if *none* of its artifacts exist in either
    /// directory: a protocol the user moved away leaves its audio behind, and
    /// that audio still belongs to the earlier meeting.
    ///
    /// Returns `currentStem` when the job already carries the title (or the
    /// title plus its short id), so a regenerated protocol never renames a job
    /// onto itself or stacks a second suffix. A candidate with an additional report
    /// in `protocolNames`, the protocols folder's file names, is taken as well.
    static func availableStem(
        titleSlug: String,
        shortID: String,
        currentStem: String,
        in dirs: Directories,
        protocolNames: Set<String> = [],
        exists: (URL) -> Bool,
    ) -> String? {
        let suffixed = "\(titleSlug)_\(shortID)"
        if currentStem == titleSlug || currentStem == suffixed { return currentStem }
        return [titleSlug, suffixed].first { candidate in
            !artifactURLs(stem: candidate, in: dirs).contains(where: exists) && reports(of: candidate, in: protocolNames).isEmpty
        }
    }

    /// The names of `stem`'s additional reports among `protocolNames`, judged from the
    /// names alone: a longer meeting counts as one only by its transcript file, so a
    /// report is seen where there may be none, which only ever keeps a name taken.
    static func reports(of stem: String, in protocolNames: Set<String>) -> [String] {
        let prefix = "\(stem) ("
        let transcripts = Set(protocolNames.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) })
        return MeetingReportFolder(basename: stem, names: protocolNames, transcriptStems: transcripts).reports.map(\.name)
    }

    /// The moves that carry every existing artifact of `oldStem` over to
    /// `newStem`, each within its own directory, and then each of its additional
    /// reports, named in `reports`, `<old stem> (<name>).md` to `<new stem> (<name>).md`.
    static func moves(
        from oldStem: String,
        to newStem: String,
        in dirs: Directories,
        reports: [String] = [],
        exists: (URL) -> Bool,
    ) -> [Move] {
        let artifacts = zip(artifactURLs(stem: oldStem, in: dirs), artifactURLs(stem: newStem, in: dirs))
            .compactMap { from, to in exists(from) ? Move(from: from, to: to) : nil }
        return artifacts + reports.map { name in
            Move(
                from: dirs.protocols.appendingPathComponent(AdditionalReport.fileName(basename: oldStem, name: name)),
                to: dirs.protocols.appendingPathComponent(AdditionalReport.fileName(basename: newStem, name: name)),
            )
        }
    }
}
