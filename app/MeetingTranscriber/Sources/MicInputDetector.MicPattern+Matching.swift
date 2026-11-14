import Foundation

/// How a watched app's bundle IDs match a process, split out of
/// `MicInputDetector.swift` to keep that file under the line cap.
extension MicInputDetector.MicPattern {
    /// The length of the longest of this pattern's bundle IDs that
    /// `bundleID` is or is a helper of, nil when the process is not this
    /// app's. The length ranks patterns that both match one process: an
    /// added app's bundle ID can be a prefix of another added app's
    /// (`com.acme.meet` and `com.acme.meet.beta`), and helper matching
    /// would file the second app's microphone use under the first app's
    /// key.
    func matchLength(bundleID: String) -> Int? {
        bundleIDs.lazy
            .filter { $0 == bundleID || (matchesHelpers && bundleID.hasPrefix($0 + ".")) }
            .map(\.count)
            .max()
    }
}
