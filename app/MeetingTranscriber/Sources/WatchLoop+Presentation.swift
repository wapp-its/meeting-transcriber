import Foundation

extension WatchLoop {
    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    /// Strip app suffixes from meeting titles for cleaner display, and Teams'
    /// compact call window prefix ("Meeting compact view | Meeting in General"
    /// reads "Meeting in General"; `TeamsWindowTitle`).
    static func cleanTitle(_ title: String) -> String {
        let suffixes = [" | Microsoft Teams", " - Zoom", " - Webex"]
        let suffix = suffixes.first { title.hasSuffix($0) }
        return TeamsWindowTitle.withoutCompactPrefix(suffix.map { String(title.dropLast($0.count)) } ?? title)
    }

    /// Map WatchLoop state to TranscriberState for compatibility with existing UI.
    var transcriberState: TranscriberState {
        switch state {
        case .idle: .idle
        case .watching: .watching
        case .recording: .recording
        case .error: .error
        }
    }
}
