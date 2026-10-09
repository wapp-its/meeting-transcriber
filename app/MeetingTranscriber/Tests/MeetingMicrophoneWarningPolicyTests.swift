import CoreAudio
@testable import MeetingTranscriber
import XCTest

/// When the meeting-app probe warns, what the menu hint shows, and what it
/// writes to the log: the limits, the wording, and what the lines must never
/// carry (a device name outside the `[debug]` line, a device UID anywhere).
final class MeetingMicrophoneWarningPolicyTests: XCTestCase {
    private typealias Policy = MeetingMicrophoneWarningPolicy

    // Distinctive UIDs and names, so the privacy test can look for them.
    private static let recordedUID = "AnnasAirPodsUID-7F3A"
    private static let recorded = MeetingInputDevice(
        objectID: 73, uid: .value(recordedUID), name: .value("Anna's AirPods Pro"),
        transport: .value(kAudioDeviceTransportTypeBluetooth),
    )
    private static let usbMic = MeetingInputDevice(
        objectID: 81, uid: .value("DeskUSBMicUID-91C2"), name: .value("Desk USB Microphone"),
        transport: .value(kAudioDeviceTransportTypeUSB),
    )
    private static let aggregate = MeetingInputDevice(
        objectID: 90, uid: .value("VPAggregateUID-55D0"), name: .value("Teams Voice Aggregate"),
        transport: .value(kAudioDeviceTransportTypeAggregate),
    )
    private static let uids = [recordedUID, "DeskUSBMicUID-91C2", "VPAggregateUID-55D0"]
    private static let names = ["Anna's AirPods Pro", "Desk USB Microphone", "Teams Voice Aggregate"]

    private static func teams(_ devices: [MeetingInputDevice]) -> MeetingInputProcess {
        MeetingInputProcess(pid: 4242, executableName: "MSTeams", isRunningInput: .value(true), inputDevices: .value(devices))
    }

    /// Runs no input and lists no device: left out of the process lines.
    private static let idleHelper = MeetingInputProcess(
        pid: 4243, executableName: "MSTeams Helper", isRunningInput: .value(false), inputDevices: .value([]),
    )

    private static let mismatch = MeetingMicrophoneVerdict.mismatch([usbMic])

    /// One probe whose processes are `processes`; the verdict defaults to the
    /// one those processes give.
    @discardableResult
    private func record(
        _ policy: inout Policy,
        _ verdict: MeetingMicrophoneVerdict,
        _ processes: [MeetingInputProcess] = [teams([usbMic]), idleHelper],
        tappedCount: Int = 3,
    ) -> Policy.Outcome {
        policy.record(verdict: verdict, processes: processes, tappedCount: tappedCount, recordedDeviceUID: Self.recordedUID)
    }

    // MARK: - Notification and hint

    func testTwoConsecutiveMismatchesNotifyExactlyOncePerRecording() {
        var policy = Policy()

        XCTAssertFalse(record(&policy, Self.mismatch).notify, "one mismatch")
        XCTAssertTrue(record(&policy, Self.mismatch).notify, "the second in a row")
        XCTAssertFalse(record(&policy, Self.mismatch).notify, "never a second time in the same recording")
        XCTAssertFalse(record(&policy, .match).notify)
        XCTAssertFalse(record(&policy, Self.mismatch).notify)
        XCTAssertFalse(record(&policy, Self.mismatch).notify, "nor after a new run of mismatches")

        policy.reset()
        XCTAssertFalse(record(&policy, Self.mismatch).notify, "the next recording")
        XCTAssertTrue(record(&policy, Self.mismatch).notify, "the next recording warns again")
    }

    func testAMatchOrAnUndeterminedVerdictInBetweenResetsTheCount() {
        for between in [MeetingMicrophoneVerdict.match, .undetermined(.unidentifiableDevice)] {
            var policy = Policy()
            record(&policy, Self.mismatch)
            record(&policy, between)
            XCTAssertFalse(record(&policy, Self.mismatch).notify, "\(between)")
            XCTAssertTrue(record(&policy, Self.mismatch).notify, "\(between)")
        }
    }

    func testTheHintShowsOnlyWhileTheLatestVerdictIsAMismatch() {
        var policy = Policy()

        XCTAssertEqual(record(&policy, Self.mismatch).hintDevices, [Self.usbMic])
        XCTAssertEqual(record(&policy, .match).hintDevices, [])
        XCTAssertEqual(record(&policy, Self.mismatch).hintDevices, [Self.usbMic])
        XCTAssertEqual(record(&policy, .undetermined(.noProcessCapturingInput)).hintDevices, [])
    }

