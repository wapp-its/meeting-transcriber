import SwiftUI

/// The menu's "Last Recording" section: the newest finished recording, named,
/// with its app and time, and the item that opens it.
extension MenuBarView {
    /// Shown while a finished recording has a file or a Notion page, left out
    /// with its heading otherwise. The name, the details line and the open item
    /// are read from one entry, the one `TranscriptionList.lastFinished` picks,
    /// so they cannot name one recording and open another. The two lines are
    /// text, not items: choosing them does nothing, like the meeting lines at
    /// the top of the menu.
    @ViewBuilder var lastRecordingSection: some View {
        if let entry = TranscriptionList.lastFinished(transcriptionEntries),
           let target = JobOpenTarget.resolve(forEntry: entry, preferNotion: notionExportEnabled) {
            Section("Last Recording") {
                lastRecordingLines(entry)

                Button {
                    actions.openLastNotes(target)
                } label: {
                    Label(target.lastNotesLabel, systemImage: target.systemImage)
                }
                .keyboardShortcut("o")
                .accessibilityIdentifier(A11yID.openLastNotesMenuItem)
            }
        }
    }

    /// Set like the meeting lines at the top of the menu. A long name is shown
    /// whole, as the All Recordings window shows it.
    private func lastRecordingLines(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.subheadline)
                .fontWeight(.medium)
            if let details = lastRecordingDetails(entry) {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Hoisted out of the `ViewBuilder` for the type-check budget (see the
    /// note on `body`). The clock is read when the menu is drawn, as the All
    /// Recordings window reads it for its rows.
    private func lastRecordingDetails(_ entry: TranscriptionEntry) -> String? {
        Self.lastRecordingDetails(for: entry, now: Date(), calendar: .current, locale: .current)
    }

    /// The line under the last recording's name, "Teams · Today at 10:30": the
    /// app, then the day and the time. The day is "Today" or "Yesterday", else
    /// the abbreviated date; the time is the meeting's start, else when the job
    /// was added (`TranscriptionEntry.date`). `now` and the calendar decide the
    /// day, the calendar's time zone places the date, and `locale` writes the
    /// date and the time. A part the entry does not have is left out; with
    /// neither, there is no line.
    static func lastRecordingDetails(
        for entry: TranscriptionEntry, now: Date, calendar: Calendar, locale: Locale,
    ) -> String? {
        let when = entry.date.map { dayAndTime($0, now: now, calendar: calendar, locale: locale) }
        let parts = [entry.appName, when].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Today at 10:30", "Yesterday at 10:30", "10 Nov 2026 at 10:30": the
    /// joiner macOS writes between a day and a time in English.
    private static func dayAndTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let timeZone = calendar.timeZone
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let day = if calendar.isDate(date, inSameDayAs: now) {
            "Today"
        } else if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
            "Yesterday"
        } else {
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone))
        }
        return "\(day) at \(time)"
    }
}
