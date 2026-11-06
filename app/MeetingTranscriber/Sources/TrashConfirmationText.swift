import Foundation

/// What the confirmation of a Trash action on one meeting says. Pure: the files come
/// from the record, which names what the action covers, and what the disk answered
/// about the audio comes in.
struct TrashConfirmationText: Equatable, Sendable {
    let title: String
    /// One paragraph each; the last holds the file names, one per line.
    let lines: [String]
    let confirmButton = "Move to Trash"

    static func moveAudio(meetingTitle: String, record: MeetingFileRecord, audio: RecordingAudioLine.AudioOnDisk) -> Self {
        let files = record.filesCovered(by: .audioToTrash)
        let size = audio.bytes > 0 ? " (\(audio.size))" : ""
        let going = files.count == 1 ? "1 audio file\(size) goes to the Trash." : "\(files.count) audio files\(size) go to the Trash."
        return Self(title: "Move the audio of “\(meetingTitle)” to the Trash?", lines: [
            ([going] + whatStays(of: record)).joined(separator: " "),
            "Without the audio you cannot transcribe this meeting again or identify its speakers again. Voice profiles learned from it stay.",
            names(of: files),
        ])
    }

    /// Regenerate Notes reads a transcript, so without one nothing is promised about it.
    private static func whatStays(of record: MeetingFileRecord) -> [String] {
        let isThere = { (role: MeetingFile.Role) in record.files.contains { $0.role == role && $0.state != .gone } }
        return switch (isThere(.transcript), isThere(.protocol)) {
        case (true, true): ["The transcript and the meeting notes stay, and Regenerate Notes keeps working."]
        case (true, false): ["The transcript stays, and Regenerate Notes keeps working."]
        case (false, true): ["The meeting notes stay."]
        case (false, false): []
        }
    }

    static func moveMeeting(
        meetingTitle: String, record: MeetingFileRecord, audio: RecordingAudioLine.AudioOnDisk,
        hasNotionPage: Bool, hasFailedExport: Bool,
    ) -> Self {
        let files = record.filesCovered(by: .meetingToTrash).filter { !$0.role.isAudio || audio.isAnyLeft }
        var lines = [whatGoes(of: files, origin: record.origin, audio: audio)]
        if record.origin == .imported { lines.append("The imported file stays where it is.") }
        if hasNotionPage { lines.append("The page in Notion stays.") }
        if hasFailedExport { lines.append("The failed Notion export can no longer be retried.") }
        lines.append("Voice profiles learned from it stay.")
        if !files.isEmpty { lines.append(names(of: files)) }
        return Self(title: "Move “\(meetingTitle)” to the Trash?", lines: lines)
    }

    /// Names what is still on disk. An import's audio is the user's: a copy the
    /// pipeline made goes too, as one of the remaining files, not as its audio.
    private static func whatGoes(of files: [MeetingFile], origin: MeetingFileRecord.Origin, audio: RecordingAudioLine.AudioOnDisk) -> String {
        guard !files.isEmpty else { return "No file of this meeting is left to move, so it only leaves this list." }
        var named: [String] = []
        if origin == .recorded, files.contains(where: \.role.isAudio) {
            named.append(audio.bytes > 0 ? "audio (\(audio.size))" : "audio")
        }
        if files.contains(where: { $0.role == .transcript }) { named.append("transcript") }
        if files.contains(where: { $0.role == .protocol }) { named.append("meeting notes") }
        guard let last = named.last else { return "Its remaining files go to the Trash, and the meeting leaves this list." }
        let list = named.count == 1 ? last : named.dropLast().joined(separator: ", ") + " and " + last
        let verb = named.count == 1 && last != "meeting notes" ? "goes" : "go"
        return "Its \(list) \(verb) to the Trash, and the meeting leaves this list."
    }

    private static func names(of files: [MeetingFile]) -> String {
        files.map { URL(filePath: $0.path, directoryHint: .notDirectory).lastPathComponent }.joined(separator: "\n")
    }
}
