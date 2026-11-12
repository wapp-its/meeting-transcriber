@testable import MeetingTranscriber
import XCTest

/// The details line under the menu's last recording, written for a fixed
/// clock, calendar, time zone and locale, so it reads the same on every
/// machine and at any hour, midnight included.
@MainActor
final class MenuBarLastRecordingDetailsTests: XCTestCase {
    private static let zurich = TimeZone(identifier: "Europe/Zurich")

    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(Self.zurich)
        return calendar
    }

    /// 12 Nov 2026 at `hour`:`minute` in Zurich, or `dayOffset` days from it.
    private func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) throws -> Date {
        try XCTUnwrap(calendar().date(from: DateComponents(year: 2026, month: 11, day: 12 + dayOffset, hour: hour, minute: minute)))
    }

    /// A history entry with only what the line reads: the app, the meeting's
    /// start and when the job was added, each left out when nil, as in a
    /// record written before the history kept it.
    private func entry(app: String?, startedAt start: Date?, addedAt added: Date?) throws -> TranscriptionEntry {
        let job = PipelineJob(meetingTitle: "Retro", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        var encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalJobRecord(job: job))) as? [String: Any],
        )
        // Assigning nil removes the key.
        encoded["appName"] = app.map { $0 as Any }
        encoded["meetingStartTime"] = start.map { $0.timeIntervalSinceReferenceDate as Any }
        encoded["enqueuedAt"] = added.map { $0.timeIntervalSinceReferenceDate as Any }
        let record = try JSONDecoder().decode(TerminalJobRecord.self, from: JSONSerialization.data(withJSONObject: encoded))
        return try XCTUnwrap(TranscriptionEntry(record: record, finishOrder: 0))
    }

    private struct Case {
        let name: String
        let app: String?
        let start: Date?
        var added: Date?
        let line: String?
    }

    func testTheLineIsTheAppThenTheDayAndTheTime() throws {
        let now = try at(14, 0)
        let cases: [Case] = try [
            Case(name: "today", app: "Teams", start: at(10, 30), line: "Teams · Today at 10:30"),
            Case(name: "today, just after midnight", app: "Teams", start: at(0, 0), line: "Teams · Today at 0:00"),
            Case(name: "yesterday, just before midnight", app: "Zoom", start: at(23, 59, dayOffset: -1), line: "Zoom · Yesterday at 23:59"),
            Case(name: "yesterday", app: "Zoom", start: at(9, 15, dayOffset: -1), line: "Zoom · Yesterday at 9:15"),
            Case(name: "an older day", app: "Zoom", start: at(9, 0, dayOffset: -2), line: "Zoom · 10 Nov 2026 at 9:00"),
            Case(name: "the start, not when the job was added", app: "Teams", start: at(10, 30), added: at(11, 15), line: "Teams · Today at 10:30"),
            Case(name: "when the job was added, without a start", app: "Teams", start: nil, added: at(11, 15), line: "Teams · Today at 11:15"),
            Case(name: "no app", app: nil, start: at(10, 30), line: "Today at 10:30"),
            Case(name: "no time", app: "Teams", start: nil, line: "Teams"),
            Case(name: "neither", app: nil, start: nil, line: nil),
        ]
        for testCase in cases {
            let line = try MenuBarView.lastRecordingDetails(
                for: entry(app: testCase.app, startedAt: testCase.start, addedAt: testCase.added),
                now: now, calendar: calendar(), locale: Locale(identifier: "en_GB"),
            )
            XCTAssertEqual(line, testCase.line, testCase.name)
        }
    }

    /// The date and the time are written in the locale; the day words stay
    /// English, as all of the app's text is.
    func testTheDateAndTimeFollowTheLocale() throws {
        let line = try MenuBarView.lastRecordingDetails(
            for: entry(app: "Zoom", startedAt: at(9, 0, dayOffset: -2), addedAt: nil),
            now: at(14, 0), calendar: calendar(), locale: Locale(identifier: "en_US"),
        )

        XCTAssertEqual(line, "Zoom · Nov 10, 2026 at 9:00\u{202F}AM")
    }
}
