import Foundation
import Observation

extension RecordingRetention {
    /// Whether this value deletes audio sooner than `other`: only such a value can make
    /// audio go that `other` holds back, so only it asks first.
    func deletesSooner(than other: Self) -> Bool {
        soonness < other.soonness
    }

    /// The one order by how soon a value deletes. `allCases` is the picker's order.
    private var soonness: Int {
        switch self {
        case .afterProtocol: 0
        case .days7: 1
        case .days30: 2
        case .days90: 3
        case .never: 4
        }
    }
}

/// What a retention value would delete now and what the user reads before it takes
/// effect. Pure: `RecordingRetentionRule` chooses, from the records and the queue, and
/// the disk's answers come in. `RecordingRetentionController.preview(for:)` asks both.
///
/// It promises what the rule says, and the check right before it deletes can keep more:
/// a folder, a link or an unreadable file at the notes path, or notes off with the
/// transcript removed by hand. The check never deletes more than this says.
struct RetentionPreview: Equatable, Sendable {
    /// What the disk answers for one audio file.
    enum FileOnDisk: Equatable, Sendable {
        case present(bytes: Int64)
        case gone
        /// Which is not "no audio": it goes once its drive is back.
        case unreachable

        /// Touches the file system, so it can block on a network or removable volume;
        /// never call it on the main actor.
        static func read(_ path: String) -> Self {
            switch MeetingFilePresence.of(path) {
            case .present: .present(bytes: (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
            case .gone: .gone
            case .unreachable: .unreachable
            }
        }
    }

    /// Meetings with audio that no value ever deletes, each counted for one reason. A
    /// meeting that only has to wait (speakers not named, a Notion export running, no
    /// notes saved) is not among them: it can still go.
    struct Skipped: Equatable, Sendable {
        var kept = 0
        var failed = 0
        var imported = 0
        var fromBeforeThisFeature = 0

        mutating func count(_ record: MeetingFileRecord, queueSaysFailed: Bool) {
            guard record.files.contains(where: { $0.role.isAudio && $0.state == .present }) else { return }
            if record.origin == .imported {
                imported += 1
            } else if record.excludedFromAutomaticDeletion {
                fromBeforeThisFeature += 1
            } else if record.outcome == .failed || queueSaysFailed {
                failed += 1
            } else if record.keep {
                kept += 1
            }
        }
    }

    /// What the rule chose, before anyone asked the disk.
    struct Selection {
        let retention: RecordingRetention
        /// Per meeting, the audio files the rule would delete now.
        let meetings: [[MeetingFile]]
        let skipped: Skipped
        /// False when the queue cannot answer for a meeting the record would let go, so
        /// what goes cannot be told.
        let isComplete: Bool

        /// The rule alone settles most, and the queue's answer can read a file, so the
        /// queue is asked only about a meeting that could go. `bundleID` is the running
        /// build's, whose meetings alone its setting reaches.
        @MainActor
        init(
            records: [MeetingFileRecord], live: @MainActor (UUID) -> LiveMeetingState?,
            isKnown: @MainActor (UUID) -> Bool = { _ in true }, retention: RecordingRetention,
            bundleID: String?, now: Date, calendar: Calendar,
        ) {
            var meetings: [[MeetingFile]] = []
            var skipped = Skipped()
            var isComplete = true
            for record in records {
                let audioToDelete = { (state: LiveMeetingState?) in
                    RecordingRetentionRule.audioToDelete(
                        record: record, live: state, retention: retention, now: now, calendar: calendar, bundleID: bundleID,
                    )
                }
                guard !audioToDelete(nil).isEmpty else {
                    skipped.count(record, queueSaysFailed: false)
                    continue
                }
                guard isKnown(record.jobID) else {
                    isComplete = false
                    continue
                }
                let state = live(record.jobID)
                let files = audioToDelete(state)
                if files.isEmpty {
                    skipped.count(record, queueSaysFailed: state?.state == .error)
                } else {
                    meetings.append(files)
                }
            }
            self.retention = retention
            self.meetings = meetings
            self.skipped = skipped
            self.isComplete = isComplete
        }
    }

    let retention: RecordingRetention
    let meetingCount: Int
    /// Of the files that answered present, each path once.
    let bytes: Int64
    /// Files whose size cannot be told, as they are out of reach.
    let unreachableFiles: Int
    let skipped: Skipped

    /// A meeting whose audio the disk confirms is all gone has nothing to delete, which
    /// is how its row reads too. One out of reach still counts: its audio goes later.
    init(_ selection: Selection, onDisk: (MeetingFile) -> FileOnDisk) {
        let left = selection.meetings.filter { files in files.contains { onDisk($0) != .gone } }
        let answers = Dictionary(left.joined().map { ($0.path, onDisk($0)) }) { first, _ in first }.values
        retention = selection.retention
        meetingCount = left.count
        bytes = answers.reduce(0) { total, answer in
            if case let .present(bytes) = answer { total + bytes } else { total }
        }
        unreachableFiles = answers.count { $0 == .unreachable }
        skipped = selection.skipped
    }

    var isEmpty: Bool {
        meetingCount == 0
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var title: String {
        "Delete the audio of \(meetingCount) \(meetingCount == 1 ? "meeting" : "meetings")?"
    }

    var confirmButton: String {
        "Delete Audio of \(meetingCount) \(meetingCount == 1 ? "Meeting" : "Meetings")"
    }

    /// The first paragraph says what goes and when, the second what never does.
    var message: String {
        let noun = meetingCount == 1 ? "meeting" : "meetings"
        let which = retention.days.map { "\(meetingCount) \(noun) recorded more than \($0) days ago" } ?? "\(meetingCount) finished \(noun)"
        let have = meetingCount == 1 ? "still has its audio" : "still have their audio"
        return "With “\(retention.title)”, \(which) \(have)\(sizeAndWhen) Transcripts and meeting notes stay.\n\n"
            + "Meetings marked Keep, failed meetings and imported files are skipped. "
            + "Recordings made before this feature existed are not touched."
    }

    /// Audio out of reach has no size to add and cannot go within the minute.
    private var sizeAndWhen: String {
        if unreachableFiles == 0 {
            " (\(size)). It is deleted for good within the next minute."
        } else if bytes == 0 {
            ", on a drive that is not connected. It is deleted for good once that drive is back."
        } else {
            " (at least \(size)). It is deleted for good within the next minute, "
                + "and what is on a drive that is not connected once that drive is back."
        }
    }
}

/// What the Recordings section asks of the app. Both come from
/// `RecordingRetentionController`, which is what holds the records and the check.
struct RetentionSettingsActions {
    /// Nil when what the value deletes cannot be told, which is no "nothing".
    let preview: @MainActor (RecordingRetention) async -> RetentionPreview?
    /// Saves a confirmed value and asks for a check.
    let apply: @MainActor (RecordingRetention) -> Void
}

/// The picker's value on its way to the setting. A value that can delete something
/// waits here until the disk has answered and the user has seen what it deletes, and is
/// dropped when what it deletes cannot be told. Everything else is saved at once, with no
/// check of its own: only a confirmed value promises one. A reference type for the reason
/// on `TranscriptionsFileNotice`.
@Observable
@MainActor
final class RetentionChoice {
    /// The value waiting, which the picker shows until it is saved or dropped.
    private(set) var candidate: RecordingRetention?
    /// What `candidate` would delete, set while the alert is open.
    private(set) var preview: RetentionPreview?
    /// The value dropped last as what it deletes could not be told, until the next choice.
    private(set) var notChecked: RecordingRetention?
    /// Asking the disk for `candidate`, which can take as long as a slow volume does.
    @ObservationIgnored private(set) var checking: Task<Void, Never>?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let actions: RetentionSettingsActions

    init(settings: AppSettings, actions: RetentionSettingsActions) {
        self.settings = settings
        self.actions = actions
    }

    var shown: RecordingRetention {
        candidate ?? settings.recordingRetention
    }

    var isChecking: Bool {
        candidate != nil && preview == nil
    }

    /// Replaces whatever was waiting, so a late answer for an earlier value is dropped.
    func choose(_ value: RecordingRetention) {
        cancel()
        let stored = settings.recordingRetention
        guard value.deletesSooner(than: stored) else {
            settings.recordingRetention = value
            return
        }
        candidate = value
        checking = Task { [weak self, actions] in
            let answer = await actions.preview(value)
            guard !Task.isCancelled, let self else { return }
            checking = nil
            guard let answer else {
                candidate = nil
                notChecked = value
                return
            }
            if answer.isEmpty {
                candidate = nil
                settings.recordingRetention = value
            } else {
                preview = answer
            }
        }
    }

    /// Takes what the alert showed, as SwiftUI may close it before running its button.
    func confirm(_ preview: RetentionPreview) {
        cancel()
        actions.apply(preview.retention)
    }

    /// Drops the value waiting, so the picker shows the stored one again.
    func cancel() {
        checking?.cancel()
        checking = nil
        candidate = nil
        preview = nil
        notChecked = nil
    }
}
