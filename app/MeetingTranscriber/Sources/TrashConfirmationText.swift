import Foundation

/// What the confirmation of a Trash action on one meeting, or on several selected ones,
/// says. Pure: the files come from the record, which names what the action covers, less
/// what the disk answered gone, and that answer and what the regenerator could read come in.
struct TrashConfirmationText: Equatable, Sendable {
    let title: String
    /// One paragraph each; the last holds the file names, one per line.
    let lines: [String]
    let confirmButton = "Move to Trash"

    /// What a confirmation of `kind` has to name: what the action covers, less what
    /// the disk answered gone.
    static func files(
        of kind: MeetingFileRecord.DeletionKind, record: MeetingFileRecord, audio: RecordingAudioLine.AudioOnDisk,
    ) -> [MeetingFile] {
        record.filesCovered(by: kind).filter { !audio.gonePaths.contains($0.path) }
    }

    static func moveAudio(
        meetingTitle: String, record: MeetingFileRecord, audio: RecordingAudioLine.AudioOnDisk,
        transcriptSource: RecordingRowActions.TranscriptSource,
    ) -> Self {
        let files = Self.files(of: .audioToTrash, record: record, audio: audio)
        let size = audio.bytes > 0 ? " (\(audio.size))" : ""
        let going = files.count == 1 ? "1 audio file\(size) goes to the Trash." : "\(files.count) audio files\(size) go to the Trash."
        return Self(title: "Move the audio of “\(meetingTitle)” to the Trash?", lines: [
            ([going] + whatStays(of: record, audio: audio, transcriptSource: transcriptSource)).joined(separator: " "),
            "Without the audio you cannot transcribe this meeting again or identify its speakers again. Voice profiles learned from it stay.",
            names(of: files.map(\.path)),
        ])
    }

    /// Regenerate Notes is promised exactly when the regenerator has a transcript to
    /// read, by its own rule: a usable transcript file, or the one the notes hold.
    private static func whatStays(
        of record: MeetingFileRecord, audio: RecordingAudioLine.AudioOnDisk, transcriptSource: RecordingRowActions.TranscriptSource,
    ) -> [String] {
        let isThere = { (role: MeetingFile.Role) in Self.isThere(role, record: record, audio: audio) }
        let staying = switch (isThere(.transcript), isThere(.protocol)) {
        case (true, true): "The transcript and the meeting notes stay"
        case (true, false): "The transcript stays"
        case (false, true): "The meeting notes stay"
        case (false, false): ""
        }
        guard !staying.isEmpty else { return [] }
        return [staying + (transcriptSource == .none ? "." : ", and Regenerate Notes keeps working.")]
    }

    /// Whether the record lists a file in `role` that the disk did not answer gone.
    private static func isThere(_ role: MeetingFile.Role, record: MeetingFileRecord, audio: RecordingAudioLine.AudioOnDisk) -> Bool {
        record.files.contains { $0.role == role && $0.state != .gone && !audio.gonePaths.contains($0.path) }
    }

    /// `reports` are the paths of the meeting's additional reports as they were just
    /// found (`MeetingReportScan`): counted after the notes and named with the other
    /// files (spec A10).
    static func moveMeeting(
        meetingTitle: String, record: MeetingFileRecord, audio: RecordingAudioLine.AudioOnDisk,
        hasNotionPage: Bool, hasFailedExport: Bool, reports: [String] = [],
    ) -> Self {
        let files = Self.files(of: .meetingToTrash, record: record, audio: audio)
        let listed = Set(files.map(\.path))
        let paths = files.map(\.path) + reports.filter { !listed.contains($0) }
        var lines = [whatGoes(of: files, origin: record.origin, audio: audio, reports: reports.count)]
        if record.origin == .imported { lines.append("The imported file stays where it is.") }
        if hasNotionPage { lines.append("The page in Notion stays.") }
        if hasFailedExport { lines.append("The failed Notion export can no longer be retried.") }
        lines.append("Voice profiles learned from it stay.")
        if !paths.isEmpty { lines.append(names(of: paths)) }
        return Self(title: "Move “\(meetingTitle)” to the Trash?", lines: lines)
    }

