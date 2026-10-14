@testable import MeetingTranscriber
import XCTest

/// When a recording is warned that it is about to reach its maximum length,
/// and the texts of the three notices: that warning, the notice that the
/// maximum ended the recording, and the notice that a manual recording ended
/// because its app quit. Pure, at the app's values: a 4-hour maximum and a
/// 10-minute lead.
final class RecordingStopNoticesTests: XCTestCase {
    private struct WarningCase {
        let name: String
        let elapsed: TimeInterval
        let maxDuration: TimeInterval
        let alreadyWarned: Bool
        let warns: Bool
    }

    private static let maxDuration: TimeInterval = 14400

    // MARK: - The warning decision

    func testTheWarningLeadIsTenMinutes() {
        XCTAssertEqual(RecordingCapWarningPolicy.defaultLead, 600)
    }

    func testWarnsOnceInsideTheLastTenMinutesAndNeverPastTheMaximum() {
        let cases = [
            WarningCase(name: "before the window", elapsed: 13799, maxDuration: Self.maxDuration, alreadyWarned: false, warns: false),
            WarningCase(name: "at the start of the window", elapsed: 13800, maxDuration: Self.maxDuration, alreadyWarned: false, warns: true),
            WarningCase(name: "a late poll inside the window", elapsed: 14000, maxDuration: Self.maxDuration, alreadyWarned: false, warns: true),
            WarningCase(name: "already warned", elapsed: 14000, maxDuration: Self.maxDuration, alreadyWarned: true, warns: false),
            // The stop is strict (`elapsed > maxDuration`), so a poll exactly
            // at the maximum still records and is still warned.
            WarningCase(name: "at the maximum", elapsed: 14400, maxDuration: Self.maxDuration, alreadyWarned: false, warns: true),
            WarningCase(name: "past the maximum", elapsed: 14400.5, maxDuration: Self.maxDuration, alreadyWarned: false, warns: false),
            WarningCase(name: "a maximum equal to the lead", elapsed: 0, maxDuration: 600, alreadyWarned: false, warns: false),
            WarningCase(name: "a maximum equal to the lead, near it", elapsed: 599, maxDuration: 600, alreadyWarned: false, warns: false),
            WarningCase(name: "a maximum below the lead", elapsed: 200, maxDuration: 300, alreadyWarned: false, warns: false),
        ]
        for item in cases {
            XCTAssertEqual(
                RecordingCapWarningPolicy.shouldWarn(
                    elapsed: item.elapsed,
                    maxDuration: item.maxDuration,
                    lead: RecordingCapWarningPolicy.defaultLead,
                    alreadyWarned: item.alreadyWarned,
                ),
                item.warns,
                item.name,
            )
        }
    }

    // MARK: - The texts

    func testTheWarningAtTheAppsValues() {
        let notice = RecordingStopNotices.capWarning(recordingTitle: "Weekly sync", elapsed: 13800, maxDuration: Self.maxDuration)

        XCTAssertEqual(notice.title, "Recording Ends in 10 Minutes")
        XCTAssertEqual(notice.body, "\"Weekly sync\" reaches the maximum length of 4 hours.")
        XCTAssertEqual(notice.urgency, .timeSensitive)
    }

    /// A poll that lands late in the window names the minutes actually left,
    /// rounded up, and never fewer than one.
    func testTheWarningCountsTheMinutesLeftRoundedUpAndAtLeastOne() {
        let elapsed: [TimeInterval] = [14000, 14370, 14400]
        let titles = elapsed.map { seconds in
            RecordingStopNotices.capWarning(recordingTitle: "Weekly sync", elapsed: seconds, maxDuration: Self.maxDuration).title
        }

        XCTAssertEqual(titles, ["Recording Ends in 7 Minutes", "Recording Ends in 1 Minute", "Recording Ends in 1 Minute"])
    }

    func testTheNoticeThatTheMaximumEndedTheRecording() {
        let notice = RecordingStopNotices.capReached(recordingTitle: "Weekly sync", maxDuration: Self.maxDuration)

        XCTAssertEqual(notice.title, "Recording Ended")
        XCTAssertEqual(notice.body, "\"Weekly sync\" reached the maximum length of 4 hours.")
        XCTAssertEqual(notice.urgency, .standard)
    }

    func testTheNoticeThatTheAppQuit() {
        let notice = RecordingStopNotices.appQuit(recordingTitle: "Weekly sync", appName: "Zoom")

        XCTAssertEqual(notice.title, "Recording Ended")
        XCTAssertEqual(notice.body, "Zoom quit, so the recording \"Weekly sync\" ended.")
        XCTAssertEqual(notice.urgency, .standard)
    }

    func testAnEmptyTitleIsLeftOutOfEveryText() {
        XCTAssertEqual(
            RecordingStopNotices.capWarning(recordingTitle: "", elapsed: 13800, maxDuration: Self.maxDuration).body,
            "This recording reaches the maximum length of 4 hours.",
        )
        XCTAssertEqual(
            RecordingStopNotices.capReached(recordingTitle: "", maxDuration: Self.maxDuration).body,
            "The recording reached the maximum length of 4 hours.",
        )
        XCTAssertEqual(
            RecordingStopNotices.appQuit(recordingTitle: "", appName: "Zoom").body,
            "Zoom quit, so the recording ended.",
        )
    }

    /// Whole hours when the length is a whole number of them, whole minutes
    /// otherwise, read from the value given.
    func testTheMaximumLengthIsNamedInWholeHoursOrElseWholeMinutes() {
        let lengths: [TimeInterval] = [14400, 3600, 5400, 600, 60]
        let phrases = lengths.map { RecordingStopNotices.lengthPhrase($0) }

        XCTAssertEqual(phrases, ["4 hours", "1 hour", "90 minutes", "10 minutes", "1 minute"])
    }

    // MARK: - The diagnostic line

    /// The trigger and the whole seconds left, and nothing else: the line is
    /// unconditional and ends up in the log file the user exports.
    func testTheLogLineCarriesOnlyTheTriggerAndTheSecondsLeft() {
        XCTAssertEqual(
            RecordingStopNotices.capWarningLogLine(trigger: .auto, remaining: 599.6),
            "recording_cap_warning trigger=auto remaining_s=600",
        )
        XCTAssertEqual(
            RecordingStopNotices.capWarningLogLine(trigger: .manual, remaining: 60),
            "recording_cap_warning trigger=manual remaining_s=60",
        )
    }
}
