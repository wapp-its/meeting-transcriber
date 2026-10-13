import CoreAudio
@testable import MeetingTranscriber
import XCTest

/// The probe's mapping from raw Core Audio reads to what it reports, through
/// fake reads (CI has no meeting app and no audio hardware to ask).
final class MeetingMicrophoneProbeTests: XCTestCase {
    /// pid 1 has no process object; pid 2's isRunningInput read fails; pid 3's
    /// device list fails; pid 4 runs input with two devices, the second of
    /// which fails every read.
    private static let reads = MeetingMicrophoneProbe.RawReads(
        processObject: { pid in pid == 1 ? nil : AudioObjectID(pid) * 10 },
        uint32: { object, selector, _ in
            switch (object, selector) {
            case (20, kAudioProcessPropertyIsRunningInput): .failed(560_947_818)
            case (_, kAudioProcessPropertyIsRunningInput): .value(1)
            case (400, kAudioDevicePropertyTransportType): .value(kAudioDeviceTransportTypeUSB)
            default: .failed(-50)
            }
        },
        objectIDs: { object, selector, scope in
            // Only the input scope of the device list is an answer here, so a
            // probe asking for the output side reads as a failure.
            guard selector == kAudioProcessPropertyDevices, scope == kAudioObjectPropertyScopeInput else { return .failed(-1) }
            return object == 30 ? .failed(2_003_332_927) : .value([400, 401])
        },
        string: { object, selector in
            switch (object, selector) {
            case (400, kAudioDevicePropertyDeviceUID): .value("DeskUSBMicUID")
            case (400, kAudioObjectPropertyName): .value("Desk USB Microphone")
            default: .failed(1_852_797_029)
            }
        },
    )

    func testEachFailedReadKeepsItsStatusAndAPidWithoutAProcessObjectIsSkipped() {
        let processes = MeetingMicrophoneProbe.read(pids: [1, 2, 3, 4], reads: Self.reads)

        let usbMic = MeetingInputDevice(
            objectID: 400, uid: .value("DeskUSBMicUID"), name: .value("Desk USB Microphone"),
            transport: .value(kAudioDeviceTransportTypeUSB),
        )
        let failing = MeetingInputDevice(objectID: 401, uid: .failed(1_852_797_029), name: .failed(1_852_797_029), transport: .failed(-50))
        XCTAssertEqual(processes.map(\.pid), [2, 3, 4])
        XCTAssertEqual(processes.map(\.isRunningInput), [.failed(560_947_818), .value(true), .value(true)])
        XCTAssertEqual(processes.map(\.inputDevices), [.value([usbMic, failing]), .failed(2_003_332_927), .value([usbMic, failing])])
    }
}