    /// Names joined with a comma, an unreadable one as "an unnamed device", an
    /// unnamed recorded microphone as "an unnamed microphone".
    func testTheNotificationAndHintWording() {
        let unnamed = MeetingInputDevice(
            objectID: 96, uid: .value("X"), name: .failed(-1), transport: .value(kAudioDeviceTransportTypeUSB),
        )

        let alert = Policy.notification(appName: "Microsoft Teams", recordedName: "Anna's AirPods Pro", devices: [Self.usbMic])
        XCTAssertEqual(alert.title, "Microphone differs from Microsoft Teams")
        XCTAssertEqual(
            alert.body,
            "Recording from Anna's AirPods Pro, but Microsoft Teams uses Desk USB Microphone. "
                + "Choose the microphone in the menu bar under Microphone.",
        )
        XCTAssertEqual(
            Policy.notification(appName: "zoom.us", recordedName: nil, devices: [Self.usbMic, unnamed]).body,
            "Recording from an unnamed microphone, but zoom.us uses Desk USB Microphone, an unnamed device. "
                + "Choose the microphone in the menu bar under Microphone.",
        )
        XCTAssertEqual(
            Policy.hint(appName: "Microsoft Teams", devices: [Self.usbMic, unnamed]),
            "Microsoft Teams uses Desk USB Microphone, an unnamed device",
        )
    }

    // MARK: - Log entries

    func testTheFirstProbeLogsAnUnchangedProbeLogsNothingAndAChangeLogs() {
        var policy = Policy()

        let first = record(&policy, Self.mismatch)
        XCTAssertEqual(first.lines, [
            Policy.Line(level: .notice, text: "Meeting app microphone (first): exe=MSTeams pid=4242 isRunningInput=true inputDevices=[81/USB/other]"),
            Policy.Line(level: .warning, text: "Meeting app microphone verdict (first): mismatch processesWithAudioObject=2/3 capturingInput=1"),
        ])
        XCTAssertEqual(first.debugLine, "[debug] Meeting app microphone devices: 81 name=Desk USB Microphone transport=USB")

        let unchanged = record(&policy, Self.mismatch)
        XCTAssertEqual(unchanged.lines, [])
        XCTAssertNil(unchanged.debugLine)

        let change = record(&policy, .match, [Self.teams([Self.aggregate, Self.recorded]), Self.idleHelper])
        XCTAssertEqual(change.lines, [
            Policy.Line(
                level: .notice,
                text: "Meeting app microphone (change): exe=MSTeams pid=4242 isRunningInput=true "
                    + "inputDevices=[90/Aggregate/other, 73/Bluetooth/recorded]",
            ),
            Policy.Line(level: .notice, text: "Meeting app microphone verdict (change): match processesWithAudioObject=2/3 capturingInput=1"),
        ])
        XCTAssertEqual(
            change.debugLine,
            "[debug] Meeting app microphone devices: 90 name=Teams Voice Aggregate transport=Aggregate; "
                + "73 name=Anna's AirPods Pro transport=Bluetooth",
        )
    }

    /// A failed read is `?(<status>)` wherever the value would be, and a device
    /// whose UID cannot be read is neither "recorded" nor "other".
    func testAFailedReadIsShownAsItsStatus() {
        var policy = Policy()
        let failing = MeetingInputDevice(objectID: 95, uid: .failed(1_852_797_029), name: .failed(2_003_332_927), transport: .failed(-50))
        let processes = [
            MeetingInputProcess(
                pid: 4242, executableName: "MSTeams",
                isRunningInput: .failed(560_947_818), inputDevices: .value([Self.recorded, failing]),
            ),
            MeetingInputProcess(pid: 4243, executableName: "zoom.us", isRunningInput: .value(true), inputDevices: .failed(2_003_332_927)),
        ]

        let outcome = record(&policy, .undetermined(.unreadableProperty), processes, tappedCount: 2)

        XCTAssertEqual(outcome.lines.map(\.text), [
            "Meeting app microphone (first): exe=MSTeams pid=4242 isRunningInput=?(560947818) "
                + "inputDevices=[73/Bluetooth/recorded, 95/?(-50)/?]",
            "Meeting app microphone (first): exe=zoom.us pid=4243 isRunningInput=true inputDevices=?(2003332927)",
            "Meeting app microphone verdict (first): undetermined(unreadableProperty) processesWithAudioObject=2/2 capturingInput=1",
        ])
        XCTAssertEqual(
            outcome.debugLine,
            "[debug] Meeting app microphone devices: 73 name=Anna's AirPods Pro transport=Bluetooth; "
                + "95 name=?(2003332927) transport=?(-50)",
        )
    }

