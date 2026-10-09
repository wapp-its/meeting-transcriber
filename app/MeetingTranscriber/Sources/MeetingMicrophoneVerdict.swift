import CoreAudio
import Foundation

/// Whether the meeting app records from the microphone this recording
/// captures, as far as Core Audio lets the app tell. Pure: the
/// probe reads, this decides, `MeetingMicrophoneWarningPolicy` acts.
///
/// Only the tapped processes that read as running input count. The app can
/// tell only when every input device of those processes is identifiable: its
/// UID and transport type are readable and the transport is a physical kind.
/// An aggregate (a voice-processing aggregate, the default-device aggregate),
/// a virtual device (a meeting app's own) or an unknown kind hides the physical
/// microphone behind it, so the verdict is then undetermined and nothing warns.
enum MeetingMicrophoneVerdict: Equatable, Sendable {
    /// Why the probe could not tell.
    enum Reason: String, Equatable, Sendable {
        case noProcessCapturingInput
        case unidentifiableDevice
        case unreadableProperty
        case recordedMicrophoneUnknown
    }

    /// A process capturing input uses the recorded microphone.
    case match
    /// The devices the meeting app uses, none of them the recorded microphone,
    /// each once, in the order the processes listed them.
    case mismatch([MeetingInputDevice])
    case undetermined(Reason)

    /// Precedence, when several reasons apply: a match wins over everything,
    /// then an unreadable property, no process capturing input, an
    /// unidentifiable device, and last an unknown recorded microphone, which is
    /// reported only when the meeting app's side could be told.
    static func evaluate(processes: [MeetingInputProcess], recordedDeviceUID: String?) -> Self {
        let capturing = processes.filter { $0.isRunningInput == .value(true) }
        var devices: [MeetingInputDevice] = []
        var listUnreadable = false
        var listsNoDevice = false
        for process in capturing {
            switch process.inputDevices {
            case let .value(list):
                devices += list
                listsNoDevice = listsNoDevice || list.isEmpty

            case .failed:
                listUnreadable = true
            }
        }

        if let recordedDeviceUID, devices.contains(where: { $0.uid == .value(recordedDeviceUID) }) {
            return .match
        }
        let unreadable = listUnreadable
            || processes.contains(where: \.isRunningInput.isFailed)
            || devices.contains { $0.uid.isFailed || $0.transport.isFailed }
        if unreadable { return .undetermined(.unreadableProperty) }
        if capturing.isEmpty { return .undetermined(.noProcessCapturingInput) }
        // A process capturing input that lists no device uses one the app cannot see.
        let identifiable = !listsNoDevice && devices.allSatisfy { device in
            if case let .value(transport) = device.transport { isPhysical(transport: transport) } else { false }
        }
        if !identifiable { return .undetermined(.unidentifiableDevice) }
        guard recordedDeviceUID != nil else { return .undetermined(.recordedMicrophoneUnknown) }

        var seen = Set<AudioObjectID>()
        return .mismatch(devices.filter { seen.insert($0.objectID).inserted })
    }

    /// Whether a transport type is a physical kind. An allow-list rather than a
    /// list of the excluded kinds: the auto-aggregate kind is declared only in
    /// Core Audio's deprecated header, which the warnings-as-errors build cannot
    /// name, and a kind added later stays unidentifiable instead of passing.
    private static func isPhysical(transport: UInt32) -> Bool {
        physicalTransports[transport] != nil
    }

    /// The transport type as the log lines show it: a name for the kinds the
    /// app knows, the four-char code for any other (`fgrp` for auto-aggregate).
    static func transportLabel(_ transport: UInt32) -> String {
        if let name = physicalTransports[transport] ?? otherTransports[transport] { return name }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: transport >> $0) }
        guard bytes.allSatisfy({ (0x20 ... 0x7E).contains($0) }) else { return String(transport) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(transport)
    }

    private static let physicalTransports: [UInt32: String] = [
        kAudioDeviceTransportTypeBuiltIn: "Built-In",
        kAudioDeviceTransportTypeUSB: "USB",
        kAudioDeviceTransportTypeBluetooth: "Bluetooth",
        kAudioDeviceTransportTypeBluetoothLE: "Bluetooth-LE",
        kAudioDeviceTransportTypePCI: "PCI",
        kAudioDeviceTransportTypeFireWire: "FireWire",
        kAudioDeviceTransportTypeHDMI: "HDMI",
        kAudioDeviceTransportTypeDisplayPort: "DisplayPort",
        kAudioDeviceTransportTypeAirPlay: "AirPlay",
        kAudioDeviceTransportTypeAVB: "AVB",
        kAudioDeviceTransportTypeThunderbolt: "Thunderbolt",
        kAudioDeviceTransportTypeContinuityCaptureWired: "ContinuityCapture-Wired",
        kAudioDeviceTransportTypeContinuityCaptureWireless: "ContinuityCapture-Wireless",
    ]

    private static let otherTransports: [UInt32: String] = [
        kAudioDeviceTransportTypeAggregate: "Aggregate",
        kAudioDeviceTransportTypeVirtual: "Virtual",
        kAudioDeviceTransportTypeUnknown: "Unknown",
    ]
}
