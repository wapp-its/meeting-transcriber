@testable import MeetingTranscriber
import XCTest

/// Dates and records for the pure decisions of a meeting's files: paths only, with
/// no file behind them, as those decisions never look at the disk.
enum RetentionFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt
        return calendar
    }()

    /// Reads "15 Nov".
    static let locale = Locale(identifier: "en_GB")
    /// The running build, which created every record here unless a test says otherwise.
    static let thisBuild = "com.example.meetingtranscriber.this"
    /// A second build sharing the record file, as the development and the release build do.
    static let otherBuild = "com.example.meetingtranscriber.other"
    static let recorded = date(2026, 10, 16)
    /// Long past every due date.
    static let longAfter = date(2027, 6, 1)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    static func file(_ role: MeetingFile.Role, _ name: String, owned: Bool = true, state: MeetingFile.State = .present) -> MeetingFile {
        MeetingFile(role: role, path: "/output/recordings/\(name)", identity: nil, owned: owned, state: state)
    }

    /// A finished meeting with notes on disk: for a recording three tracks of its
    /// own, for an import the user's source, plus a transcript and a protocol.
    static func record(
        origin: MeetingFileRecord.Origin = .recorded,
        recordingDate: Date? = recorded,
        outcome: MeetingFileRecord.Outcome = .finished(protocolExpected: true),
        _ change: (inout MeetingFileRecord) -> Void = { _ in },
    ) -> MeetingFileRecord {
        let tracks = origin == .recorded
            ? [file(.mix, "b_mix.wav"), file(.appTrack, "b_app.wav"), file(.micTrack, "b_mic.wav")]
            : [file(.mix, "source.wav", owned: false)]
        var record = MeetingFileRecord(
            jobID: UUID(), origin: origin, recordingDate: recordingDate,
            files: tracks + [file(.transcript, "b.txt"), file(.protocol, "b.md")], outcome: outcome, createdBy: thisBuild,
        )
        change(&record)
        return record
    }
}

extension MeetingFileRecord {
    /// Set the state of every file in `role`, or take them out of the record with nil.
    mutating func setFiles(_ role: MeetingFile.Role, to state: MeetingFile.State?) {
        guard let state else {
            files.removeAll { $0.role == role }
            return
        }
        for index in files.indices where files[index].role == role {
            files[index].state = state
        }
    }

    mutating func setAudio(to state: MeetingFile.State) {
        for index in files.indices where files[index].role.isAudio {
            files[index].state = state
        }
    }
}