    func testTransportsWithoutAPhysicalKindAreNamedOrGivenAsTheirCode() {
        let labels: [(UInt32, String)] = [
            (kAudioDeviceTransportTypeAggregate, "Aggregate"),
            (kAudioDeviceTransportTypeVirtual, "Virtual"),
            (kAudioDeviceTransportTypeUnknown, "Unknown"),
            (0x6667_7270, "fgrp"), // auto-aggregate, declared only in the deprecated header
        ]
        for (transport, label) in labels {
            XCTAssertEqual(MeetingMicrophoneVerdict.transportLabel(transport), label)
        }
    }

    /// Change entries after the first stop at 20 per recording, with one line
    /// saying so.
    func testThe21stChangeLogsOneCapLineAndThenNothing() {
        var policy = Policy()
        let entries: [(MeetingMicrophoneVerdict, [MeetingInputProcess])] = [
            (Self.mismatch, [Self.teams([Self.usbMic])]),
            (.match, [Self.teams([Self.recorded])]),
        ]
        XCTAssertEqual(record(&policy, entries[0].0, entries[0].1).lines.count, 2, "first")

        for change in 1 ... 20 {
            let (verdict, processes) = entries[change % 2]
            XCTAssertEqual(record(&policy, verdict, processes).lines.count, 2, "change \(change)")
        }
        let (verdict21, processes21) = entries[21 % 2]
        XCTAssertEqual(record(&policy, verdict21, processes21).lines, [
            Policy.Line(level: .notice, text: "Meeting app microphone: 20 changes logged in this recording, further changes not logged"),
        ])
        let (verdict22, processes22) = entries[22 % 2]
        XCTAssertEqual(record(&policy, verdict22, processes22), Policy.Outcome(lines: [], hintDevices: [Self.usbMic]))
    }

    func testTheStopLineCarriesLastVerdictProbesSkippedProbesAndWarned() {
        var policy = Policy()
        XCTAssertNil(policy.stopLine, "nothing was due")

        policy.recordSkip()
        XCTAssertEqual(policy.stopLine, "Meeting app microphone at stop: lastVerdict=none probes=0 skippedProbes=1 warned=false")

        record(&policy, Self.mismatch)
        record(&policy, Self.mismatch)
        XCTAssertEqual(policy.stopLine, "Meeting app microphone at stop: lastVerdict=mismatch probes=2 skippedProbes=1 warned=true")
        record(&policy, .undetermined(.recordedMicrophoneUnknown))
        XCTAssertEqual(
            policy.stopLine,
            "Meeting app microphone at stop: lastVerdict=undetermined(recordedMicrophoneUnknown) probes=3 skippedProbes=1 warned=true",
        )

        policy.reset()
        XCTAssertNil(policy.stopLine, "a new recording")
    }

    /// The unconditional lines reach the persisted, "redacted" diagnostics
    /// file: no device name there, and no device UID in any line.
    func testNoLineCarriesAUIDAndOnlyTheDebugLineNamesDevices() {
        var policy = Policy()
        var unconditional: [String] = []
        var debug: [String] = []
        let probes: [(MeetingMicrophoneVerdict, [MeetingInputProcess])] = [
            (Self.mismatch, [Self.teams([Self.usbMic])]),
            (.match, [Self.teams([Self.aggregate, Self.recorded]), Self.idleHelper]),
            (.undetermined(.unidentifiableDevice), [Self.teams([Self.aggregate])]),
        ]
        for (verdict, processes) in probes {
            let outcome = record(&policy, verdict, processes)
            unconditional += outcome.lines.map(\.text)
            debug += outcome.debugLine.map { [$0] } ?? []
        }
        policy.recordSkip()
        if let stopLine = policy.stopLine {
            unconditional.append(stopLine)
        }
        XCTAssertEqual(unconditional.count, 7, "precondition: three entries and the stop line")
        XCTAssertEqual(debug.count, 3, "precondition")

        for line in unconditional + debug {
            for uid in Self.uids {
                XCTAssertFalse(line.contains(uid), "UID in: \(line)")
            }
        }
        for line in unconditional {
            for name in Self.names {
                XCTAssertFalse(line.contains(name), "device name in an unconditional line: \(line)")
            }
        }
    }
}
