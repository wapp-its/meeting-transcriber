import CoreAudio
@testable import MeetingTranscriber
import XCTest

/// Whether the meeting app records from the recorded microphone, decided from
/// what the probe read. Every undetermined reason is an arm the warning must
/// stay quiet on.
final class MeetingMicrophoneVerdictTests: XCTestCase {
    private static let recordedUID = "RecordedHeadsetUID"

    private static func device(
        _ objectID: AudioObjectID,
        uid: MeetingMicrophoneProbe.Reading<String>,
        transport: MeetingMicrophoneProbe.Reading<UInt32> = .value(kAudioDeviceTransportTypeUSB),
    ) -> MeetingInputDevice {
        MeetingInputDevice(objectID: objectID, uid: uid, name: .value("Device \(objectID)"), transport: transport)
    }

    private static func process(
        _ devices: MeetingMicrophoneProbe.Reading<[MeetingInputDevice]>,
        pid: pid_t = 4242,
        running: MeetingMicrophoneProbe.Reading<Bool> = .value(true),
    ) -> MeetingInputProcess {
        MeetingInputProcess(pid: pid, executableName: "MSTeams", isRunningInput: running, inputDevices: devices)
    }

    private static let recorded = device(73, uid: .value(recordedUID), transport: .value(kAudioDeviceTransportTypeBluetooth))
    private static let usbMic = device(81, uid: .value("DeskUSBMicUID"))
    private static let aggregate = device(90, uid: .value("VPAggregateUID"), transport: .value(kAudioDeviceTransportTypeAggregate))

    private func evaluate(_ processes: [MeetingInputProcess], recordedUID: String? = recordedUID) -> MeetingMicrophoneVerdict {
        .evaluate(processes: processes, recordedDeviceUID: recordedUID)
    }

    /// The recorded microphone among the devices is enough, whatever else the
    /// process uses beside it.
    func testMatchWhenAProcessCapturingInputUsesTheRecordedMicrophoneEvenBesideAnAggregate() {
        XCTAssertEqual(evaluate([Self.process(.value([Self.aggregate, Self.recorded]))]), .match)
    }

    /// Each device once, in the order the processes listed them: a helper
    /// process listing the same microphone does not repeat it in the message.
    func testMismatchWhenEveryDeviceIsPhysicalAndNoneIsRecorded() {
        let headset = Self.device(82, uid: .value("OtherHeadsetUID"), transport: .value(kAudioDeviceTransportTypeBluetoothLE))
        let processes = [
            Self.process(.value([Self.usbMic]), pid: 4242),
            Self.process(.value([headset, Self.usbMic]), pid: 4243),
            // Not running input: its device does not count, recorded or not.
            Self.process(.value([Self.recorded]), pid: 4244, running: .value(false)),
        ]

        XCTAssertEqual(evaluate(processes), .mismatch([Self.usbMic, headset]))
    }

    func testNoProcessCapturingInput() {
        let cases: [(String, [MeetingInputProcess])] = [
            ("no process with an audio object", []),
            ("input not running anywhere", [
                Self.process(.value([]), pid: 4242, running: .value(false)),
                Self.process(.value([Self.usbMic]), pid: 4243, running: .value(false)),
            ]),
        ]
        for (name, processes) in cases {
            XCTAssertEqual(evaluate(processes), .undetermined(.noProcessCapturingInput), name)
        }
    }

    /// The allow-list in the negative: anything that is not a physical kind,
    /// including kinds the app has no name for, hides the microphone behind it.
    /// Auto-aggregate is spelled as its four-char code because Core Audio
    /// declares the constant only in its deprecated header.
    func testUnidentifiableDevice() {
        let autoAggregate: UInt32 = 0x6667_7270 // 'fgrp'
        let remoteScreen: UInt32 = 0x7273_6372 // 'rscr'
        let transports: [(String, UInt32)] = [
            ("aggregate", kAudioDeviceTransportTypeAggregate),
            ("auto-aggregate", autoAggregate),
            ("virtual", kAudioDeviceTransportTypeVirtual),
            ("unknown", kAudioDeviceTransportTypeUnknown),
            ("unlisted", remoteScreen),
        ]
        for (name, transport) in transports {
            let device = Self.device(91, uid: .value("SomeUID"), transport: .value(transport))
            XCTAssertEqual(
                evaluate([Self.process(.value([Self.usbMic, device]))]),
                .undetermined(.unidentifiableDevice), name,
            )
        }
        XCTAssertEqual(
            evaluate([Self.process(.value([Self.usbMic]), pid: 4242), Self.process(.value([]), pid: 4243)]),
            .undetermined(.unidentifiableDevice), "a process capturing input lists no device",
        )
    }

    func testUnreadableProperty() {
        let cases: [(String, [MeetingInputProcess])] = [
            ("isRunningInput", [
                Self.process(.value([Self.usbMic]), pid: 4242),
                Self.process(.value([]), pid: 4243, running: .failed(560_947_818)),
            ]),
            ("device list", [Self.process(.failed(2_003_332_927))]),
            ("UID", [Self.process(.value([Self.usbMic, Self.device(92, uid: .failed(1_852_797_029))]))]),
            ("transport", [Self.process(.value([Self.device(93, uid: .value("X"), transport: .failed(-50))]))]),
        ]
        for (name, processes) in cases {
            XCTAssertEqual(evaluate(processes), .undetermined(.unreadableProperty), name)
        }
    }

    /// Everything on the meeting app's side is identifiable, but there is
    /// nothing to compare it with.
    func testRecordedMicrophoneUnknown() {
        XCTAssertEqual(
            evaluate([Self.process(.value([Self.usbMic]))], recordedUID: nil),
            .undetermined(.recordedMicrophoneUnknown),
        )
    }

    /// The allow-list in the positive: each physical kind can be named as the
    /// meeting app's microphone.
    func testEveryPhysicalTransportIsIdentifiable() {
        let physical: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeAVB, kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
        ]
        for transport in physical {
            let device = Self.device(94, uid: .value("PhysicalUID"), transport: .value(transport))
            XCTAssertEqual(
                evaluate([Self.process(.value([device]))]), .mismatch([device]),
                MeetingMicrophoneVerdict.transportLabel(transport),
            )
        }
    }
}
