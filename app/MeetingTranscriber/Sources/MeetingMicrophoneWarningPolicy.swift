import CoreAudio
import Foundation

/// What the meeting-app probe does with each verdict: when to post
/// the one mismatch notification, which devices the menu hint names, and which
/// lines go to the log. Pure, so every limit is tested without Core Audio;
/// `MicrophoneController+MeetingProbe.swift` feeds it one probe at a time and
/// acts on what it returns. One value per recording: `reset()` between them.
///
/// **Privacy.** The lines are written unconditionally through
/// `DiagnosticsLogging`, which logs `.public` and reaches the persisted
/// diagnostics file Settings offers as a redacted log. So `lines` and
/// `stopLine` carry executable names, process ids, Core Audio object ids,
/// transport kinds, booleans and status codes only: never a device name
/// (a Bluetooth device's name usually carries a person's name) and never a
/// device UID (stable across boots; a USB one carries the serial). Names appear
/// only in `debugLine`, which the caller writes only with Verbose Audio Logging
/// on, as the capture library does with its `[debug] Mic input device:` line.
/// No line carries a UID.
struct MeetingMicrophoneWarningPolicy {
    struct Limits: Equatable, Sendable {
        /// The probe runs on every this-many-th once-a-second tick.
        var probeEveryTicks = 5
        /// Consecutive mismatching probes before the notification. Two, so one
        /// probe taken while a microphone switch is still restarting the
        /// capture (the old device is reported until adoption) never warns.
        var mismatchesBeforeWarning = 2
        /// Change entries per recording after the first entry; one more line
        /// says the rest are not logged.
        var maxChangeLogEntries = 20

        static let production = Self()
    }

    struct Line: Equatable {
        enum Level: Equatable {
            case notice
            case warning
        }

        let level: Level
        let text: String
    }

    /// What one probe asks of the caller.
    struct Outcome: Equatable {
        /// Empty for a probe that changed nothing in what the log shows.
        var lines: [Line] = []
        /// The `[debug]` line naming the devices, beside a first or change
        /// entry that lists any; written only with Verbose Audio Logging on.
        var debugLine: String?
        /// Post the mismatch notification now.
        var notify = false
        /// The devices the menu hint names, empty unless this probe's verdict
        /// is a mismatch (which always names at least one).
        var hintDevices: [MeetingInputDevice] = []
    }

    let limits: Limits
    private var lastVerdict: MeetingMicrophoneVerdict?
    /// Reads started, whether or not their result came back: a read still out
    /// at stop is the one the summary most needs to show.
    private var probes = 0
    /// Probes that came due while an earlier read was still outstanding.
    private var skippedProbes = 0
    private var warned = false
    private var consecutiveMismatches = 0
    private var changeEntries = 0
    /// What the last first or change entry showed, without its tag; empty
    /// before the first, since every entry has its verdict line.
    private var lastEntry: [String] = []

    init(limits: Limits = .production) {
        self.limits = limits
    }

    /// The summary for the recording's end, nil when no probe ever came due.
    var stopLine: String? {
        guard probes + skippedProbes > 0 else { return nil }
        return "Meeting app microphone at stop: lastVerdict=\(lastVerdict?.logLabel ?? "none") "
            + "probes=\(probes) skippedProbes=\(skippedProbes) warned=\(warned)"
    }

    /// A read was started.
    mutating func recordProbeStarted() {
        probes += 1
    }

    /// One probe's result. `processes` are the tapped processes that have an
    /// audio object, `tappedCount` all of them.
    mutating func record(
        verdict: MeetingMicrophoneVerdict,
        processes: [MeetingInputProcess],
        tappedCount: Int,
        recordedDeviceUID: String?,
    ) -> Outcome {
        lastVerdict = verdict
        var outcome = Outcome()
        if case let .mismatch(devices) = verdict {
            consecutiveMismatches += 1
            outcome.hintDevices = devices
            if consecutiveMismatches >= limits.mismatchesBeforeWarning, !warned {
                warned = true
                outcome.notify = true
            }
        } else {
            consecutiveMismatches = 0
        }

        let logged = processes.filter { $0.isRunningInput != .value(false) || $0.inputDevices != .value([]) }
        let processTexts = logged.map { Self.processText($0, recordedDeviceUID: recordedDeviceUID) }
        let capturing = processes.count { $0.isRunningInput == .value(true) }
        let verdictText = "\(verdict.logLabel) processesWithAudioObject=\(processes.count)/\(tappedCount) capturingInput=\(capturing)"
        let entry = processTexts + [verdictText]
        guard entry != lastEntry else { return outcome }

        let tag: String
        if lastEntry.isEmpty {
            tag = "first"
        } else if changeEntries < limits.maxChangeLogEntries {
            changeEntries += 1
            tag = "change"
        } else {
            if changeEntries == limits.maxChangeLogEntries {
                changeEntries += 1
                outcome.lines = [Line(
                    level: .notice,
                    text: "Meeting app microphone: \(limits.maxChangeLogEntries) changes logged in this recording, "
                        + "further changes not logged",
                )]
            }
            return outcome
        }
        lastEntry = entry
        outcome.lines = processTexts.map { Line(level: .notice, text: "Meeting app microphone (\(tag)): \($0)") }
        let verdictLevel: Line.Level = if case .mismatch = verdict { .warning } else { .notice }
        outcome.lines.append(Line(level: verdictLevel, text: "Meeting app microphone verdict (\(tag)): \(verdictText)"))
        outcome.debugLine = Self.debugLine(logged)
        return outcome
    }

