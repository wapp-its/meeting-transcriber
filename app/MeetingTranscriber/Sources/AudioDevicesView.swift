import SwiftUI

extension Notification.Name {
    /// Brings the Audio Devices window to the front; observed by the menu bar
    /// scene, posted by the debug RPC's `/action/openAudioDevices`.
    static let showAudioDevices = Notification.Name("showAudioDevices")
    /// Closes the Audio Devices window; observed by the window itself, posted
    /// by the debug RPC's `/action/closeAudioDevices`.
    static let closeAudioDevices = Notification.Name("closeAudioDevices")
}

/// The Audio Devices window, opened by "Device Details…" in the menu bar's
/// Audio Devices section. A `Window` scene, so choosing the item again brings
/// the one window to the front rather than opening a second.
struct AudioDevicesScene: Scene {
    let appState: AppState

    var body: some Scene {
        Window(AudioDevicesWindowState.windowTitle, id: AudioDevicesView.windowID) {
            AudioDevicesWindowContent(appState: appState)
        }
        .windowResizability(.contentSize)
    }
}

/// The window's content: renders the state value and runs the reader for as
/// long as the window is open.
struct AudioDevicesWindowContent: View {
    let appState: AppState
    @Environment(\.dismissWindow)
    private var dismissWindow

    var body: some View {
        AudioDevicesView(state: appState.audioDevicesWindowState)
            .onAppear { appState.audioDevices.windowOpened() }
            .onDisappear { appState.audioDevices.windowClosed() }
            .onReceive(NotificationCenter.default.publisher(for: .closeAudioDevices)) { _ in
                dismissWindow(id: AudioDevicesView.windowID)
            }
    }
}

/// Renders `AudioDevicesWindowState` and nothing else: every string, mark and
/// level comes from the state. Read-only: no row holds a control, since
/// switching stays in the menu's Microphone and Output entries.
struct AudioDevicesView: View {
    nonisolated static let windowID = "audio-devices"

    let state: AudioDevicesWindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AudioDevicesSectionView(section: state.microphones, showsLevelColumn: state.showsLevelColumn)
            AudioDevicesSectionView(section: state.outputs, showsLevelColumn: state.showsLevelColumn)
            if let meetingAudio = state.meetingAudio {
                AudioDevicesSectionView(section: meetingAudio, showsLevelColumn: state.showsLevelColumn)
            }
            Text(state.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
    }
}

/// A heading, its rounded list and the grey hint line under the list.
struct AudioDevicesSectionView: View {
    let section: AudioDevicesWindowState.Section
    let showsLevelColumn: Bool

    var body: some View {
        Text(section.title)
            .font(.headline)
            .padding(.top, 4)
        VStack(spacing: 0) {
            if section.rows.isEmpty {
                Text(AudioDevicesWindowState.noneFound)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                AudioDeviceRowView(row: row, showsLevelColumn: showsLevelColumn)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        if let hint = section.hint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One device: its name, its marks and, while a recording runs, the level
/// column.
struct AudioDeviceRowView: View {
    let row: AudioDevicesWindowState.Row
    let showsLevelColumn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(row.marks, id: \.self) { mark in
                AudioDeviceMarkView(mark: mark, meetingApp: row.meetingApp)
            }
            Spacer(minLength: 8)
            if showsLevelColumn {
                levelColumn
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var levelColumn: some View {
        Group {
            if let lit = row.litSegments {
                AudioDeviceLevelBar(litSegments: lit)
            } else {
                Text(AudioDevicesWindowState.noLevel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: AudioDeviceLevelBar.width, alignment: .trailing)
    }
}
