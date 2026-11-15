import Foundation

/// What the Audio Devices window shows: its groups and their rows, every mark
/// on a row, which rows show a level bar and how many of its segments are lit,
/// the hint lines and the footer.
///
/// Decided here rather than in `AudioDevicesView` for the reason
/// `MicrophoneMenuState` gives: every arm is tested without the window, and
/// every string the window shows is here, so a wording change happens in one
/// place. Built from values the app already holds and the window reader's last
/// results (`AudioDevicesWindowReader`), so building it reads no hardware and
/// `/state` can build it on the main actor.
struct AudioDevicesWindowState: Equatable {
    /// Which list a row is in. The raw value is `/state`'s `group`.
    enum Group: String {
        case microphone
        case output
        case meetingAudio
    }

    /// One mark on a row, declared in the order a row shows its marks. The
    /// raw value is what `/state` reports.
    enum Mark: String, CaseIterable {
        /// This app records it: the recorded microphone while its track runs,
        /// and the Meeting audio row.
        case recording
        /// The recording is paused; on the Meeting audio row, after Recording.
        case paused
        /// The tapped meeting app uses it, during a recording that taps one.
        case meetingApp
        /// Core Audio reports the device running for some process, this app
        /// included.
        case inUse
        /// A reading this row depends on failed or is late: "could not ask",
        /// never "not running".
        case unknown
        /// The Mac's default input or default output.
        case systemDefault = "default"
        /// The configured microphone, which is not connected.
        case notConnected
        /// The Mac's default output is the Teams device, which keeps the
        /// meeting's audio out of the recording (`OutputRoutingWarning`).
        case routingWarning
    }

    struct Row: Equatable {
        let group: Group
        /// What the row is called: the device's name, never its UID.
        let name: String
        let marks: [Mark]
        /// The meeting app's name while `marks` holds `.meetingApp`, nil otherwise.
        let meetingApp: String?
        /// How many of the level bar's segments are lit; nil for a row without
        /// a bar.
        let litSegments: Int?
    }

    /// A heading, its list and the grey line under the list.
    struct Section: Equatable {
        let title: String
        /// Empty for a group with no device, which shows `noneFound`.
        let rows: [Row]
        let hint: String?
    }

    /// The running recording, as far as the window shows it.
    struct Recording: Equatable {
        /// Whether it taps an app, and so has a Meeting audio row.
        let capturesApp: Bool
        /// The recorded app's name (`MicrophoneController.Attachment.meetingAppName`).
        let appName: String?
        /// The microphone the recording reports it captures, while its
        /// microphone track is active; nil otherwise.
        let recordedMicrophoneUID: String?
        let paused: Bool
        /// The two tracks' levels as lit segments (`litSegments(dBFS:)`).
        let micLitSegments: Int
        let appLitSegments: Int
    }

    /// Everything the window is decided from.
    struct Inputs {
        /// `MicrophoneController.devices`, the Microphone entry's list, in its order.
        let microphones: [MicrophoneDevice]
        let defaultInputUID: String?
        /// `AppSettings.micDeviceUID`, empty for System Default.
        let configuredMicrophoneUID: String
        /// `OutputDeviceController.devices` and `current`.
        let outputs: [OutputDevice]
        let defaultOutput: OutputDevice?
        /// `MicrophoneController.meetingAppHint`, the Microphone entry's hint.
        let meetingAppHint: String?
        /// Nil while no recording runs.
        let recording: Recording?
        let status: AudioDeviceStatus
    }

    static let windowTitle = "Audio Devices"
    static let noneFound = "None found"
    static let noLevel = "no level"
    static let segmentCount = 12
    static let recordingFooter =
        "Levels show for what this recording captures. To switch a device, use Microphone or Output in the menu bar."
    static let idleFooter =
        "Levels show while a recording runs. To switch a device, use Microphone or Output in the menu bar."

    let microphones: Section
    let outputs: Section
    /// Present while the recording taps an app.
    let meetingAudio: Section?
    /// Whether rows have a level column, which only a running recording gives them.
    let showsLevelColumn: Bool
    let footer: String

    /// Every row, top to bottom.
    var rows: [Row] {
        microphones.rows + outputs.rows + (meetingAudio?.rows ?? [])
    }

    init(_ inputs: Inputs) {
        let recording = inputs.recording
        microphones = Section(title: "Microphones", rows: Self.microphoneRows(inputs), hint: inputs.meetingAppHint)
        let outputMenu = OutputMenuState.resolve(devices: inputs.outputs, current: inputs.defaultOutput)
        outputs = Section(title: "Outputs", rows: Self.outputRows(outputMenu, inputs), hint: outputMenu.hint)
        meetingAudio = recording.flatMap { recording in
            recording.capturesApp
                ? Section(title: "Meeting audio", rows: [Self.meetingAudioRow(recording)], hint: nil)
                : nil
        }
        showsLevelColumn = recording != nil
        footer = recording == nil ? Self.idleFooter : Self.recordingFooter
    }

    /// One segment per 5 dB above -60 dBFS, the channel-health silence
    /// threshold: -60 or less lights none, and so does the -120 a track
    /// reports once it stops delivering; 0 dBFS lights all twelve. Nil, a
    /// level not read yet, lights none.
    static func litSegments(dBFS: Double?) -> Int {
        guard let dBFS, dBFS > -60 else { return 0 }
        return min(segmentCount, Int(((dBFS + 60) / 5).rounded(.down)))
    }

