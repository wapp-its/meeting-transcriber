import Foundation

/// How long a recorded meeting's audio stays: one app-wide setting.
enum RecordingRetention: String, CaseIterable, Sendable {
    // `AppSettings` stores the raw value, which is the case name. A renamed case
    // has to keep its raw value or come with a migration:
    // `AppSettingsTests.testRecordingRetentionRawValuesArePinned` surfaces the need.
    case never
    case afterProtocol
    case days7
    case days30
    case days90

    /// The days after the recording date, for a value that counts them.
    var days: Int? {
        switch self {
        case .never, .afterProtocol: nil
        case .days7: 7
        case .days30: 30
        case .days90: 90
        }
    }

    var title: String {
        switch self {
        case .never: "Never"
        case .afterProtocol: "Right after the notes"
        case .days7: "After 7 days"
        case .days30: "After 30 days"
        case .days90: "After 90 days"
        }
    }
}

/// What the queue knows of a job it still lists. A job stays `.done` through its
/// Notion export, first run or retry, so its state alone cannot say the queue is
/// through with it.
struct LiveMeetingState: Equatable, Sendable {
    let state: JobState
    let notionExportRunning: Bool

    /// Whether the queue is through with the job for now.
    var isSettled: Bool {
        switch state {
        case .done: !notionExportRunning
        case .waiting, .transcribing, .diarizing, .generatingProtocol, .speakerNamingPending, .error: false
        }
    }
}

/// When a meeting's audio is due and which of its files the automatic check
/// deletes now. Pure: the clock and the calendar come in, and "present" is what the
/// record marks. The check is what asks the disk, right before it deletes.
enum RecordingRetentionRule {
    /// Nil where the audio is never due: under Never, for an import, a kept meeting,
    /// a recording from before this feature or one without a recording date. Right
    /// after the notes is due from the start, so only `audioToDelete`'s other
    /// conditions hold it back.
    static func dueDate(record: MeetingFileRecord, retention: RecordingRetention, calendar: Calendar) -> Date? {
        guard record.origin == .recorded, !record.keep, !record.excludedFromAutomaticDeletion,
              let recorded = record.recordingDate else { return nil }
        switch retention {
        case .never:
            return nil

        case .afterProtocol:
            return recorded

        case .days7, .days30, .days90:
            return retention.days.flatMap { calendar.date(byAdding: .day, value: $0, to: recorded) }
        }
    }

    /// Saved on disk or as a completed Notion export. A page whose export failed
    /// holds only part of the notes, so it does not count; a failed export with its
    /// Markdown on disk counts through that file.
    static func hasSavedProtocol(_ record: MeetingFileRecord) -> Bool {
        record.savedToNotion || record.files.contains { $0.role == .protocol && $0.state == .present }
    }

    /// The audio to delete now: the owned files still marked present of a meeting
    /// that finished with its notes saved, or with notes off, whose queue is through
    /// with it, with no deletion under way or left unfinished, and that is due. Empty
    /// in every other case.
    static func audioToDelete(
        record: MeetingFileRecord, live: LiveMeetingState?, retention: RecordingRetention, now: Date, calendar: Calendar,
    ) -> [MeetingFile] {
        guard case let .finished(protocolExpected) = record.outcome,
              !protocolExpected || hasSavedProtocol(record),
              live?.isSettled ?? true,
              record.incomplete == nil, record.pending == nil,
              let due = dueDate(record: record, retention: retention, calendar: calendar), due <= now
        else { return [] }
        return record.filesCovered(by: .automatic).filter { $0.state == .present }
    }
}
