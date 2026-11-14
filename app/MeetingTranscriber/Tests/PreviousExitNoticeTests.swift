@testable import MeetingTranscriber
import XCTest

/// Wording of the launch-time notice for a run that ended without a quit
/// (issue #703). Pinned in a fixed locale, calendar and time zone so the
/// assertions do not depend on the machine running them.
final class PreviousExitNoticeTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "en_GB")
    // swiftlint:disable:next force_unwrapping
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "bad fixture date \(iso)")
    }

    private func notice(lastAlive: String, now: String) throws -> PreviousExitNotice {
        try PreviousExitNotice(
            lastAlive: date(lastAlive), now: date(now),
            calendar: calendar, locale: locale, timeZone: utc,
        )
    }

    /// The reporter's case: a morning crash noticed and relaunched hours
    /// later, on the same day. The notice names both ends of the window and
    /// says what the window meant.
    func testASameDayWindowIsNamedByItsTimes() throws {
        let notice = try notice(lastAlive: "2026-09-09T10:52:00Z", now: "2026-09-09T14:03:00Z")

        XCTAssertEqual(
            notice.body,
            "It stopped without quitting at about 10:52 and was not watching for meetings "
                + "until 14:03. Nothing was recorded in between.",
        )
    }

    /// A window that crosses midnight would read as this morning if the stop
    /// carried only a time, so the date is added, after the time: "at about
    /// 10:52 on 8 Mar". Pinned in full because this is the common case (a
    /// crash in the evening, noticed the next morning) and a `contains` check
    /// let "at about 8 Mar at 10:52" through. The launch end is dated too, or
    /// a gap of a day and more reads like a few minutes.
    func testAWindowFromAnEarlierDayCarriesTheDate() throws {
        let notice = try notice(lastAlive: "2026-03-08T10:52:00Z", now: "2026-03-09T14:03:00Z")

        XCTAssertEqual(
            notice.body,
            "It stopped without quitting at about 10:52 on 8 Mar and was not watching for meetings "
                + "until 14:03 on 9 Mar. Nothing was recorded in between.",
        )
    }

    /// Two days down, one minute apart on the clock: with only the launch
    /// time the window read "10:52 on 8 Mar ... until 10:53", a minute. Both
    /// ends carry their date whenever the days differ, a few minutes across
    /// midnight included.
    func testAWindowOverDifferentDaysDatesBothEnds() throws {
        // The hour after midnight is written "0:10" or "00:10" depending on the
        // system's locale data, so that one time comes from the system style;
        // what is pinned here is the date after it.
        let shortTime = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: utc)
        let afterMidnight = try date("2026-03-09T00:10:00Z").formatted(shortTime)
        let cases: [(lastAlive: String, now: String, window: String)] = [
            ("2026-03-08T10:52:00Z", "2026-03-10T10:53:00Z", "10:52 on 8 Mar and was not watching for meetings until 10:53 on 10 Mar"),
            ("2026-03-08T23:50:00Z", "2026-03-09T00:10:00Z", "23:50 on 8 Mar and was not watching for meetings until \(afterMidnight) on 9 Mar"),
        ]
        for testCase in cases {
            let notice = try notice(lastAlive: testCase.lastAlive, now: testCase.now)

            XCTAssertEqual(
                notice.body,
                "It stopped without quitting at about \(testCase.window). Nothing was recorded in between.",
                testCase.lastAlive,
            )
        }
    }

    /// A clock set back between the runs puts the stop after the launch. The
    /// notice still comes, says what it measured, and dates both ends.
    func testAStopAfterTheLaunchStillGivesADatedNotice() throws {
        let notice = try notice(lastAlive: "2026-03-10T10:52:00Z", now: "2026-03-09T11:15:00Z")

        XCTAssertEqual(
            notice.body,
            "It stopped without quitting at about 10:52 on 10 Mar and was not watching for meetings "
                + "until 11:15 on 9 Mar. Nothing was recorded in between.",
        )
    }

    /// The title is what the user could not see for themselves.
    func testTheTitleSaysTheAppWasNotRunning() {
        XCTAssertEqual(PreviousExitNotice.title, "Meeting Transcriber was not running")
    }
}
