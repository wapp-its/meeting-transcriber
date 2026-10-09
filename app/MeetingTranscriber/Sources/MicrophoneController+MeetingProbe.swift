import Foundation

/// The meeting-app microphone probe: every fifth tick of a recording that taps
/// a meeting app and is capturing the microphone, read which input devices the
/// tapped processes use, judge it against the recorded microphone, log it,
/// show the menu hint while the latest probe is a mismatch, and notify once
/// after two mismatching probes. The reads are `MeetingMicrophoneProbe`'s, the decisions
/// `MeetingMicrophoneVerdict`'s and `MeetingMicrophoneWarningPolicy`'s; this
/// file only runs them in order.
///
/// **No Core Audio read on the main thread, and none waited for there** (issue
/// #588: coreaudiod can stop answering). The read runs on `probeQueue`, one at
/// a time; a probe due while one is still out is skipped and counted, so a
/// read that never returns costs skipped probes and nothing else. Its result
/// comes back by a main-actor hop and is dropped unless the recording it was
/// started for is still the attached one and still capturing its microphone.
extension MicrophoneController {
    /// The probe's state for the attached recording.
    struct MeetingProbeState {
        var policy = MeetingMicrophoneWarningPolicy()
        /// Ticks since the recording attached.
        var ticks = 0
        /// Bumped when a recording ends, so a read started before tells.
        var generation = 0
        /// A read is on `probeQueue` and has not come back. Survives the
        /// recording's end: the read is still out, whichever recording asked.
        var readInFlight = false
    }

    /// From `tick()`. The microphone track is the one the capture reports
    /// running, not the requested source: a microphone that failed to start
    /// leaves the source `.appAndMic`, and a given-up track must end the
    /// probing, and with it a hint about a microphone no longer recorded.
    func probeMeetingMicrophoneIfDue(_ recorder: (any RecordingProvider)?) {
        meetingProbe.ticks += 1
        let pids = recorder?.tappedPIDs ?? []
        guard recorder?.microphoneTrackActive == true, !pids.isEmpty else {
            if meetingAppHint != nil { meetingAppHint = nil }
            return
        }
        guard meetingProbe.ticks.isMultiple(of: meetingProbe.policy.limits.probeEveryTicks) else { return }
        guard !meetingProbe.readInFlight else {
            meetingProbe.policy.recordSkip()
            return
        }

        meetingProbe.readInFlight = true
        meetingProbe.policy.recordProbeStarted()
        let generation = meetingProbe.generation
        let read = probeReader
        probeQueue.async { [weak self] in
            let processes = read(pids)
            Task { @MainActor in
                self?.adoptMeetingProbe(processes, tappedCount: pids.count, generation: generation)
            }
        }
    }

    /// From `recordingStopped()`: the stop line when a probe came due, then a
    /// clean slate for the next recording.
    func endMeetingProbe() {
        if let stopLine = meetingProbe.policy.stopLine {
            log.notice(stopLine)
        }
        meetingProbe.policy.reset()
        meetingProbe.ticks = 0
        meetingProbe.generation += 1
        if meetingAppHint != nil { meetingAppHint = nil }
    }

    private func adoptMeetingProbe(_ processes: [MeetingInputProcess], tappedCount: Int, generation: Int) {
        meetingProbe.readInFlight = false
        // The track can have given up while the read was out: then there is
        // no recorded microphone left to compare with.
        guard generation == meetingProbe.generation, let attachment,
              attachment.recorderProvider()?.microphoneTrackActive == true
        else { return }

        let recordedUID = recordedDevice?.uid
        let verdict = MeetingMicrophoneVerdict.evaluate(processes: processes, recordedDeviceUID: recordedUID)
        let outcome = meetingProbe.policy.record(
            verdict: verdict, processes: processes, tappedCount: tappedCount, recordedDeviceUID: recordedUID,
        )
        for line in outcome.lines {
            switch line.level {
            case .notice: log.notice(line.text)
            case .warning: log.warning(line.text)
            }
        }
        if let debugLine = outcome.debugLine, settings.verboseDiagnostics {
            log.notice(debugLine)
        }

        let appName = attachment.meetingAppName ?? "the meeting app"
        if outcome.notify {
            let alert = MeetingMicrophoneWarningPolicy.notification(
                appName: appName, recordedName: recordedDevice?.name, devices: outcome.hintDevices,
            )
            notifier.notify(title: alert.title, body: alert.body, urgency: .timeSensitive)
        }
        let hint = outcome.hintDevices.isEmpty
            ? nil : MeetingMicrophoneWarningPolicy.hint(appName: appName, devices: outcome.hintDevices)
        if meetingAppHint != hint { meetingAppHint = hint }
    }
}
