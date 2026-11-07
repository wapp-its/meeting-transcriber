@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class OutputSettingsViewTests: XCTestCase {
    // MARK: - OutputSettingsLogic.displayPath

    func testDisplayPathAbbreviatesHomePrefix() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alice/Documents/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "~/Documents/Meetings",
        )
    }

    func testDisplayPathReturnsFullPathOutsideHome() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Volumes/External/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Volumes/External/Meetings",
        )
    }

    func testDisplayPathExactlyHomeReturnsTilde() {
        let home = URL(fileURLWithPath: "/Users/alice")
        XCTAssertEqual(OutputSettingsLogic.displayPath(for: home, home: home), "~")
    }

    func testDisplayPathDifferentUserHomeReturnsFull() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/bob/Documents")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/bob/Documents",
        )
    }

    /// Regression guard: a naive `hasPrefix` match treats `/Users/alicebob/foo`
    /// as inside `/Users/alice` and yields `~bob/foo`. Boundary must be a path
    /// component (`/` or end-of-string).
    func testDisplayPathDoesNotMatchAcrossComponentBoundary() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alicebob/foo")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/alicebob/foo",
        )
    }

    // MARK: - OutputSettingsLogic.mergePickerOptions

    func testMergePickerOptionsPrependsSelectedWhenAbsent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "custom-tag:latest",
        )
        XCTAssertEqual(result, ["custom-tag:latest", "gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedWhenSelectedPresent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedForEmptySelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4"], selected: "",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableYieldsJustSelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: [], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableAndEmptySelectedYieldsEmpty() {
        let result = OutputSettingsLogic.mergePickerOptions(available: [], selected: "")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Protocol language list

    func testProtocolLanguagesContainNoDuplicates() {
        // The picker uses the names as ForEach ids, so a repeat would collide.
        let languages = AppSettings.protocolLanguages
        XCTAssertEqual(languages.count, Set(languages).count)
    }

    // MARK: - Render

    func testViewRendersWithDefaultSettings() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        let view = OutputSettingsView(settings: settings)
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - Recordings section

    /// A `RetentionChoice` over stubs, with what it was asked. Its apply writes the
    /// setting as the real one does (`RetentionPreviewTests` holds the real one to that).
    @MainActor
    private final class RetentionBed {
        let settings: AppSettings
        var answer: RetentionPreview
        private(set) var asked: [RecordingRetention] = []
        private(set) var applied: [RecordingRetention] = []
        /// A value's check waits here until the test opens it.
        var gates: [RecordingRetention: MainActorGate] = [:]
        private(set) lazy var choice = RetentionChoice(settings: settings, actions: RetentionSettingsActions(
            preview: { [weak self, first = answer] value in
                self?.asked.append(value)
                let answer = self?.answer ?? first
                await self?.gates[value]?.wait()
                return answer
            },
            apply: { [weak self] value in
                self?.applied.append(value)
                self?.settings.recordingRetention = value
            },
        ))
        private(set) lazy var view = OutputSettingsView(settings: settings, retentionChoice: choice)

        init(settings: AppSettings, answer: RetentionPreview) {
            self.settings = settings
            self.answer = answer
        }

        func picker() throws -> InspectableView<ViewType.Picker> {
            try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingRetentionPicker).find(ViewType.Picker.self)
        }

        func alert() throws -> InspectableView<ViewType.Alert> {
            try view.inspect().find(ViewType.Alert.self)
        }

        func alertButton(_ id: String) throws -> InspectableView<ViewType.Button> {
            try alert().actions().find(viewWithAccessibilityIdentifier: id).button()
        }

        /// Chooses `value` the way the picker does and waits for the check to answer.
        func pick(_ value: RecordingRetention) async throws {
            try picker().select(value: value)
            await choice.checking?.value
        }

        var shown: RecordingRetention? {
            try? picker().selectedValue(RecordingRetention.self)
        }
    }

    /// What a value would delete, as the stubbed check answers.
    private func answer(meetings: Int, for retention: RecordingRetention = .days30) -> RetentionPreview {
        let records = (0 ..< meetings).map { _ in RetentionFixture.record() }
        let selection = RetentionPreview.Selection(
            records: records, live: { _ in nil }, retention: retention, bundleID: RetentionFixture.thisBuild,
            now: RetentionFixture.longAfter, calendar: RetentionFixture.calendar,
        )
        return RetentionPreview(selection) { _ in .present(bytes: 100) }
    }

    private func makeRetentionBed(stored: RecordingRetention = .never, meetings: Int = 2, for retention: RecordingRetention = .days30) -> RetentionBed {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        settings.recordingRetention = stored
        return RetentionBed(settings: settings, answer: answer(meetings: meetings, for: retention))
    }

    func testTheSectionSitsDirectlyUnderOutputFolderAboveNotionAndMeetingNotes() throws {
        let bed = makeRetentionBed()

        let headers = try bed.view.inspect().findAll(ViewType.Section.self).map { section in
            try section.header().find(ViewType.Text.self).string()
        }

        XCTAssertEqual(Array(headers.prefix(4)), ["Output Folder", "Recordings", "Notion Database Export", "Meeting Notes"])
    }

    func testThePickerOffersTheFiveValuesAndStartsAtNever() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        let bed = RetentionBed(settings: settings, answer: answer(meetings: 0))
        let picker = try bed.picker()

        XCTAssertEqual(try picker.labelView().text().string(), "Delete recordings automatically")
        XCTAssertEqual(
            try picker.find(ViewType.ForEach.self).map { try $0.text().string() },
            ["Never", "Right after the notes", "After 7 days", "After 30 days", "After 90 days"],
        )
        XCTAssertEqual(try picker.selectedValue(RecordingRetention.self), .never)
    }

    func testTheSectionShowsItsThreeHelpLines() throws {
        let body = try makeRetentionBed().view.inspect()

        for line in [
            "Counts from the recording date. Only audio this app recorded is deleted; imported files never are.",
            "Audio stays until the meeting notes are saved and the speakers are named. "
                + "Failed meetings, meetings marked Keep and record-only recordings keep their audio.",
            "Deleted for good, not moved to the Trash. Copies in Time Machine backups or synced folders are not deleted.",
        ] {
            XCTAssertNoThrow(try body.find(text: line), line)
        }
    }

    /// It still applies to meetings recorded earlier, unlike the sections around it.
    func testTheSectionStaysEnabledInRecordOnlyMode() throws {
        let bed = makeRetentionBed()
        bed.settings.recordOnly = true

        XCTAssertFalse(try bed.picker().isDisabled())
        XCTAssertTrue(try bed.view.inspect().find(viewWithAccessibilityIdentifier: A11yID.protocolSection).isDisabled(), "test premise")
    }

    func testWithoutItsActionsTheTabLeavesTheSectionOut() throws {
        let body = try OutputSettingsView(settings: AppSettings(defaults: makeIsolatedDefaults())).inspect()

        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.recordingRetentionPicker))
    }

    func testTheSettingsWindowGivesTheTabItsActions() throws {
        let nothing = answer(meetings: 0, for: .days30)
        let view = SettingsView(
            settings: AppSettings(defaults: makeIsolatedDefaults()),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            recognitionStatsLog: RecognitionStatsLog(),
            stageTimingLog: StageTimingLog(),
            retentionActions: RetentionSettingsActions(preview: { _ in nothing }, apply: { _ in }),
        )

        XCTAssertNoThrow(try view.detailView(for: .output).inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingRetentionPicker))
    }

    func testAValueThatAffectsNothingIsSavedWithoutAsking() async throws {
        let bed = makeRetentionBed(meetings: 0)

        try await bed.pick(.days30)

        XCTAssertEqual(bed.asked, [.days30])
        XCTAssertEqual(bed.settings.recordingRetention, .days30)
        XCTAssertEqual(bed.shown, .days30)
        XCTAssertThrowsError(try bed.alert())
        XCTAssertEqual(bed.applied, [], "nothing to delete, so no check is due")
    }

    /// The stub would answer that meetings go, as overdue audio would make the real one,
    /// so asking at all parks the value and fails this.
    func testNeverOrALongerValueIsSavedWithoutAskingWhateverIsOverdue() async throws {
        let cases: [(RecordingRetention, RecordingRetention)] = [
            (.afterProtocol, .days7), (.days7, .days30), (.days7, .days90), (.days30, .days90),
            (.afterProtocol, .never), (.days7, .never), (.days90, .never),
        ]
        for (stored, value) in cases {
            let bed = makeRetentionBed(stored: stored)

            try await bed.pick(value)

            XCTAssertEqual(bed.asked, [], "\(stored) to \(value)")
            XCTAssertEqual(bed.settings.recordingRetention, value, "\(stored) to \(value)")
            XCTAssertEqual(bed.applied, [], "\(stored) to \(value): nothing confirmed, so no check is asked for")
            XCTAssertThrowsError(try bed.alert(), "\(stored) to \(value)")
        }
    }

    func testChoosingTheStoredValueAgainAsksNothing() async throws {
        let bed = makeRetentionBed(stored: .days30)

        try await bed.pick(.days30)

        XCTAssertEqual(bed.asked, [])
        XCTAssertEqual(bed.settings.recordingRetention, .days30)
    }

    func testAShorterValueThatAffectsMeetingsIsParkedAndTheSettingStays() async throws {
        let cases: [(RecordingRetention, RecordingRetention)] = [
            (.never, .days90), (.never, .afterProtocol), (.days90, .days30), (.days30, .days7), (.days7, .afterProtocol),
        ]
        for (stored, value) in cases {
            let bed = makeRetentionBed(stored: stored, for: value)

            try await bed.pick(value)

            XCTAssertEqual(bed.settings.recordingRetention, stored, "\(stored) to \(value)")
            XCTAssertEqual(bed.applied, [], "\(stored) to \(value)")
            XCTAssertEqual(bed.choice.candidate, value, "\(stored) to \(value)")
            XCTAssertEqual(bed.choice.preview, bed.answer, "\(stored) to \(value)")
            XCTAssertEqual(bed.shown, value, "\(stored) to \(value)")
        }
    }

    func testTheAlertSaysWhatThePreviewSaysWithCancelAndARedConfirmButton() async throws {
        let bed = makeRetentionBed()

        try await bed.pick(.days30)

        let alert = try bed.alert()
        XCTAssertEqual(try alert.title().string(), "Delete the audio of 2 meetings?")
        XCTAssertEqual(try alert.message().text().string(), bed.answer.message)
        let confirm = try bed.alertButton(A11yID.retentionPreviewConfirmButton)
        XCTAssertEqual(try confirm.labelView().text().string(), "Delete Audio of 2 Meetings")
        XCTAssertEqual(try confirm.role(), .destructive)
        let cancel = try bed.alertButton(A11yID.retentionPreviewCancelButton)
        XCTAssertEqual(try cancel.labelView().text().string(), "Cancel")
        XCTAssertEqual(try cancel.role(), .cancel)
    }

    /// Return answers Cancel: this deletes for good. ViewInspector reads no
    /// `.keyboardShortcut`, so this walks the view value.
    func testCancelIsTheDefaultButton() throws {
        let bed = makeRetentionBed()
        let buttons = RecordingsSettingsSection(choice: bed.choice).previewButtons(bed.answer)

        var shortcuts: [String: Set<Character>] = [:]
        try collectShortcuts(in: buttons, into: &shortcuts)

        XCTAssertEqual(shortcuts, ["Cancel": [KeyEquivalent.return.character]])
    }

    private func collectShortcuts(in value: Any, into found: inout [String: Set<Character>]) throws {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return }
        if String(describing: type(of: value)).hasPrefix("ModifiedContent<"),
           let content = mirror.descendant("content") as? any View,
           let modifier = mirror.descendant("modifier") {
            let keys = keyEquivalents(in: modifier)
            if !keys.isEmpty {
                try found[title(of: content), default: []].formUnion(keys.map(\.character))
            }
        }
        for child in mirror.children {
            try collectShortcuts(in: child.value, into: &found)
        }
    }

    private func keyEquivalents(in value: Any) -> [KeyEquivalent] {
        if let key = value as? KeyEquivalent { return [key] }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return [] }
        return mirror.children.flatMap { keyEquivalents(in: $0.value) }
    }

    private func title(of view: some View) throws -> String {
        try view.inspect().find(ViewType.Text.self).string()
    }

    func testConfirmingAppliesTheValueAndClosesTheAlert() async throws {
        let bed = makeRetentionBed()
        try await bed.pick(.days30)

        try bed.alertButton(A11yID.retentionPreviewConfirmButton).tap()

        XCTAssertEqual(bed.applied, [.days30])
        XCTAssertEqual(bed.settings.recordingRetention, .days30)
        XCTAssertEqual(bed.shown, .days30)
        XCTAssertNil(bed.choice.candidate)
        XCTAssertThrowsError(try bed.alert())
    }

    func testCancellingKeepsTheStoredValueAndClosesTheAlert() async throws {
        let bed = makeRetentionBed(stored: .days90)
        try await bed.pick(.days30)

        try bed.alertButton(A11yID.retentionPreviewCancelButton).tap()

        XCTAssertEqual(bed.applied, [])
        XCTAssertEqual(bed.settings.recordingRetention, .days90)
        XCTAssertEqual(bed.shown, .days90, "the picker goes back")
        XCTAssertNil(bed.choice.candidate)
        XCTAssertThrowsError(try bed.alert())
    }

    /// SwiftUI clears the alert's binding before or after running a button, and the
    /// buttons have to work either way.
    func testConfirmingStillAppliesWhenTheBindingWasClearedFirst() async throws {
        let bed = makeRetentionBed()
        try await bed.pick(.days30)
        let confirm = try bed.alertButton(A11yID.retentionPreviewConfirmButton)

        try bed.alert().dismiss()
        XCTAssertNil(bed.choice.candidate, "closing the alert is a Cancel")
        XCTAssertEqual(bed.settings.recordingRetention, .never)
        try confirm.tap()

        XCTAssertEqual(bed.applied, [.days30])
    }

    func testClosingTheAlertAnotherWayIsACancel() async throws {
        let bed = makeRetentionBed()
        try await bed.pick(.days30)

        try bed.alert().dismiss()

        XCTAssertEqual(bed.applied, [])
        XCTAssertEqual(bed.settings.recordingRetention, .never)
        XCTAssertEqual(bed.shown, .never)
    }

    /// While a slow volume answers, the window goes on: the value is not saved yet, the
    /// section says so, and another choice takes over.
    func testAChoiceWaitingForTheDiskSaysSoAndSavesNothing() async throws {
        let bed = makeRetentionBed()
        let gate = MainActorGate()
        bed.gates[.days30] = gate

        try bed.picker().select(value: RecordingRetention.days30)
        await waitFor(gate.hasWaiter)

        XCTAssertEqual(bed.settings.recordingRetention, .never)
        XCTAssertEqual(bed.shown, .days30)
        XCTAssertTrue(bed.choice.isChecking)
        XCTAssertNoThrow(try bed.view.inspect().find(text: "Checking which meetings this would delete…"))
        XCTAssertThrowsError(try bed.alert())

        gate.open()
        await bed.choice.checking?.value

        XCTAssertFalse(bed.choice.isChecking)
        XCTAssertThrowsError(try bed.view.inspect().find(text: "Checking which meetings this would delete…"))
        XCTAssertNoThrow(try bed.alert())
    }

    /// An answer for a value the user has moved on from says nothing about the setting.
    func testAnAnswerForAValueTheUserLeftIsDropped() async throws {
        let followUps: [(String, RecordingRetention, answerMeetings: Int)] = [
            ("another shorter value", .days7, 1),
            ("the stored value again", .never, 2),
        ]
        for (name, next, count) in followUps {
            let bed = makeRetentionBed()
            let gate = MainActorGate()
            bed.gates[.days30] = gate
            try bed.picker().select(value: RecordingRetention.days30)
            let first = try XCTUnwrap(bed.choice.checking)
            await waitFor(gate.hasWaiter)

            bed.answer = answer(meetings: count, for: next)
            try await bed.pick(next)
            bed.answer = answer(meetings: 2, for: .days30)
            gate.open()
            await first.value

            XCTAssertEqual(bed.settings.recordingRetention, .never, name)
            XCTAssertEqual(bed.choice.preview?.retention, next == .never ? nil : next, name)
        }
    }

    /// The user's whole way, on real files: the picker, the alert, and the check.
    func testConfirmingThePreviewOfTheRealControllerDeletesTheAudioAndCancellingDoesNot() async throws {
        let check = try makeRetentionCheckBed()
        check.settings.recordingRetention = .never
        let record = try check.meeting()
        let controller = RecordingRetentionController(
            settings: check.settings,
            store: check.store,
            remover: MeetingFileRemover { url in XCTFail("moved \(url.lastPathComponent) to the Trash") },
            liveState: { check.live[$0] },
            isListed: { check.listed.contains($0) },
            securityScope: check.harness.scopes.access,
            calendar: check.calendar,
            now: { check.clock },
            settingChangeDelay: .milliseconds(1),
        )
        let choice = RetentionChoice(settings: check.settings, actions: RetentionSettingsActions(
            preview: { await controller.preview(for: $0) },
            apply: { controller.apply($0) },
        ))
        let view = OutputSettingsView(settings: check.settings, retentionChoice: choice)
        func pick() async throws {
            try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingRetentionPicker)
                .find(ViewType.Picker.self).select(value: RecordingRetention.days30)
            await choice.checking?.value
        }

        try await pick()
        XCTAssertEqual(try view.inspect().find(ViewType.Alert.self).title().string(), "Delete the audio of 1 meeting?")
        try view.inspect().find(ViewType.Alert.self).actions()
            .find(viewWithAccessibilityIdentifier: A11yID.retentionPreviewCancelButton).button().tap()
        await controller.checkNow()
        XCTAssertEqual(check.settings.recordingRetention, .never)
        try check.assertUntouched(record, "after Cancel")

        try await pick()
        try view.inspect().find(ViewType.Alert.self).actions()
            .find(viewWithAccessibilityIdentifier: A11yID.retentionPreviewConfirmButton).button().tap()
        XCTAssertEqual(check.settings.recordingRetention, .days30)
        await waitFor { check.audioPaths(record).allSatisfy { !check.isOnDisk($0) } && !controller.isChecking }
        try check.assertAudioWent(record)
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OutputSettingsViewTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        guard let defaults = DefaultsSuite.open(suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        return defaults
    }
}