    // MARK: - Rows

    /// The Microphone entry's devices, in its order, then a configured
    /// microphone that is not connected, as the entry lists it.
    private static func microphoneRows(_ inputs: Inputs) -> [Row] {
        let recording = inputs.recording
        var rows = inputs.microphones.map { device in
            let recorded = recording?.recordedMicrophoneUID == device.uid
            var marks: Set<Mark> = recorded ? [.recording] : []
            marks.formUnion(statusMarks(uid: device.uid, side: .input, inputs: inputs))
            if device.uid == inputs.defaultInputUID { marks.insert(.systemDefault) }
            return Row(
                group: .microphone, name: displayName(device.name, uid: device.uid), marks: ordered(marks),
                meetingApp: meetingAppName(marks, recording),
                litSegments: recorded ? recording.map { $0.paused ? 0 : $0.micLitSegments } : nil,
            )
        }
        let configured = inputs.configuredMicrophoneUID
        if !configured.isEmpty, !inputs.microphones.contains(where: { $0.uid == configured }) {
            rows.append(Row(group: .microphone, name: "Selected microphone", marks: [.notConnected], meetingApp: nil, litSegments: nil))
        }
        return rows
    }

    /// The Output entry's items: the outputs the Mac offers, then a default
    /// output it does not offer (the Teams device), as the entry lists them.
    private static func outputRows(_ menu: OutputMenuState, _ inputs: Inputs) -> [Row] {
        menu.items.map { item in
            var marks = statusMarks(uid: item.uid, side: .output, inputs: inputs)
            if item.uid == inputs.defaultOutput?.uid {
                marks.insert(.systemDefault)
                if menu.warning { marks.insert(.routingWarning) }
            }
            return Row(
                group: .output, name: displayName(item.label, uid: item.uid), marks: ordered(marks),
                meetingApp: meetingAppName(marks, inputs.recording), litSegments: nil,
            )
        }
    }

    private static func meetingAudioRow(_ recording: Recording) -> Row {
        Row(
            group: .meetingAudio,
            name: recording.appName ?? "Meeting app",
            marks: recording.paused ? [.recording, .paused] : [.recording],
            meetingApp: nil,
            litSegments: recording.paused ? 0 : recording.appLitSegments,
        )
    }

    /// `OutputDevices` names a device by its UID when Core Audio gives no
    /// name, and a USB device's UID carries its serial number.
    private static func displayName(_ name: String, uid: String) -> String {
        name.isEmpty || name == uid ? "Unnamed device" : name
    }

    private static func ordered(_ marks: Set<Mark>) -> [Mark] {
        Mark.allCases.filter(marks.contains)
    }

    private static func meetingAppName(_ marks: Set<Mark>, _ recording: Recording?) -> String? {
        marks.contains(.meetingApp) ? recording?.appName ?? "the meeting app" : nil
    }

    private enum Side {
        case input
        case output
    }

    /// The marks the reader's results decide: Used by <App> during a recording
    /// that taps an app, In use, and Status unknown wherever a reading this
    /// row depends on could not answer.
    private static func statusMarks(uid: String, side: Side, inputs: Inputs) -> Set<Mark> {
        var marks: Set<Mark> = []
        if let running = inputs.status.running?[uid] {
            if running { marks.insert(.inUse) }
        } else {
            marks.insert(.unknown)
        }
        guard inputs.recording?.capturesApp == true else { return marks }
        guard let devices = inputs.status.meetingApp else { return marks.union([.unknown]) }
        let (used, complete) = switch side {
        case .input: (devices.inputUIDs, devices.inputComplete)
        case .output: (devices.outputUIDs, devices.outputComplete)
        }
        if used.contains(uid) {
            marks.insert(.meetingApp)
        } else if !complete {
            marks.insert(.unknown)
        }
        return marks
    }
}

extension AudioDevicesWindowState.Mark {
    /// The capsule's words; `meetingApp` names the app for "Used by <App>".
    func label(meetingApp: String?) -> String {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .meetingApp: "Used by \(meetingApp ?? "the meeting app")"
        case .inUse: "In use"
        case .unknown: "Status unknown"
        case .systemDefault: "Default"
        case .notConnected: "Not connected"
        case .routingWarning: "Warning"
        }
    }
}

/// What the window's reader can say about the devices right now
/// (`AudioDevicesWindowReader`).
struct AudioDeviceStatus: Equatable, Sendable {
    /// Per device UID, whether Core Audio reports the device running for any
    /// process. A device missing from it could not be read. Nil while no
    /// reading is current (none has returned yet, or the last one is late), so
    /// every row is unknown; an empty one is a reading that found no device.
    let running: [String: Bool]? // swiftlint:disable:this discouraged_optional_collection
    /// Which devices the tapped processes of the running recording use; nil
    /// while no reading of them is current.
    let meetingApp: MeetingAppDevices?

    static let unknown = Self(running: nil, meetingApp: nil)
}

/// The input and output devices the tapped processes use, by UID.
struct MeetingAppDevices: Equatable, Sendable {
    let inputUIDs: Set<String>
    let outputUIDs: Set<String>
    /// False when a read on that side failed: a device missing from its set
    /// is then unknown rather than unused.
    let inputComplete: Bool
    let outputComplete: Bool
}
