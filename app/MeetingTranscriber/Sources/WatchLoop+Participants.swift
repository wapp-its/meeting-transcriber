import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Who is in a detected meeting, split out of `WatchLoop.swift` to keep that
/// file under the line cap.
extension WatchLoop {
    /// The participants of a Teams meeting, read once as its recording
    /// starts; empty for every other app and when none could be read.
    func readParticipants(of meeting: DetectedMeeting) -> [String] {
        guard meeting.pattern.appName == "Microsoft Teams",
              let names = ParticipantReader.readParticipants(pid: meeting.windowPID),
              !names.isEmpty
        else { return [] }
        logger.info("Detected \(names.count) participants")
        return names
    }
}
