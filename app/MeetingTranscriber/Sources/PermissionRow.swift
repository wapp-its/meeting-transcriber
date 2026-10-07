import SwiftUI

/// A row showing permission status with a colored icon, an optional action
/// button and an info popover.
struct PermissionRow: View {
    /// A small push button at the row's trailing edge, before the "?" button.
    struct Action {
        let title: String
        let identifier: String
        let perform: @MainActor () -> Void
    }

    let label: String
    let detail: String
    var granted: Bool
    var warning: Bool = false
    var optional: Bool = false
    var help: String = ""
    var action: Action?
    @State private var showingHelp = false

    private var icon: String {
        if granted { return "checkmark.circle.fill" }
        if warning || optional { return "exclamationmark.triangle.fill" }
        return "xmark.circle.fill"
    }

    private var iconColor: Color {
        if granted { return .green }
        if warning || optional { return .orange }
        return .red
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let action {
                Button(action.title, action: action.perform)
                    .accessibilityIdentifier(action.identifier)
                    .controlSize(.small)
            }
            if !help.isEmpty {
                Button {
                    showingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingHelp) {
                    Text(help)
                        .font(.callout)
                        .padding()
                }
            }
        }
    }
}
