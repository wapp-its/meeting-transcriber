import Foundation

/// What a row of the All Recordings window says about its audio: one line, the Keep
/// badge after the title, and why a deletion stopped. Pure: the record, what the disk
/// answered, the clock, calendar and locale all come in, so the view only renders it.
struct RecordingAudioLine: Equatable, Sendable {
    /// A meeting's audio as `MeetingFilePresence` answered for it. The caller asks,
    /// and never from a view body, as an unplugged drive can block the answer.
    struct AudioOnDisk: Equatable, Sendable {
        let presentCount: Int
        /// Out of reach, which is neither there nor gone.
        let unreachableCount: Int
        /// Every audio file the record lists as the app's, each path once, also those
        /// gone: what "2 of 3 files" counts.
        let totalCount: Int
        /// Of the present files only.
        let bytes: Int64
        /// Files of the meeting, audio or not, that the record still lists and the
        /// disk answered gone: a file removed by hand, which the record learns only
        /// when an action finds it gone. The confirmations leave them out.
        var gonePaths: Set<String> = []

        /// False only when the disk confirmed that none is there.
        var isAnyLeft: Bool {
            presentCount + unreachableCount > 0
        }

        var size: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// Nil for a row without a record and for a meeting still being processed.
    let text: String?
    let showsKeepBadge: Bool
    /// "Deletion incomplete: <reason>", which the row shows in place of its status.
    let incompleteText: String?

    /// `live` is nil when the queue no longer lists the job, and `audio` nil when the
    /// row has no record.
    static func resolve( // swiftlint:disable:this function_parameter_count
        record: MeetingFileRecord?, live: LiveMeetingState?, audio: AudioOnDisk?, retention: RecordingRetention,
        now: Date, calendar: Calendar, locale: Locale,
    ) -> Self {
        guard let record, let audio else { return Self(text: nil, showsKeepBadge: false, incompleteText: nil) }
        let inputs = Inputs(record: record, live: live, audio: audio, retention: retention, now: now, calendar: calendar, locale: locale)
        return Self(
            text: inputs.text,
            showsKeepBadge: record.keep,
            incompleteText: record.incomplete.map { "Deletion incomplete: \($0.reason)" },
        )
    }

    private struct Inputs {
        /// Where the meeting stands. The queue wins while it lists the job, as a
        /// record's outcome only changes when a job ends or is retried.
        enum Standing {
            case naming
            case failed
            case finished(protocolExpected: Bool)
            case leftUnfinished
        }

        let record: MeetingFileRecord
        let live: LiveMeetingState?
        let audio: AudioOnDisk
        let retention: RecordingRetention
        let now: Date
        let calendar: Calendar
        let locale: Locale

        /// Nil while the meeting is being processed, here or in another build.
        var standing: Standing? {
            switch live?.state {
            case .waiting, .transcribing, .diarizing, .generatingProtocol:
                nil

            case .speakerNamingPending:
                .naming

            case .error:
                .failed

            case .done, nil:
                switch record.outcome {
                case .inProgress: nil
                case .failed: .failed
                case let .finished(protocolExpected): .finished(protocolExpected: protocolExpected)
                case .leftUnfinished: .leftUnfinished
                }
            }
        }

        /// An import reads the same in every state, as it is true in all of them and
        /// a line about waiting would suggest the file goes afterwards. After that,
        /// what happened to the files decides, and only with some on disk their size
        /// and what happens to them next.
        var text: String? {
            guard let standing else { return nil }
            if record.origin == .imported { return "Audio · your imported file, never deleted by the app" }
            if let deletion = record.audioDeletion { return deleted(deletion) }
            if record.incomplete != nil, audio.totalCount > 0 { return moved }
            guard audio.presentCount > 0 else {
                return audio.unreachableCount > 0 ? "Audio · on a drive that is not connected" : "Audio not found"
            }
            return "Audio · \(audio.size)" + (next(standing).map { " · \($0)" } ?? "")
        }

        func deleted(_ deletion: MeetingFileRecord.AudioDeletion) -> String {
            switch deletion.kind {
            case .manual: "Audio moved to the Trash on \(day(deletion.at))"
            case .automatic: "Audio deleted automatically on \(day(deletion.at))"
            }
        }

        var moved: String {
            let count = max(0, audio.totalCount - audio.presentCount - audio.unreachableCount)
            return "Audio · \(count) of \(audio.totalCount) \(audio.totalCount == 1 ? "file" : "files") moved to the Trash"
        }

        /// What happens to audio on disk, or nil when the line has nothing to promise.
        /// Keep is true in every state, and the setting only reaches a finished meeting.
        func next(_ standing: Standing) -> String? {
            if record.keep { return "kept, never deleted automatically" }
            switch standing {
            case .naming:
                return "kept until the speakers are named"

            case .failed:
                return "kept while the meeting has failed"

            case .leftUnfinished:
                return nil

            case let .finished(protocolExpected):
                guard retention != .never else { return nil }
                if live?.notionExportRunning == true { return "kept until the Notion export ends" }
                if protocolExpected, !RecordingRetentionRule.hasSavedProtocol(record) { return "kept, no notes were saved" }
                return RecordingRetentionRule.dueDate(record: record, retention: retention, calendar: calendar).map { due in
                    "deleted automatically \(due <= now ? "at the next check" : "on \(day(due))")"
                }
            }
        }

        /// Day and abbreviated month, "15 Nov" in en_GB.
        func day(_ date: Date) -> String {
            date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
        }
    }
}
