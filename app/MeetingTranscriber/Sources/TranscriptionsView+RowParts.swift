import SwiftUI

/// Parts of `TranscriptionsView` that read none of its state: the window's
/// messages and placeholder, and a row's badge, status and outcome lines.
extension TranscriptionsView {
    func windowMessage(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func keepBadge(index: Int) -> some View {
        Text("Keep")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(.secondary.opacity(0.5), lineWidth: 1))
            .accessibilityIdentifier(A11yID.recordingKeepBadge(index))
    }

    func statusText(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.status(state: entry.state, hasWarnings: !entry.warnings.isEmpty, progress: entry.state.label)
    }

    func statusSymbol(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.symbol(state: entry.state, hasWarnings: !entry.warnings.isEmpty)
    }

    /// Why a failed job failed, or what a finished one warned about.
    @ViewBuilder
    func outcome(_ entry: TranscriptionEntry) -> some View {
        if entry.state == .error, let error = entry.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        } else if entry.state == .done, !entry.warnings.isEmpty {
            Text(entry.warnings.joined(separator: "; "))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
