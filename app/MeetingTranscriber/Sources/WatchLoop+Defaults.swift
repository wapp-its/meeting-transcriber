import Foundation

/// The production defaults `WatchLoop` falls back on, split out of
/// `WatchLoop.swift` to keep that file under the line cap.
extension WatchLoop {
    nonisolated static var defaultOutputDir: URL {
        AppPaths.downloadsProtocolsDir
    }

    nonisolated static func defaultDetector() -> any MeetingDetecting {
        PowerAssertionDetector()
    }
}
