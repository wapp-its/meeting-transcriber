@testable import MeetingTranscriber
import XCTest

/// The stored "Long Silence" setting and the threshold the watch loop reads
/// from it: on by default, five minutes, kept across a relaunch, and clamped to
/// 1…60 minutes both when written and when a stored value is read back.
final class AppSettingsSilencePromptTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "silence-prompt-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testDefaultsAskAfterFiveMinutes() throws {
        let settings = try AppSettings(defaults: makeDefaults())

        XCTAssertTrue(settings.silencePromptEnabled)
        XCTAssertEqual(settings.silencePromptMinutes, 5)
        XCTAssertEqual(settings.silencePromptAfter, 300)
    }

    func testBothValuesSurviveARelaunch() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.silencePromptEnabled = false
        settings.silencePromptMinutes = 12

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.silencePromptEnabled)
        XCTAssertEqual(relaunched.silencePromptMinutes, 12)
    }

    func testMinutesOutsideTheRangeAreClampedOnWrite() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        for (written, expected) in [(0, 1), (61, 60)] {
            settings.silencePromptMinutes = written

            XCTAssertEqual(settings.silencePromptMinutes, expected, "written \(written)")
            XCTAssertEqual(defaults.integer(forKey: "silencePromptMinutes"), expected, "stored after writing \(written)")
        }
    }

    /// A value stored by hand (`defaults write`) or by a later build with a
    /// wider range must not reach the loop unclamped.
    func testStoredMinutesOutsideTheRangeAreClampedOnLoad() throws {
        for (stored, expected) in [(0, 1), (61, 60)] {
            let defaults = try makeDefaults()
            defaults.set(stored, forKey: "silencePromptMinutes")

            XCTAssertEqual(AppSettings(defaults: defaults).silencePromptMinutes, expected, "stored \(stored)")
        }
    }

    func testThresholdFollowsTheMinutesAndIsNilWhenSwitchedOff() throws {
        let settings = try AppSettings(defaults: makeDefaults())
        settings.silencePromptMinutes = 7
        XCTAssertEqual(settings.silencePromptAfter, 420)

        settings.silencePromptEnabled = false

        XCTAssertNil(settings.silencePromptAfter)
    }
}