    /// Names what is still on disk. An import's audio is the user's: a copy the
    /// pipeline made goes too, as one of the remaining files, not as its audio.
    private static func whatGoes(
        of files: [MeetingFile], origin: MeetingFileRecord.Origin, audio: RecordingAudioLine.AudioOnDisk, reports: Int,
    ) -> String {
        guard !files.isEmpty || reports > 0 else { return "No file of this meeting is left to move, so it only leaves this list." }
        var named: [String] = []
        if origin == .recorded, files.contains(where: \.role.isAudio) {
            named.append(audio.bytes > 0 ? "audio (\(audio.size))" : "audio")
        }
        if files.contains(where: { $0.role == .transcript }) { named.append("transcript") }
        if files.contains(where: { $0.role == .protocol }) { named.append("meeting notes") }
        if let counted = reportCount(reports) { named.append(counted) }
        guard let last = named.last else { return "Its remaining files go to the Trash, and the meeting leaves this list." }
        let list = named.count == 1 ? last : named.dropLast().joined(separator: ", ") + " and " + last
        let verb = named.count == 1 && !isPlural(last) ? "goes" : "go"
        return "Its \(list) \(verb) to the Trash, and the meeting leaves this list."
    }

    private static func reportCount(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 additional report"
        default: "\(count) additional reports"
        }
    }

    private static func isPlural(_ named: String) -> Bool {
        named == "meeting notes" || named == "transcripts" || named.hasSuffix("reports")
    }

    private static func names(of paths: [String]) -> String {
        paths.map { URL(filePath: $0, directoryHint: .notDirectory).lastPathComponent }.joined(separator: "\n")
    }

    // MARK: - Several meetings

    /// The one confirmation for a selection, in the singular when one meeting is left
    /// for the action. It names no files: the plan keeps what it counted per meeting.
    static func forSelection(_ plan: TrashSelectionPlan) -> Self {
        let one = plan.meetings.count == 1
        let count = one ? "1 meeting" : "\(plan.meetings.count) meetings"
        let notes: [String?] = [keepLine(plan), leftOutLine(plan.leftOut)]
        switch plan.action {
        case .moveAudio:
            let size = plan.audioBytes > 0 ? " (\(plan.audioSize))" : ""
            let going = "\(one ? "Its" : "Their") audio\(size) goes to the Trash."
            let lost = one
                ? "Without the audio you cannot transcribe this meeting again or identify its speakers again. Voice profiles learned from it stay."
                : "Without the audio you cannot transcribe these meetings again or identify their speakers again. "
                + "Voice profiles learned from these meetings stay."
            return Self(title: "Move the audio of \(count) to the Trash?", lines: [
                ([going] + textStaying(plan)).joined(separator: " "),
            ] + notes.compactMap(\.self) + [lost])

        case .moveMeeting:
            let pages = plan.meetings.filter(\.entry.hasNotionPage).count
            let failedExports = plan.meetings.filter { $0.entry.liveNotionExport == .failed }.count
            let more: [String?] = [
                plan.hasImports ? (one ? "The imported file stays where it is." : "Imported files stay where they are.") : nil,
                pages > 0 ? (one ? "The page in Notion stays." : "Pages in Notion stay.") : nil,
                failedExports > 0 ? (one ? "The failed Notion export can no longer be retried." : "Failed Notion exports can no longer be retried.") : nil,
                one ? "Voice profiles learned from it stay." : "Voice profiles learned from these meetings stay.",
            ]
            return Self(title: "Move \(count) to the Trash?", lines: [whatGoes(plan)] + (notes + more).compactMap(\.self))
        }
    }

    /// Of one meeting as its own dialog says it, of several over all of them: a kind of
    /// file is named when any meeting has one left.
    private static func whatGoes(_ plan: TrashSelectionPlan) -> String {
        let covered = plan.meetings.map { ($0.meeting, files(of: .meetingToTrash, record: $0.meeting.record, audio: $0.meeting.audio)) }
        let reports = plan.meetings.reduce(0) { $0 + (plan.reports[$1.entry.id]?.count ?? 0) }
        if covered.count == 1, let (meeting, files) = covered.first {
            return whatGoes(of: files, origin: meeting.record.origin, audio: meeting.audio, reports: reports)
        }
        let all = covered.flatMap(\.1)
        guard !all.isEmpty || reports > 0 else { return "No file of these meetings is left to move, so they only leave this list." }
        var named: [String] = []
        if covered.contains(where: { $0.0.record.origin == .recorded && $0.1.contains(where: \.role.isAudio) }) {
            named.append(plan.audioBytes > 0 ? "audio (\(plan.audioSize))" : "audio")
        }
        if all.contains(where: { $0.role == .transcript }) { named.append("transcripts") }
        if all.contains(where: { $0.role == .protocol }) { named.append("meeting notes") }
        if let counted = reportCount(reports) { named.append(counted) }
        guard let last = named.last else { return "Their remaining files go to the Trash, and the meetings leave this list." }
        let list = named.count == 1 ? last : named.dropLast().joined(separator: ", ") + " and " + last
        let verb = named.count == 1 && !isPlural(last) ? "goes" : "go"
        return "Their \(list) \(verb) to the Trash, and the meetings leave this list."
    }

    /// What stays when only the audio goes, as far as any meeting still has it.
    private static func textStaying(_ plan: TrashSelectionPlan) -> [String] {
        let isThere = { (role: MeetingFile.Role) in
            plan.meetings.contains { Self.isThere(role, record: $0.meeting.record, audio: $0.meeting.audio) }
        }
        let one = plan.meetings.count == 1
        let staying = switch (isThere(.transcript), isThere(.protocol)) {
        case (true, true): one ? "Its transcript and meeting notes stay." : "Their transcripts and meeting notes stay."
        case (true, false): one ? "Its transcript stays." : "Their transcripts stay."
        case (false, true): one ? "Its meeting notes stay." : "Their meeting notes stay."
        case (false, false): ""
        }
        return staying.isEmpty ? [] : [staying]
    }

    /// Keep stops only the automatic deletion, which a kept meeting's row says too.
    private static func keepLine(_ plan: TrashSelectionPlan) -> String? {
        let quoted = plan.keptTitles.map { "“\($0)”" }
        guard let last = quoted.last else { return nil }
        let one = quoted.count == 1
        let names = one ? last : quoted.dropLast().joined(separator: ", ") + " and " + last
        let goes = switch plan.action {
        case .moveAudio: one ? "its audio goes too" : "their audio goes too"
        case .moveMeeting: one ? "it goes too" : "they go too"
        }
        return "\(names) \(one ? "is" : "are") marked Keep. Keep only stops automatic deletion, so \(goes)."
    }

    /// What the window says when a confirmation stopped because a file came back
    /// that it did not name.
    static func nothingMoved(meetings count: Int) -> String {
        let whose = count == 1 ? "the meeting's files" : "the files of a selected meeting"
        return "Nothing was moved: \(whose) changed while the dialog was open. Choose the action again to see what it moves now."
    }

    /// What the window says when a selection stopped part-way, because a file of the next
    /// meeting came back while the earlier ones moved.
    static func stopped(after done: Int, of total: Int) -> String {
        "Stopped after \(done) of \(total) meetings: the files of the next one changed meanwhile. "
            + "Choose the action again to see what it moves now."
    }

    private static func leftOutLine(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 selected meeting is left out, as this action does not apply to it."
        default: "\(count) selected meetings are left out, as this action does not apply to them."
        }
    }
}
