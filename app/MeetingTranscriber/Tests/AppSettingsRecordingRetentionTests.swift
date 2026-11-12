import Foundation
@testable import MeetingTranscriber
import XCTest

/// The recording retention setting. Its own file because `AppSettingsTests`
/// sits at the 600-line cap.
final class AppSettingsRecordingRetentionTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppSettingsRecordingRetentionTests.\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return try XCTUnwrap(DefaultsSuite.open(suiteName))
    }

    /// Stored by name: a renamed case would read as Never for everyone who chose it.
    func testRecordingRetentionRawValuesArePinned() {
        XCTAssertEqual(RecordingRetention.allCases.map(\.rawValue), ["never", "afterProtocol", "days7", "days30", "days90"])
    }

    func testRecordingRetentionDefaultsToNeverAndSurvivesARestart() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.recordingRetention, .never)
        for retention in RecordingRetention.allCases {
            settings.recordingRetention = retention
            XCTAssertEqual(AppSettings(defaults: defaults).recordingRetention, retention)
        }
    }

    func testAnUnknownStoredRecordingRetentionReadsAsNever() throws {
        let defaults = try makeDefaults()
        defaults.set("days14", forKey: "recordingRetention")
        XCTAssertEqual(AppSettings(defaults: defaults).recordingRetention, .never)
    }
}
