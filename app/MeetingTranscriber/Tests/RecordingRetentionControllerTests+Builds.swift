@testable import MeetingTranscriber
import XCTest

// MARK: - Two builds over one record file

extension RecordingRetentionControllerTests {
    /// The development and the release build share the record file, each with a
    /// retention setting of its own. This build deletes after 30 days and the other
    /// keeps everything: this build's setting must not delete for good the audio of a
    /// meeting the other one recorded, whose own row says it stays, nor promise to.
    func testEachBuildsSettingReachesOnlyTheMeetingsThatBuildRecorded() async throws {
        let bed = try makeRetentionCheckBed()
        let suite = "RetentionOtherBuild-\(UUID().uuidString)"
        let otherSettings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: bed.harness.outputDir)
        addTeardownBlock { DefaultsSuite.remove(suite) }
        otherSettings.recordingRetention = .never
        let otherBuild = MeetingFileStore(path: bed.harness.recordPath, bundleID: RetentionFixture.otherBuild)
        let own = try bed.meeting()
        let theOthers = try bed.meeting(writtenBy: otherBuild)
        let fromBeforeTheField = try bed.meeting { $0.createdBy = nil }

        let audio = RecordingAudioLine.AudioOnDisk(presentCount: 6, unreachableCount: 0, totalCount: 6, bytes: 286_000_000)
        let lines = try [own, theOthers, fromBeforeTheField].map { record in
            try RecordingAudioLine.resolve(
                record: bed.current(record), live: nil, audio: audio, retention: bed.settings.recordingRetention,
                bundleID: bed.store.bundleID, now: bed.clock, calendar: bed.calendar, locale: RetentionFixture.locale,
            ).text
        }
        XCTAssertEqual(lines, ["Audio · 286 MB · deleted automatically at the next check", "Audio · 286 MB", "Audio · 286 MB"])
        let preview = await bed.controller().preview(for: .days30)
        XCTAssertEqual(preview?.meetingCount, 1, "the preview counts this build's meeting only")

        await bed.check()
        await bed.controller(store: otherBuild, settings: otherSettings).checkNow()

        try bed.assertAudioWent(own)
        try bed.assertUntouched(theOthers)
        try bed.assertUntouched(fromBeforeTheField)

        // The other build's own setting reaches its meeting, and still nothing else.
        otherSettings.recordingRetention = .afterProtocol
        await bed.controller(store: otherBuild, settings: otherSettings).checkNow()

        try bed.assertAudioWent(theOthers)
        try bed.assertUntouched(fromBeforeTheField)
    }
}
