import Foundation

extension WatchLoop {
    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    /// Strip app suffixes from meeting titles for cleaner display.
    static func cleanTitle(_ title: String) -> String {
        let suffixes = [" | Microsoft Teams", " - Zoom", " - Webex"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }

    /// The title a recording of `meeting` shows and is named after:
    /// `cleanTitle`, and for Teams also without the compact call window's
    /// prefix ("Meeting compact view | Meeting in General" reads "Meeting in
    /// General"; `TeamsWindowTitle`). Every other app keeps `cleanTitle` alone.
    static func cleanTitle(of meeting: DetectedMeeting) -> String {
        let title = cleanTitle(meeting.windowTitle)
        return TeamsWindowTitle.ranks(meeting.pattern) ? TeamsWindowTitle.withoutCompactPrefix(title) : title
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
