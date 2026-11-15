#if !APPSTORE
    import Foundation

    // `selfRunningInput` is a nullable boolean on the wire: null is "no
    // answer", which a false would misreport as "not running".
    // swiftlint:disable discouraged_optional_boolean

    /// `/state.audioDevicesWindow`: the Audio Devices window as the debug RPC
    /// reports it. Built from `AudioDevicesWindowState` and the window reader's
    /// last results, so building it makes no Core Audio call: `/state` is built
    /// on the main actor, and a hanging read there would freeze the app.
    struct AudioDevicesWindowSnapshot: Codable, Equatable {
        let open: Bool
        /// Every row top to bottom; empty while the window is closed.
        let rows: [Row]
        /// Whether Core Audio reports this app's own process running audio
        /// input, for the no-capture check. Null while the window is closed,
        /// before the first reading returns, and when a reading failed or is
        /// late.
        let selfRunningInput: Bool?

        struct Row: Codable, Equatable {
            /// `microphone`, `output` or `meetingAudio`.
            let group: String
            let name: String
            /// `AudioDevicesWindowState.Mark` raw values, in the row's order.
            let marks: [String]
            /// The meeting app's name, null unless `marks` holds `meetingApp`.
            let meetingApp: String?
            /// Whether the row shows a level bar.
            let levelBar: Bool
            /// How many of the bar's 12 segments are lit; absent without a bar.
            let litSegments: Int?

            init(_ row: AudioDevicesWindowState.Row) {
                group = row.group.rawValue
                name = row.name
                marks = row.marks.map(\.rawValue)
                meetingApp = row.meetingApp
                levelBar = row.litSegments != nil
                litSegments = row.litSegments
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(group, forKey: .group)
                try container.encode(name, forKey: .name)
                try container.encode(marks, forKey: .marks)
                try container.encode(meetingApp, forKey: .meetingApp)
                try container.encode(levelBar, forKey: .levelBar)
                try container.encodeIfPresent(litSegments, forKey: .litSegments)
            }
        }

        static let closed = Self(open: false, rows: [], selfRunningInput: nil)

        init(open: Bool, rows: [Row], selfRunningInput: Bool?) {
            self.open = open
            self.rows = rows
            self.selfRunningInput = selfRunningInput
        }

        /// The open window.
        init(state: AudioDevicesWindowState, selfRunningInput: Bool?) {
            self.init(open: true, rows: state.rows.map(Row.init), selfRunningInput: selfRunningInput)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(open, forKey: .open)
            try container.encode(rows, forKey: .rows)
            try container.encode(selfRunningInput, forKey: .selfRunningInput)
        }
    }

    // swiftlint:enable discouraged_optional_boolean

    extension AppState {
        /// `/state.audioDevicesWindow`, from the window's state value and the
        /// reader's last results.
        func audioDevicesWindowSnapshot() -> AudioDevicesWindowSnapshot {
            guard audioDevices.isOpen else { return .closed }
            return AudioDevicesWindowSnapshot(state: audioDevicesWindowState, selfRunningInput: audioDevices.selfRunningInput)
        }
    }
#endif
