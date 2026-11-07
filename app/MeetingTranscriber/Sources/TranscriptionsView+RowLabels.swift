import Foundation

/// What a row of `TranscriptionsView` calls things: pure text, kept apart from the
/// view's state.
extension TranscriptionsView {
    /// The line under a row's title: app, date and time, and duration, each
    /// "—" when the entry does not have it (a record written before the
    /// history kept it, or a duration not measured yet).
    static func detailLine(for entry: TranscriptionEntry) -> String {
        let missing = "—"
        let app = entry.appName ?? missing
        let date = entry.date?.formatted(date: .abbreviated, time: .shortened) ?? missing
        let duration = entry.audioDuration.map { formattedTime($0) } ?? missing
        return "\(app) · \(date) · \(duration)"
    }

    static func title(of action: MainAction) -> String {
        switch action {
        case .cancel: "Cancel"
        case .nameSpeakers: "Name Speakers"
        case .openProtocol: "Open Notes"
        case .openTranscript: "Open Transcript"
        case .openInNotion: "Open in Notion"
        case .retry: "Retry"
        case .remove: "Remove"
        }
    }

    static func title(of item: RowMenuItem) -> String {
        switch item {
        case let .item(plain): title(of: plain)
        case .keep: "Keep (Never Delete Automatically)"
        case .moveAudioToTrash: "Move Audio to Trash…"
        case .moveMeetingToTrash: "Move Meeting to Trash…"
        }
    }

    static func title(of item: MenuItem) -> String {
        switch item {
        case .openProtocol: "Open Notes"
        case .openTranscript: "Open Transcript"
        case .openInNotion: "Open in Notion"
        case .showInFinder: "Show in Finder"
        case .separator: ""
        case .reportsHeading: "Additional Reports"
        case let .report(report, _): report.name
        case .regenerate: "Regenerate Notes…"
        case .retry: "Retry"
        case .remove: "Remove"
        case .dismiss: "Dismiss"
        }
    }

    static func identifier(of item: RowMenuItem, index: Int) -> String {
        switch item {
        case let .item(plain): identifier(of: plain, index: index)
        case .keep: A11yID.recordingMenuKeep(index)
        case .moveAudioToTrash: A11yID.recordingMenuMoveAudioToTrash(index)
        case .moveMeetingToTrash: A11yID.recordingMenuMoveMeetingToTrash(index)
        }
    }

    static func identifier(of item: MenuItem, index: Int) -> String {
        switch item {
        case .openProtocol: A11yID.recordingMenuOpenProtocol(index)
        case .openTranscript: A11yID.recordingMenuOpenTranscript(index)
        case .openInNotion: A11yID.recordingMenuOpenInNotion(index)
        case .showInFinder: A11yID.recordingMenuShowInFinder(index)
        case .separator: ""
        case .reportsHeading: A11yID.recordingMenuReportsHeading(index)
        case let .report(_, position): A11yID.recordingMenuReport(index, position)
        case .regenerate: A11yID.recordingMenuRegenerate(index)
        case .retry: A11yID.recordingMenuRetry(index)
        case .remove: A11yID.recordingMenuRemove(index)
        case .dismiss: A11yID.recordingMenuDismiss(index)
        }
    }
}
