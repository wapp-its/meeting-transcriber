import Foundation

extension MeetingFileRecord {
    /// A re-run of the meeting from its admission until it ends, in the record and,
    /// the same, on the re-run's job. The record is its journal: the other build and
    /// the next launch read it there.
    struct RerunMarker: Codable, Equatable, Sendable {
        /// When the re-run was admitted. Its files are named by it (`stem(base:)`).
        let stamp: Date
        /// The record's outcome before the re-run, which every end but success puts back.
        let outcomeBefore: Outcome
        /// The build that admitted it, which alone acts on it.
        let bundleID: String?
        /// The process that admitted it, as a pending deletion keeps it.
        let process: DeletionProcess
        /// The id the re-run's local notes go through the local model's gate under, so
        /// a cancel of the re-run never refuses the meeting's own id.
        let runID: UUID
        /// Each file the re-run wrote, with the identity it had when it was written.
        var files: [MeetingFile] = []

        /// The stem every file of the re-run carries: the meeting's stem and the
        /// stamp. It never ends in `)` and holds no ` (`, so the additional-report
        /// rule never reads a re-run file as a report of the meeting.
        func stem(base: String) -> String {
            "\(base).rerun-\(Self.stampFormat.string(from: stamp))"
        }

        private static let stampFormat = DateFormatter.filenameStamp("yyyyMMdd_HHmmss")

        /// List a file the re-run wrote; a write to a listed path replaces its entry.
        mutating func list(_ file: MeetingFile) {
            files.removeAll { $0.path == file.path }
            files.append(file)
        }

        mutating func markGone(paths: Set<String>) {
            for index in files.indices where paths.contains(files[index].path) {
                files[index].state = .gone
            }
        }
    }

    /// Why a re-run of the meeting cannot be admitted, as far as the record says,
    /// nil when it can: the meeting has finished, no deletion of it is pending or
    /// incomplete, and no re-run of it is under way.
    var rerunRefusal: RerunRefusal? {
        guard case .finished = outcome else { return .notFinished }
        guard pending == nil, incomplete == nil else { return .deletionPending }
        return rerun == nil ? nil : .alreadyRerunning
    }

    /// The source audio a re-run reads, where the record lists it: the newest
    /// entry of each source role not marked gone. Nil for a role it lists none of.
    var rerunSourceTracks: RelocatedAudioPaths {
        func track(_ role: MeetingFile.Role) -> URL? {
            files.last { $0.role == role && $0.state != .gone }.map { URL(filePath: $0.path) }
        }
        return RelocatedAudioPaths(mix: track(.mix), app: track(.appTrack), mic: track(.micTrack))
    }
}
