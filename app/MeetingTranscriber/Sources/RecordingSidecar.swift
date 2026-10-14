import Foundation

/// Metadata sidecar written next to dual-source recordings when record-only
/// mode is enabled. Consumed by an external transcription/diarization
/// pipeline (e.g. on a Linux GPU host) so it doesn't have to re-detect
/// context the macOS client already knows.
struct RecordingSidecar: Codable {
    /// Filename suffix appended to the recording basename to form the sidecar
    /// filename (e.g. `20260503_120000` → `20260503_120000_meta.json`).
    static let filenameSuffix = "_meta.json"

    /// Schema version stamped into every new sidecar. Bump when fields are
    /// added/removed/repurposed so downstream consumers can branch on it.
    /// 2 added `trigger`, 3 added `pauses`.
    static let currentVersion = 3

    /// How the recording was started. Consumers apply different policies to
    /// the two: a very short auto capture is usually a false trigger worth
    /// discarding, while a short manual recording is deliberate. Without this
    /// the only downstream signal is duration, which cannot tell them apart.
    enum Trigger: String, Codable {
        /// Started by a meeting detector, including browser meetings where the
        /// user only confirmed a consent prompt the detector raised.
        case auto
        /// Started by the user picking an app in the recording picker.
        case manual
    }

    let version: Int
    let title: String
    let appName: String
    let startedAt: Date
    let stoppedAt: Date
    let participants: [String]
    let micDelaySeconds: TimeInterval
    let files: Files
    /// The stretches in which nothing was recorded, in order, each with its
    /// wall-clock times and its position on the saved tracks. Nil when the
    /// recording had none, which is also how a version 1 or 2 sidecar reads.
    /// `startedAt` and `stoppedAt` stay wall-clock times, so the audio
    /// recorded is about `stoppedAt - startedAt` minus the pauses' lengths.
    let pauses: [RecordingPause]? // swiftlint:disable:this discouraged_optional_collection

    /// Raw storage so an unrecognised value decodes as `nil` instead of
    /// throwing. `read()` swallows decode errors, so a strict `Trigger?` would
    /// let one future value discard the entire sidecar on the reimport path
    /// (title, participants and meeting-start included) rather than just the
    /// one field this build cannot interpret.
    private let triggerRaw: String?

    /// `nil` for version 1 sidecars, which predate the field, and for values
    /// introduced by a newer schema version than this build knows.
    var trigger: Trigger? {
        triggerRaw.flatMap(Trigger.init(rawValue:))
    }

    struct Files: Codable {
        let mix: String
        let app: String?
        let mic: String?
    }

    private enum CodingKeys: String, CodingKey {
        case version, title, appName, startedAt, stoppedAt
        case participants, micDelaySeconds, files, pauses
        case triggerRaw = "trigger"
    }

    init(
        title: String,
        appName: String,
        startedAt: Date,
        stoppedAt: Date,
        participants: [String],
        micDelaySeconds: TimeInterval,
        trigger: Trigger,
        mixFilename: String,
        appFilename: String?,
        micFilename: String?,
        pauses: [RecordingPause] = [],
    ) {
        self.version = Self.currentVersion
        self.title = title
        self.appName = appName
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.participants = participants
        self.micDelaySeconds = micDelaySeconds
        self.triggerRaw = trigger.rawValue
        self.files = Files(mix: mixFilename, app: appFilename, mic: micFilename)
        self.pauses = pauses.isEmpty ? nil : pauses
    }

    /// Writes the sidecar as `<basename>\(filenameSuffix)` into `directory`.
    /// Returns the resulting URL.
    @discardableResult
    func write(toDirectory directory: URL, basename: String) throws -> URL {
        let url = directory.appendingPathComponent("\(basename)\(Self.filenameSuffix)")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        // Holds meeting title + participants — match the owner-only (0600)
        // treatment of the audio it sits beside.
        try FileManager.default.restrictToOwner(url)
        return url
    }

    /// Decode `<directory>/<basename>\(filenameSuffix)`, or nil when missing/malformed.
    static func read(fromDirectory directory: URL, basename: String) -> Self? {
        let url = directory.appendingPathComponent("\(basename)\(Self.filenameSuffix)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }
}
