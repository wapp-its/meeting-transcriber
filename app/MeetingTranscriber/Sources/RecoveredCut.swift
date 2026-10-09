import Foundation

/// Applies a stored meeting-end cut (`PendingRecordingCut`) when the launch
/// recovery of the staging folder brings back a recording the app died with
/// while the "meeting seems to have ended" question was open.
///
/// The countdown would have cut that recording back to where the silent stop
/// used to end it. Recovery makes the same cut before the recording is queued,
/// so the room audio recorded while asking is neither kept nor transcribed.
///
/// A pass runs in three steps around the rest of the staging recovery:
/// `collect` first, before any header is repaired or any track re-mixed,
/// because both rewrite the files whose last write stands in for the stop;
/// then the re-mix of crashed recordings; then `apply`, before the orphan scan
/// queues anything. Passes never overlap (`PipelineController` serializes
/// them), so a stored cut is only ever changed by one pass at a time.
///
/// Every stored cut a pass settles gets one diagnostics line, and no line
/// carries the recording's stem or a path: the stem of an imported recording
/// is derived from its title.
enum RecoveredCut {
    /// How long after the countdown's deadline a recording's capture may have
    /// ended and still have its stored cut applied without a resolved
    /// `keptSeconds`. An unanswered countdown stops the recording at its
    /// deadline, so one whose capture ran on clearly longer was kept (Keep
    /// recording or a returning signal) and its stored cut is one whose
    /// removal failed. Five minutes covers the whole stop sequence of a
    /// recording up to the 4-hour cap (the poll after the deadline, the
    /// recorder's stop and mix build, the live cut's copying), with margin.
    static let deadlineTolerance: TimeInterval = 5 * 60

    /// Why a stored cut is not applied. The raw value is the `reason=` the
    /// diagnostics line carries.
    enum Refusal: String, Equatable, Sendable {
        /// The file cannot be applied: unreadable, empty, an unknown
        /// version, times out of order or a non-positive `keptSeconds`.
        case unreadable
        /// It names another recording than its file does.
        case otherRecording = "other_recording"
        /// Its recording went on past the deadline plus `deadlineTolerance`.
        case ranPastDeadline = "ran_past_deadline"
        /// Nothing says when its recording's capture stopped.
        case noCaptureEnd = "no_capture_end"
        /// The cut would keep nothing of the audio.
        case nothingToKeep = "nothing_to_keep"
        /// Its recording is gone: no mix, no marker, no hidden original.
        case stale

        init(_ reason: PendingRecordingCut.InvalidReason) {
            self = reason == .otherRecording ? .otherRecording : .unreadable
        }
    }

    enum Decision: Equatable, Sendable {
        /// Keep the first `keptSeconds` of the recording's timeline.
        case cut(keptSeconds: TimeInterval)
        case refuse(Refusal)
    }

    /// Where the stored cut lands on a recording whose mix is `mixDuration`
    /// long, or why it does not apply.
    ///
    /// A resolved `keptSeconds` is used exactly as stored: it was set before
    /// any track was cut, and placing the cut again on a cut (or partly cut)
    /// recording would read the shortened mix and cut deeper. Without it, the
    /// deadline check runs and the live cut's two-estimate placement is made
    /// with the capture end standing in for the stop.
    static func decide(record: PendingRecordingCut, mixDuration: TimeInterval?) -> Decision {
        if let kept = record.keptSeconds { return .cut(keptSeconds: kept) }
        guard let captureEndedAt = record.captureEndedAt else { return .refuse(.noCaptureEnd) }
        guard captureEndedAt <= record.deadline.addingTimeInterval(deadlineTolerance) else {
            return .refuse(.ranPastDeadline)
        }
        let kept = RecordingCut.keptSeconds(
            cutAt: record.cutAt,
            startedAt: record.startedAt,
            stoppedAt: captureEndedAt,
            mixDuration: mixDuration,
        )
        return kept > 0 ? .cut(keptSeconds: kept) : .refuse(.nothingToKeep)
    }

    // MARK: - Collect

    /// Every stored cut in `dir` this pass may settle: not hidden, and not
    /// held by a stop of this process. An invalid one is removed and logged
    /// here, leaving its recording untouched. A valid one without a capture
    /// end gets it now, from when its capture files were last written, and
    /// stores it, so a pass interrupted after the re-mix (which writes new
    /// track files) leaves the next pass the original evidence. A store that
    /// fails is logged, and the value read is still used for this pass.
    static func collect(
        in dir: URL,
        diagnostics: any DiagnosticsLogging,
        sync: @escaping PendingRecordingCut.Sync = PendingRecordingCut.fullSync,
    ) -> [PendingRecordingCut] {
        let pass = Pass(dir: dir, diagnostics: diagnostics, rename: RecordingCut.rename, sync: sync)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var collected: [PendingRecordingCut] = []
        for name in names.sorted() {
            guard let stem = stem(ofStoredCut: name), !PendingRecordingCut.isHeld(stem) else { continue }
            switch PendingRecordingCut.read(stem: stem, in: dir) {
            case .absent:
                continue

            case let .invalid(reason):
                pass.refuse(stem: stem, Refusal(reason))

            case var .valid(record):
                if record.captureEndedAt == nil, let end = captureEnd(stem: stem, in: dir) {
                    record.captureEndedAt = end
                    let outcome = PendingRecordingCut.recordResolution(
                        stem: stem, in: dir, keptSeconds: nil, captureEndedAt: end, sync: sync,
                    )
                    pass.logFailedStore(outcome, value: "capture_end")
                }
                collected.append(record)
            }
        }
        return collected
    }

