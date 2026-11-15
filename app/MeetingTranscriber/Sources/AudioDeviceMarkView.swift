import SwiftUI

/// One mark as a small capsule, in the accepted boards' colours: Recording
/// red with a dot, Used by <App> blue, In use grey, Default outlined, the
/// routing Warning orange; Paused, Not connected and Status unknown grey.
struct AudioDeviceMarkView: View {
    let mark: AudioDevicesWindowState.Mark
    let meetingApp: String?

    var body: some View {
        HStack(spacing: 3) {
            if mark == .recording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
            }
            Text(mark.label(meetingApp: meetingApp))
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .foregroundStyle(tint)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(mark == .systemDefault ? Color.secondary : Color.clear))
    }

    private var tint: Color {
        switch mark {
        case .recording: .red
        case .meetingApp: .blue
        case .routingWarning: .orange
        case .paused, .inUse, .unknown, .systemDefault, .notConnected: .secondary
        }
    }

    private var fill: Color {
        mark == .systemDefault ? .clear : tint.opacity(0.15)
    }
}

/// The level column's bar: twelve segments in a row, the lit ones green.
struct AudioDeviceLevelBar: View {
    private static let segmentWidth: CGFloat = 6
    private static let spacing: CGFloat = 2
    /// The column's width, which the "no level" rows keep too.
    static let width = CGFloat(AudioDevicesWindowState.segmentCount) * (segmentWidth + spacing) - spacing

    let litSegments: Int

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0 ..< AudioDevicesWindowState.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < litSegments ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: Self.segmentWidth, height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level")
        .accessibilityValue("\(litSegments) of \(AudioDevicesWindowState.segmentCount)")
    }
}
