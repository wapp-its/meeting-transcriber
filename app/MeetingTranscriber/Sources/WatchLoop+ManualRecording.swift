import Foundation

/// The poll loop that decides when a manually started recording ends, split out
/// of `WatchLoop.swift` to keep that file under the line cap.
///
/// Only the monitor moved. The start and stop paths mutate `activeRecorder`,
/// `manualRecordingTask` and `watchTask`, all of which are private to the class
/// on purpose, and moving them here would mean widening those to internal for a
/// line count. The monitor reads nothing but injected dependencies.
extension WatchLoop {
    func monitorManualRecording(pid: pid_t?) async {
        let startTime = nowProvider()
        var capWarned = false
        while !Task.isCancelled {
            // No PID means a microphone-only recording, which has no process
            // that could exit; the duration cap below is its only stop signal.
            let target: ManualRecordingTarget = pid.map { pidAliveCheck($0) ? .alive : .exited } ?? .untargeted
            let elapsed = nowProvider().timeIntervalSince(startTime)
            let decision = ManualRecordingMonitorPolicy.step(target: target, elapsed: elapsed, maxDuration: maxDuration)
            let info = manualRecordingInfo
            switch decision {
            case .continuePolling:
                break

            case .stopPidExited:
                diagnostics.notice(AutoStopReason.appExited.logLine(trigger: .manual, pid: pid))
                stopManualRecording()
                if let info { postStopNotice(RecordingStopNotices.appQuit(recordingTitle: info.title, appName: info.appName)) }
                return

            case .stopMaxDurationExceeded:
                diagnostics.notice(AutoStopReason.maxDuration.logLine(trigger: .manual))
                stopManualRecording()
                if let info { postStopNotice(RecordingStopNotices.capReached(recordingTitle: info.title, maxDuration: maxDuration)) }
                return
            }
            if let stop = stepSilencePrompt(held: false, trigger: .manual) {
                diagnostics.notice(AutoStopReason.silenceStop.logLine(trigger: .manual, silentFor: stop.silentFor))
                stopManualRecording(cutAt: stop.cutAt)
                return
            }
            if let info {
                warnBeforeMaximumIfDue(elapsed: elapsed, recordingTitle: info.title, trigger: .manual, warned: &capWarned)
            }
            try? await sleepProvider(pollInterval)
        }
    }
}