    /// A probe that came due while the previous read was still outstanding.
    mutating func recordSkip() {
        skippedProbes += 1
    }

    /// Forget the recording that ended.
    mutating func reset() {
        self = Self(limits: limits)
    }

    // MARK: - Notification and hint

    static func notification(
        appName: String,
        recordedName: String?,
        devices: [MeetingInputDevice],
    ) -> (title: String, body: String) {
        let body = "Recording from \(recordedName ?? "an unnamed microphone"), but \(appName) uses \(deviceNames(devices)). "
            + "Choose the microphone in the menu bar under Microphone."
        return ("Microphone differs from \(appName)", body)
    }

    /// The disabled line under the menu's Microphone items.
    static func hint(appName: String, devices: [MeetingInputDevice]) -> String {
        "\(appName) uses \(deviceNames(devices))"
    }

    private static func deviceNames(_ devices: [MeetingInputDevice]) -> String {
        devices.map { device in
            if case let .value(name) = device.name { name } else { "an unnamed device" }
        }
        .joined(separator: ", ")
    }

    // MARK: - Log lines

    /// `exe=… pid=… isRunningInput=… inputDevices=[<objectID>/<transport>/<recorded|other|?>, …]`.
    /// A device whose UID could not be read is `?(<status>)`; with the recorded
    /// microphone's UID unknown it is `?`.
    private static func processText(_ process: MeetingInputProcess, recordedDeviceUID: String?) -> String {
        let devices = process.inputDevices.rendered { devices in
            let entries = devices.map { device in
                let role = switch (device.uid, recordedDeviceUID) {
                case let (.failed(status), _): "?(\(status))"
                case let (.value(uid), recorded?): uid == recorded ? "recorded" : "other"
                case (.value, nil): "?"
                }
                return "\(device.objectID)/\(transportText(device.transport))/\(role)"
            }
            return "[\(entries.joined(separator: ", "))]"
        }
        return "exe=\(process.executableName) pid=\(process.pid) "
            + "isRunningInput=\(process.isRunningInput.rendered { String($0) }) inputDevices=\(devices)"
    }

    /// The only line with device names; nil when no logged process lists one.
    private static func debugLine(_ processes: [MeetingInputProcess]) -> String? {
        var seen = Set<AudioObjectID>()
        let devices = processes
            .flatMap { process -> [MeetingInputDevice] in
                if case let .value(devices) = process.inputDevices { devices } else { [] }
            }
            .filter { seen.insert($0.objectID).inserted }
        guard !devices.isEmpty else { return nil }
        let entries = devices.map { device in
            "\(device.objectID) name=\(device.name.rendered { $0 }) transport=\(transportText(device.transport))"
        }
        return "[debug] Meeting app microphone devices: \(entries.joined(separator: "; "))"
    }

    private static func transportText(_ transport: MeetingMicrophoneProbe.Reading<UInt32>) -> String {
        transport.rendered(MeetingMicrophoneVerdict.transportLabel)
    }
}

private extension MeetingMicrophoneProbe.Reading {
    /// The value as `format` writes it, or `?(<status>)` for a failed read.
    func rendered(_ format: (Value) -> String) -> String {
        switch self {
        case let .value(value): format(value)
        case let .failed(status): "?(\(status))"
        }
    }
}

private extension MeetingMicrophoneVerdict {
    var logLabel: String {
        switch self {
        case .match: "match"
        case .mismatch: "mismatch"
        case let .undetermined(reason): "undetermined(\(reason.rawValue))"
        }
    }
}
