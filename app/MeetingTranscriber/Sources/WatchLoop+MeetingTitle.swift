import Foundation

/// The running recording owns its title, not the detector (issue #258).
///
/// A detected meeting is named at detection after one window. For Teams the
/// best window may not exist yet then, or may sit behind another, so while a
/// detected Teams recording runs the meeting-end wait asks the detector for
/// the best-ranked Teams window again on each poll whose decision keeps
/// listening with the call signal present
/// (`MeetingDetecting.rankedWindowTitle(for:)`, ranks in `TeamsWindowTitle`).
/// A better rank than the one held replaces the title; an equal or weaker one
/// never does, so moving between two windows of one rank does not flip it, and
/// the placeholder "Microsoft Teams Call" gives way to any usable window. A
/// poll that ends the recording (a new call, the cap, the silence stop), asks
/// or withdraws the end question, or comes after the signal was lost never
/// reads the windows: a window shown after a call, or the next call's, says
/// nothing about this one.
///
/// What the loop holds is a copy of the detected meeting that differs only in
/// `windowTitle` (`titledMeeting`). While the recording runs, `currentMeeting`
/// and the status line show it ("Paused: " during a pause, which a refresh
/// neither starts nor ends); at the stop the job and a record-only sidecar
/// take it, so the file names, notices, naming dialog and template rule
/// follow. The "Meeting Detected" notice is posted once, at the change to
/// recording, and not again. The lines logged carry the rank and the number of
/// title parts only, never the title.
extension WatchLoop {
    /// Hold `meeting`'s detection title for the recording that starts now, and
    /// for a Teams meeting log which kind of window named it.
    func holdTitle(of meeting: DetectedMeeting) {
        titledMeeting = meeting
        guard TeamsWindowTitle.ranks(meeting.pattern) else { return }
        diagnostics.notice("meeting_title_rank at=detection \(Self.rankFields(of: meeting))")
    }

    /// `meeting` under the best title its recording has held so far.
    func titled(_ meeting: DetectedMeeting) -> DetectedMeeting {
        guard let titledMeeting, titledMeeting == meeting.retitled(titledMeeting.windowTitle) else { return meeting }
        return titledMeeting
    }

    /// The held title for the recording of `meeting`, which ends now: the next
    /// recording holds its own.
    func takeTitled(_ meeting: DetectedMeeting) -> DetectedMeeting {
        defer { titledMeeting = nil }
        return titled(meeting)
    }

    /// One poll's refresh, for a Teams recording whose signal is present: a
    /// better-ranked window than the held one replaces the title. Returns the
    /// new cleaned title, nil when the title stays.
    func refreshTitle(of meeting: DetectedMeeting) -> String? {
        guard TeamsWindowTitle.ranks(meeting.pattern), let offered = detector.rankedWindowTitle(for: meeting) else { return nil }
        let held = titled(meeting)
        let heldRank = Self.titleRank(of: held)
        if let heldRank, offered.rank >= heldRank { return nil }
        let retitled = meeting.retitled(offered.title)
        titledMeeting = retitled
        let title = Self.cleanTitle(offered.title)
        if state == .recording, currentMeeting == held {
            update { next in
                next.currentMeeting = retitled
                next.detail = "\(next.pausedSince == nil ? "Recording" : "Paused"): \(title)"
            }
        }
        let was = heldRank.map { String($0.rawValue) } ?? "none"
        diagnostics.notice("meeting_title_rank at=change \(Self.rankFields(of: retitled)) was=\(was)")
        return title
    }

    /// The held title's rank; nil for the placeholder, which any usable window replaces.
    private static func titleRank(of meeting: DetectedMeeting) -> TeamsWindowTitle.Rank? {
        guard meeting.windowTitle != PowerAssertionDetector.placeholderTitle(appName: meeting.pattern.appName) else { return nil }
        return TeamsWindowTitle.rank(of: meeting.windowTitle)
    }

    /// "rank=<1-4> parts=<n>", or "rank=none parts=0" for the placeholder: never the title.
    private static func rankFields(of meeting: DetectedMeeting) -> String {
        guard let rank = titleRank(of: meeting) else { return "rank=none parts=0" }
        return "rank=\(rank.rawValue) parts=\(TeamsWindowTitle.partCount(of: meeting.windowTitle))"
    }
}

extension DetectedMeeting {
    /// This meeting under another window title, every other field kept.
    func retitled(_ windowTitle: String) -> DetectedMeeting {
        DetectedMeeting(pattern: pattern, windowTitle: windowTitle, ownerName: ownerName, windowPID: windowPID, detectedAt: detectedAt)
    }
}
