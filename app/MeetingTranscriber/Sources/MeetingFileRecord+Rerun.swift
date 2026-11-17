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
        /// True from the moment an end other than success began: the next launch and
        /// the next admission remove the files it still lists, and nothing resumes
        /// it. Nil while it runs, and in a marker from before this field.
        var ending: Bool? // swiftlint:disable:this discouraged_optional_boolean
        /// The swap's renames, in the order it makes them, written before the first
        /// one: the next launch completes or undoes the swap from them. Nil until
        /// the swap starts, and in a marker from before this field.
        var renames: [Rename]? // swiftlint:disable:this discouraged_optional_collection

        var isEnding: Bool {
            ending == true
        }

        /// The stem every file of the re-run carries: the meeting's stem and the
        /// stamp. It never ends in `)` and holds no ` (`, so the additional-report
        /// rule never reads a re-run file as a report of the meeting.
        func stem(base: String) -> String {
            "\(base).rerun-\(DateFormatter.fileVersionStamp.string(from: stamp))"
        }

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

    /// One rename of the swap: a current file to its earlier-version name, or a
    /// file of the re-run to the current name of its role. A rename keeps the file's
    /// identity, so `identity` finds the file at either end.
    struct Rename: Codable, Equatable, Sendable {
        let role: MeetingFile.Role
        let from: String
        let to: String
        let identity: FileIdentity?
        /// A current file kept as an earlier version, not a file of the re-run.
        let earlier: Bool
    }

    /// How a re-run ended, in the record from its end until the next re-run is
    /// admitted: its stamp, and whether its files took the current names.
    struct RerunNote: Codable, Equatable, Sendable {
        let stamp: Date
        let committed: Bool
    }

    /// Why a re-run of the meeting cannot be admitted, as far as the record says,
    /// nil when it can: the meeting has finished, no deletion of it is pending or
    /// incomplete, and no re-run of it is under way or left files behind.
    var rerunRefusal: RerunRefusal? {
        if rerun?.isEnding == true { return .filesLeft }
        guard case .finished = outcome else { return .notFinished }
        guard pending == nil, incomplete == nil else { return .deletionPending }
        return rerun == nil ? nil : .alreadyRerunning
    }

    /// One end of the re-run `marker` names, other than success, written into the
    /// record in one update: the outcome it had before, and with no file of the
    /// re-run `left` the marker gone and the stamp noted as ended. A file left keeps
    /// the marker, as ending and listing only the files left (A27). A record that
    /// carries another re-run's marker, or already notes this one, is left as it is.
    /// A record without either, as an older build rewrites one, ends from `marker`.
    mutating func endRerun(_ marker: RerunMarker, leaving left: [MeetingFile]) {
        if let current = rerun {
            guard current.runID == marker.runID else { return }
        } else if rerunNote?.stamp == marker.stamp {
            return
        }
        outcome = marker.outcomeBefore
        if left.isEmpty {
            rerun = nil
            rerunNote = RerunNote(stamp: marker.stamp, committed: false)
        } else {
            var kept = rerun ?? marker
            kept.files = left
            kept.ending = true
            rerun = kept
        }
    }

    /// The swap's commit point, in one update: each new file listed under its role
    /// with the identity it has now (`current`), last of its role, so it is the one
    /// the meeting's current file is read from; the earlier versions and the re-run's
    /// files it could not remove appended as owned kept files; the marker gone, the
    /// stamp noted as committed and the outcome finished. A file of the role in
    /// another output folder stays listed, so a deletion still finds it. False, with
    /// nothing changed, for a record that carries another re-run's marker or none.
    mutating func commitRerun(
        _ marker: RerunMarker, current: [MeetingFile], kept: [MeetingFile], protocolExpected: Bool,
    ) -> Bool {
        guard rerun?.runID == marker.runID else { return false }
        for file in current + kept {
            appendKept(file)
        }
        rerun = nil
        rerunNote = RerunNote(stamp: marker.stamp, committed: true)
        outcome = .finished(protocolExpected: protocolExpected)
        return true
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