    /// The stem of a stored cut's file name, nil for every other file. Hidden
    /// files never count: a write's temporary file is one, and so is the
    /// `._` companion some volumes create beside every file.
    private static func stem(ofStoredCut name: String) -> String? {
        guard !name.hasPrefix("."), name.hasSuffix(RecordingFileSuffix.pendingCut) else { return nil }
        return String(name.dropLast(RecordingFileSuffix.pendingCut.count))
    }

    /// When the recording's capture stopped: the last write of the files
    /// written during capture (the raw app temp and the microphone track),
    /// or, for an app-only recording the recorder stopped before the crash,
    /// of the app track. Never the mix, which only exists after the stop.
    private static func captureEnd(stem: String, in dir: URL) -> Date? {
        if let written = DualSourceRecorder.lastTrackWrite(stem: stem, in: dir) { return written }
        let app = dir.appendingPathComponent(stem + RecordingFileSuffix.app)
        return (try? FileManager.default.attributesOfItem(atPath: app.path)[.modificationDate]) as? Date
    }

    // MARK: - Apply

    /// Settle each collected stored cut, after the crashed recordings were
    /// re-mixed and before the orphan scan queues them. One failing never
    /// stops the others.
    ///
    /// - Parameter rename: the atomic rename for the restores and the cut,
    ///   injectable so a test can fail them.
    static func apply(
        _ collected: [PendingRecordingCut],
        in dir: URL,
        diagnostics: any DiagnosticsLogging,
        rename: @escaping (URL, URL) throws -> Void = RecordingCut.rename,
        sync: @escaping PendingRecordingCut.Sync = PendingRecordingCut.fullSync,
    ) {
        let pass = Pass(dir: dir, diagnostics: diagnostics, rename: rename, sync: sync)
        for record in collected {
            pass.settle(record)
        }
    }

    /// The paths of one recording's three tracks in the staging folder.
    private struct Tracks {
        let mix: URL
        let app: URL
        let mic: URL

        init(stem: String, in dir: URL) {
            mix = dir.appendingPathComponent(stem + RecordingFileSuffix.mix)
            app = dir.appendingPathComponent(stem + RecordingFileSuffix.app)
            mic = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        }

        var all: [URL] {
            [mix, app, mic]
        }
    }

    /// What one pass works with: the staging folder, the diagnostics sink and
    /// the file operations a test may fail.
    private struct Pass {
        let dir: URL
        let diagnostics: any DiagnosticsLogging
        let rename: (URL, URL) throws -> Void
        let sync: PendingRecordingCut.Sync

        func settle(_ record: PendingRecordingCut) {
            let tracks = Tracks(stem: record.stem, in: dir)
            // First, whatever is on disk: an original an earlier cut's
            // rollback left under its hidden name goes back on its path, so
            // the mix counts as present and the orphan scan finds the
            // recording. Until it can, the recording is not settled.
            let hidden = tracks.all.compactMap { path -> (path: URL, backup: URL)? in
                let backup = RecordingCut.backupURL(for: path)
                return exists(path) || !exists(backup) ? nil : (path, backup)
            }
            if let failure = moveBack(hidden) {
                leaveUnsettled(failure, tracks: tracks)
                return
            }
            // With every hidden original back, a missing mix is either one the
            // re-mix could not build yet (its marker is still there, so a later
            // pass retries) or a recording that is gone.
            guard exists(tracks.mix) else {
                if exists(DualSourceRecorder.inProgressMarker(stem: record.stem, in: dir)) { return }
                refuse(stem: record.stem, .stale)
                return
            }
            let mixDuration = RecordingCut.duration(of: tracks.mix)
            switch decide(record: record, mixDuration: mixDuration) {
            case let .refuse(reason):
                refuse(stem: record.stem, reason)

            case let .cut(kept):
                cut(record, keepingFirst: kept, mixDuration: mixDuration, tracks: tracks)
            }
        }

