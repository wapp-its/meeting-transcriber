import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The Teams roster read when a detected meeting starts recording, split out
/// of `WatchLoop.swift` to keep that file under the line cap.
extension WatchLoop {
    /// The participants Teams lists for `meeting`; empty for any other app and
    /// when the roster cannot be read.
    static func teamsParticipants(of meeting: DetectedMeeting) -> [String] {
        guard meeting.pattern.appName == "Microsoft Teams",
              let names = ParticipantReader.readParticipants(pid: meeting.windowPID),
              !names.isEmpty
        else { return [] }
        logger.info("Detected \(names.count) participants")
        return names
    }
}
