import Foundation

/// The name a meeting's current transcript or notes take when a re-run's new ones
/// take their place: the current name with `.until-<yyyyMMdd_HHmmss>` before the
/// extension, stamped with the re-run's date and time in local time, so in a plain
/// name sort it comes right after the current file and several sort by date.
///
/// A name that is taken gets `-2`, `-3`, … after the stamp; nothing is ever
/// overwritten. Taken is decided with case folded, as the volume may fold it, and
/// past `maxAttempt` there is no name: the re-run then ends and the meeting stays as
/// it was. The name never ends in `)`, so the additional-report rule
/// (`AdditionalReport`) never reads it as a report of the meeting, as it never reads
/// Regenerate's `.previous-<stamp>` copies.
enum EarlierVersionName {
    /// The last number tried after the stamp.
    static let maxAttempt = 99

    /// The earlier-version name of `current` for a re-run admitted at `stamp`,
    /// avoiding every name in `taken` (folded with `MeetingReportFolder.folded`).
    /// Nil once every name up to `maxAttempt` is taken.
    static func name(for current: String, stamp: Date, taken: Set<String>) -> String? {
        names(for: current, stamp: stamp).first { !taken.contains(MeetingReportFolder.folded($0)) }
    }

    /// Every name `name(for:stamp:taken:)` can give `current` for `stamp`, in the
    /// order it tries them.
    static func names(for current: String, stamp: Date) -> [String] {
        let url = URL(filePath: current, directoryHint: .notDirectory)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let stamped = "\(base).until-\(DateFormatter.fileVersionStamp.string(from: stamp))"
        return (1 ... maxAttempt).map { $0 == 1 ? stamped + suffix : "\(stamped)-\($0)\(suffix)" }
    }

    /// The names in `folder` as the taken check compares them; nil when the folder
    /// does not list.
    static func takenNames(in folder: URL) -> Set<String>? { // swiftlint:disable:this discouraged_optional_collection
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return Set(names.map(MeetingReportFolder.folded))
    }
}