        private func cut(
            _ record: PendingRecordingCut,
            keepingFirst kept: TimeInterval,
            mixDuration: TimeInterval?,
            tracks: Tracks,
        ) {
            // Resolved before any track changes, so a pass that dies inside
            // the cut leaves the next one this same point to finish at. A
            // failed store does not stop the cut.
            if record.keptSeconds == nil {
                let outcome = PendingRecordingCut.recordResolution(
                    stem: record.stem, in: dir, keptSeconds: kept, captureEndedAt: record.captureEndedAt, sync: sync,
                )
                logFailedStore(outcome, value: "kept_s")
            }
            // The recovered tracks are aligned at their file starts (the
            // re-mix and the orphan scan both use no microphone delay), so
            // every one is cut at the same point.
            let recording = RecordingResult(
                mixPath: tracks.mix,
                appPath: exists(tracks.app) ? tracks.app : nil,
                micPath: exists(tracks.mic) ? tracks.mic : nil,
                micDelay: 0,
                recordingStartDate: .distantPast,
            )
            do {
                try RecordingCut.apply(to: recording, keepingFirst: kept, rename: rename)
            } catch {
                failed(error, record: record, tracks: tracks)
                return
            }
            // What the mix holds now, not `kept`: a resolved cut read back
            // from disk may lie past the recording's end.
            let keptOfMix = RecordingCut.duration(of: tracks.mix) ?? 0
            let removed = max(0, (mixDuration ?? keptOfMix) - keptOfMix)
            diagnostics.notice("recovered_cut applied removed_s=\(Int(removed.rounded())) kept_s=\(Int(keptOfMix.rounded()))")
            remove(stem: record.stem)
        }

        /// A cut that failed. With every original back on its path the
        /// recording is queued uncut. The cut's own rollback may have left
        /// some under their hidden names, which are put back once here first.
        private func failed(_ error: any Error, record: PendingRecordingCut, tracks: Tracks) {
            if case let RecordingCut.CutError.rollbackIncomplete(uncut) = error {
                if let failure = moveBack(uncut.map { (path: $0.key, backup: $0.value) }) {
                    leaveUnsettled(failure, tracks: tracks)
                    return
                }
                diagnostics.warning("recovered_cut_failed rollback_incomplete tracks_moved=\(uncut.count) \(fields(error))")
            } else {
                diagnostics.warning("recovered_cut_failed \(fields(error))")
            }
            remove(stem: record.stem)
        }

        /// An original that stays hidden leaves the recording unsettled: the
        /// stored cut stays, and the recording must stay out of the queue
        /// too. The orphan scan after this pass takes any recording whose mix
        /// is on its path, and one queued now would be processed uncut and
        /// without the hidden track, which nothing would process afterwards.
        /// So the mix joins the hidden originals under its own hidden name,
        /// unless an original is already kept there, and every pass restores
        /// it first: the recording is queued once all its tracks are back.
        private func leaveUnsettled(_ failure: (left: Int, error: any Error), tracks: Tracks) {
            diagnostics.warning("recovered_cut_failed restore tracks_left=\(failure.left) \(fields(failure.error))")
            let backup = RecordingCut.backupURL(for: tracks.mix)
            guard exists(tracks.mix), !exists(backup) else { return }
            do {
                try rename(tracks.mix, backup)
            } catch {
                diagnostics.warning("recovered_cut_failed hide_mix \(fields(error))")
            }
        }

        /// Rename each hidden original back onto its path, once. Nil when
        /// every one is back, else how many stayed hidden and the first error.
        private func moveBack(_ originals: [(path: URL, backup: URL)]) -> (left: Int, error: any Error)? {
            var left = 0
            var firstError: (any Error)?
            for original in originals {
                do {
                    try rename(original.backup, original.path)
                } catch {
                    left += 1
                    if firstError == nil { firstError = error }
                }
            }
            return firstError.map { (left, $0) }
        }

        // MARK: Lines and removal

        func refuse(stem: String, _ reason: Refusal) {
            diagnostics.notice("recovered_cut refused reason=\(reason.rawValue)")
            remove(stem: stem)
        }

        private func remove(stem: String) {
            switch PendingRecordingCut.remove(stem: stem, in: dir, sync: sync) {
            case .removed:
                return

            case let .removedNotSynced(error):
                diagnostics.warning("recovered_cut_remove_failed outcome=not_synced \(fields(error))")

            case let .emptied(unlinkError):
                diagnostics.warning("recovered_cut_remove_failed outcome=emptied \(fields(unlinkError))")

            case let .failed(unlinkError, _):
                diagnostics.warning("recovered_cut_remove_failed outcome=failed \(fields(unlinkError))")
            }
        }

        func logFailedStore(_ outcome: PendingRecordingCut.WriteOutcome, value: String) {
            switch outcome {
            case .written:
                return

            case let .notPublished(error):
                diagnostics.warning("recovered_cut_store_failed value=\(value) outcome=not_published \(fields(error))")

            case let .publishedNotSynced(error):
                diagnostics.warning("recovered_cut_store_failed value=\(value) outcome=not_synced \(fields(error))")
            }
        }

        /// Domain and code only: a file error's description names the path.
        private func fields(_ error: any Error) -> String {
            let nsError = error as NSError
            return "domain=\(nsError.domain) code=\(nsError.code)"
        }

        private func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }
    }
}
