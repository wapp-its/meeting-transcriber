import SwiftUI

/// Parts of `TranscriptionsView` that read none of its state: the window's
/// messages and placeholder, and a row's badge, summary, status and outcome lines.
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

    /// The meeting's summary under the title line (spec R3, D6): at most two lines
    /// cut with "…", the whole text as the tooltip, nothing without one. Smaller than
    /// the title and larger than the lines below it.
    @ViewBuilder
    func summaryLine(_ entry: TranscriptionEntry, index: Int) -> some View {
        if let summary = entry.summary {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(summary)
                .accessibilityIdentifier(A11yID.recordingSummaryLine(index))
        }
    }

    /// While a deletion is incomplete, why it stopped takes the status's place: that
    /// is what the row needs from the user, and a finished job has nothing to add.
    @ViewBuilder
    func statusLine(_ entry: TranscriptionEntry, facts: RowFacts) -> some View {
        if let incomplete = facts.audioLine.incompleteText {
            Label(incomplete, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label(statusText(entry), systemImage: statusSymbol(entry))
                .font(.caption)
        }
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
