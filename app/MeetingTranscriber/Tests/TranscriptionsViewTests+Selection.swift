@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// Several rows at once: the footer, the selection's right-click menu and its one
/// confirmation. A click cannot be driven through `List(selection:)` here, so the
/// selection is set on its model. Which meetings an action applies to is covered by
/// `TranscriptionsSelectionTests`, and what the dialog says by `TrashConfirmationTextTests`.
extension TranscriptionsViewTests {
    private func row(_ title: String) -> TranscriptionEntry {
        entry(title, protocolPath: "/out/\(title).md", transcriptPath: "/out/\(title).txt")
    }

    /// A window whose rows have these meetings, the rest no record.
    private func rowActions(
        _ meetings: [(entry: TranscriptionEntry, meeting: Meeting)], retention: RecordingRetention = .never, base: AllRecordingsActions = .noop,
    ) -> AllRecordingsActions {
        var actions = base
        actions.filesOnDisk = { Self.recordedFilesOnDisk($0) }
        actions.meetingFiles = { id in meetings.first { $0.entry.id == id }?.meeting.record }
        actions.audioOnDisk = { entry in meetings.first { $0.entry.id == entry.id }?.meeting.audio }
        actions.retention = { retention }
        return actions
    }

    private func footer(of view: TranscriptionsView) throws -> String {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.transcriptionsFooter).text().string()
    }

    /// In a stack, so a menu of nothing reads as no items rather than as no view.
    private func menuIdentifiers(of view: TranscriptionsView, for ids: Set<UUID>) throws -> [String] {
        try VStack { view.selectionMenu(for: ids) }.inspect()
            .findAll { (try? $0.accessibilityIdentifier()) != nil }
            .map { try $0.accessibilityIdentifier() }
    }

    private func menuItem(_ identifier: String, of view: TranscriptionsView, for ids: Set<UUID>) throws -> InspectableView<ViewType.Button> {
        try view.selectionMenu(for: ids).inspect().find(viewWithAccessibilityIdentifier: identifier).button()
    }

    // MARK: - Footer

    /// The rows shown count, also while a search hides some; a row without a record or
    /// with its audio gone adds nothing to the size; a selection replaces the count, and
    /// only a row still shown counts as selected.
    func testTheFooterCoversTheRowsShownAndTheSelection() throws {
        let one = row("Retro")
        let two = row("Standup")
        let noRecord = row("No record")
        let audioGone = row("Audio gone")
        let selection = TranscriptionsSelection()
        let actions = rowActions([
            (one, meeting(one)),
            (two, meeting(two)),
            (audioGone, meeting(audioGone, audio: Self.noAudioLeft)),
        ])
        let all = [one, two, noRecord, audioGone]

        let sut = makeView(all, actions: actions, selection: selection)
        XCTAssertEqual(try footer(of: sut), "4 recordings · audio 96 MB")

        selection.ids = [one.id, noRecord.id]
        XCTAssertEqual(try footer(of: sut), "2 of 4 selected · audio 96 MB")

        let searching = makeView(all, query: "retro", actions: actions, selection: selection)
        XCTAssertEqual(try footer(of: searching), "1 of 1 selected · audio 48 MB")

        let hidesTheSelection = makeView(all, query: "standup", actions: actions, selection: selection)
        XCTAssertEqual(try footer(of: hidesTheSelection), "1 recording · audio 48 MB")

        let noMatch = makeView(all, query: "budget", actions: actions, selection: selection)
        XCTAssertEqual(try footer(of: noMatch), "0 recordings · no audio")
    }

    /// The window hands the footer the setting it was given, for each value.
    func testTheFooterFollowsEachRetentionValue() throws {
        let retro = row("Retro")
        let selection = TranscriptionsSelection()
        let third: [(RecordingRetention, String)] = [
            (.never, ""),
            (.afterProtocol, " · recordings are deleted automatically right after the notes (Settings → Output)"),
            (.days7, " · recordings are deleted automatically after 7 days (Settings → Output)"),
            (.days30, " · recordings are deleted automatically after 30 days (Settings → Output)"),
            (.days90, " · recordings are deleted automatically after 90 days (Settings → Output)"),
        ]
        XCTAssertEqual(third.map(\.0), RecordingRetention.allCases)
        for (retention, sentence) in third {
            let actions = rowActions([(retro, meeting(retro))], retention: retention)
            selection.ids = []
            XCTAssertEqual(try footer(of: makeView([retro], actions: actions, selection: selection)), "1 recording · audio 48 MB" + sentence)
            selection.ids = [retro.id]
            XCTAssertEqual(try footer(of: makeView([retro], actions: actions, selection: selection)), "1 of 1 selected · audio 48 MB" + sentence)
        }
    }

    /// Sizes come from the rows' cache: a redraw, also a whole list's, reads nothing again.
    func testTheFooterReadsTheAudioOncePerRefresh() throws {
        let rows = [row("One"), row("Two")]
        var reads = 0
        var actions = rowActions(rows.map { ($0, meeting($0)) })
        let readAudio = actions.audioOnDisk
        actions.audioOnDisk = { entry in
            reads += 1
            return readAudio(entry)
        }
        let sut = makeView(rows, actions: actions)

        _ = try footer(of: sut)
        _ = try footer(of: sut)

        XCTAssertEqual(reads, 2)
    }

    // MARK: - The selection's menu

    /// The menu of what was right-clicked: of no row nothing, of one row its own full
    /// list, in its own index, and of several only the two Trash items.
    func testTheMenuFollowsHowManyRowsItIsFor() throws {
        let rows = [row("One"), row("Two"), row("Three")]
        let sut = makeView(rows, actions: rowActions(rows.map { ($0, meeting($0)) }))

        XCTAssertEqual(try menuIdentifiers(of: sut, for: []), [])

        let expected = RecordingRowActions.menuItems(
            state: .done, onDisk: Self.recordedFilesOnDisk(rows[1]), canRetry: false, meeting: meeting(rows[1]),
        )
        XCTAssertEqual(try menuIdentifiers(of: sut, for: [rows[1].id]), expected.map { TranscriptionsView.identifier(of: $0, index: 1) })

        let several: Set<UUID> = [rows[0].id, rows[2].id]
        XCTAssertEqual(try menuIdentifiers(of: sut, for: several), [
            A11yID.recordingsSelectionMoveAudioToTrash,
            A11yID.recordingsSelectionMoveMeetingToTrash,
        ])
        XCTAssertEqual(
            try menuItem(A11yID.recordingsSelectionMoveAudioToTrash, of: sut, for: several).labelView().text().string(), "Move Audio to Trash…",
        )
        XCTAssertEqual(
            try menuItem(A11yID.recordingsSelectionMoveMeetingToTrash, of: sut, for: several).labelView().text().string(), "Move Meeting to Trash…",
        )
    }

    /// A selected row the search hides is not acted on: what is left decides the menu.
    func testARowTheSearchHidesDoesNotCountForTheMenu() throws {
        let rows = [row("Retro"), row("Standup")]
        let sut = makeView(rows, query: "retro", actions: rowActions(rows.map { ($0, meeting($0)) }))

        let identifiers = try menuIdentifiers(of: sut, for: [rows[0].id, rows[1].id])

        XCTAssertTrue(identifiers.contains(A11yID.recordingMenuMoveAudioToTrash(0)), "the row's own menu: \(identifiers)")
        XCTAssertFalse(identifiers.contains(A11yID.recordingsSelectionMoveAudioToTrash))
    }

    /// Each item is off when it applies to none of the rows, and Move Meeting while a
    /// regeneration runs, as on a single row.
    func testAnItemIsDisabledWhenItAppliesToNone() throws {
        let plain = row("Plain")
        let other = row("Other")
        let imported = row("Imported")
        let noRecord = row("No record")
        let audioItem = A11yID.recordingsSelectionMoveAudioToTrash
        let meetingItem = A11yID.recordingsSelectionMoveMeetingToTrash
        let actions = rowActions([(plain, meeting(plain)), (other, meeting(other)), (imported, meeting(imported, origin: .imported))])
        let sut = makeView([plain, other, imported, noRecord], actions: actions)

        let both: Set<UUID> = [plain.id, other.id]
        XCTAssertFalse(try menuItem(audioItem, of: sut, for: both).isDisabled())
        XCTAssertFalse(try menuItem(meetingItem, of: sut, for: both).isDisabled())

        let importAndNoRecord: Set<UUID> = [imported.id, noRecord.id]
        XCTAssertTrue(try menuItem(audioItem, of: sut, for: importAndNoRecord).isDisabled())
        XCTAssertFalse(try menuItem(meetingItem, of: sut, for: importAndNoRecord).isDisabled())

        let regenerating = makeView([plain, other], actions: actions, regenerationPhase: .running)
        XCTAssertFalse(try menuItem(audioItem, of: regenerating, for: both).isDisabled())
        XCTAssertTrue(try menuItem(meetingItem, of: regenerating, for: both).isDisabled())
    }

    // MARK: - The one confirmation

    /// Each item only asks, once, with the plan's text. Cancel changes nothing. Confirming
    /// runs the action once per meeting it applies to, never on one left out; those acted
    /// on leave the selection and the one left out stays in it.
    func testEachItemAsksOnceAndConfirmingRunsItOnTheMeetingsItAppliesTo() throws {
        let one = row("One")
        let two = row("Two")
        let leftOut = row("Left out")
        let meetings = [(entry: one, meeting: meeting(one)), (entry: two, meeting: meeting(two))]
        let selected = meetings.map { TrashSelectionPlan.Selected(entry: $0.entry, meeting: $0.meeting) }
            + [TrashSelectionPlan.Selected(entry: leftOut, meeting: nil)]
        let cases: [(item: String, action: TrashConfirmationPrompt.Action, call: String)] = [
            (A11yID.recordingsSelectionMoveAudioToTrash, .moveAudio, "moveAudioToTrash"),
            (A11yID.recordingsSelectionMoveMeetingToTrash, .moveMeeting, "moveMeetingToTrash"),
        ]
        for testCase in cases {
            var calls: [String] = []
            let selection = TranscriptionsSelection()
            selection.ids = [one.id, two.id, leftOut.id]
            let sut = makeView(
                [one, two, leftOut], actions: rowActions(meetings, base: recording { calls.append($0) }), selection: selection,
            )

            XCTAssertThrowsError(try trashAlert(in: sut), "a dialog before any click")
            try menuItem(testCase.item, of: sut, for: selection.ids).tap()
            let text = TrashConfirmationText.forSelection(TrashSelectionPlan(action: testCase.action, selected: selected))
            let alert = try trashAlert(in: sut)
            XCTAssertEqual(try alert.title().string(), text.title)
            XCTAssertEqual(try alert.message().text().string(), text.lines.joined(separator: "\n\n"))
            XCTAssertEqual(calls, [])

            try tapInTrashAlert(A11yID.recordingTrashCancelButton, in: sut)
            XCTAssertThrowsError(try trashAlert(in: sut))
            XCTAssertEqual(calls, [])
            XCTAssertEqual(selection.ids, [one.id, two.id, leftOut.id], "Cancel keeps the selection")

            try menuItem(testCase.item, of: sut, for: selection.ids).tap()
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)
            XCTAssertEqual(calls, ["\(testCase.call) \(one.id)", "\(testCase.call) \(two.id)"])
            XCTAssertThrowsError(try trashAlert(in: sut))
            XCTAssertEqual(selection.ids, [leftOut.id])
        }
    }

    /// The "…" menu acts on its own row, also while other rows are selected.
    func testARowsOwnItemActsOnThatRowAloneDuringASelection() throws {
        let one = row("One")
        let two = row("Two")
        let meetings = [(entry: one, meeting: meeting(one)), (entry: two, meeting: meeting(two))]
        var calls: [String] = []
        let selection = TranscriptionsSelection()
        selection.ids = [one.id, two.id]
        let sut = makeView([one, two], actions: rowActions(meetings, base: recording { calls.append($0) }), selection: selection)

        try button(A11yID.recordingMenuMoveAudioToTrash(0), in: sut).tap()
        XCTAssertEqual(try trashAlert(in: sut).title().string(), "Move the audio of “One” to the Trash?")
        try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

        XCTAssertEqual(calls, ["moveAudioToTrash \(one.id)"])
        XCTAssertEqual(selection.ids, [two.id])
    }

    // MARK: - Over the real controller

    private func makeSelectionHarness() throws -> MeetingDeletionHarness {
        let suite = "TranscriptionsSelection-\(getpid())-\(UUID().uuidString)"
        let root = try makeTempDirectory(prefix: "transcriptions-selection")
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: root.appendingPathComponent("output"),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try MeetingDeletionHarness(root: root, settings: settings)
    }

    private func window(
        over controller: PipelineController, scopeRoot: URL, selection: TranscriptionsSelection, phase: ProtocolRegenerator.Phase = .idle,
    ) -> TranscriptionsView {
        var actions = AllRecordingsActions.noop
        actions.filesOnDisk = { AllRecordingsActions.readFilesOnDisk(of: $0, scopeRoot: scopeRoot) }
        actions.meetingFiles = { controller.meetingFileStore.record(for: $0) }
        actions.audioOnDisk = { entry in
            controller.meetingFileStore.record(for: entry.id).map { AllRecordingsActions.readAudioOnDisk(of: $0, scopeRoot: scopeRoot) }
        }
        actions.moveAudioToTrash = { controller.moveAudioToTrash(jobID: $0) }
        actions.moveMeetingToTrash = { controller.moveMeetingToTrash(jobID: $0) }
        actions.retryDeletion = { controller.retryDeletion(jobID: $0) }
        return makeView(controller.transcriptionEntries, actions: actions, regenerationPhase: phase, selection: selection)
    }

    /// A file back on disk since the dialog opened stops the whole batch: nothing of any
    /// meeting moves, as the dialog never counted that file. Asked again, it does.
    func testAFileThatCameBackStopsTheWholeSelection() throws {
        let cases = [
            (item: A11yID.recordingsSelectionMoveAudioToTrash, moved: 6),
            (item: A11yID.recordingsSelectionMoveMeetingToTrash, moved: 10),
        ]
        for testCase in cases {
            let harness = try makeSelectionHarness()
            let controller = harness.controller(queue: harness.makeQueue())
            let first = try harness.recordedMeeting()
            let second = try harness.recordedMeeting()
            let track = try XCTUnwrap(second.micPath)
            let aside = harness.root.appendingPathComponent("aside.wav")
            try FileManager.default.moveItem(at: track, to: aside)
            let selection = TranscriptionsSelection()
            selection.ids = [first.id, second.id]
            let sut = window(over: controller, scopeRoot: harness.outputDir, selection: selection)

            try menuItem(testCase.item, of: sut, for: selection.ids).tap()
            try FileManager.default.moveItem(at: aside, to: track)
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

            XCTAssertEqual(harness.fakeTrash.moved, [])
            XCTAssertNoThrow(try sut.inspect().find(text: Self.severalNothingMoved))
            XCTAssertThrowsError(try trashAlert(in: sut))
            XCTAssertEqual(selection.ids, [first.id, second.id], "the rows stay selected, to ask again")
            XCTAssertNil(controller.meetingFileStore.record(for: first.id)?.pending)
            XCTAssertNil(controller.meetingFileStore.record(for: second.id)?.pending)

            try menuItem(testCase.item, of: sut, for: selection.ids).tap()
            XCTAssertThrowsError(try sut.inspect().find(text: Self.severalNothingMoved), "asking again takes the message away")
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

            XCTAssertEqual(harness.fakeTrash.moved.count, testCase.moved)
        }
    }

    /// A file of a later meeting that comes back while an earlier one moves does not go
    /// either: each meeting is asked again right before its own action, and the batch
    /// stops there, says how far it got and keeps the rest selected.
    func testAFileThatComesBackDuringTheBatchStopsItBeforeThatMeeting() throws {
        for item in [A11yID.recordingsSelectionMoveAudioToTrash, A11yID.recordingsSelectionMoveMeetingToTrash] {
            let harness = try makeSelectionHarness()
            let controller = harness.controller(queue: harness.makeQueue())
            let meetings = try [harness.recordedMeeting(), harness.recordedMeeting()]
            let laterID = try XCTUnwrap(controller.transcriptionEntries.last?.id, "the batch acts in the list's order")
            let track = try XCTUnwrap(meetings.first { $0.id == laterID }?.micPath)
            let aside = harness.root.appendingPathComponent("aside.wav")
            try FileManager.default.moveItem(at: track, to: aside)
            let selection = TranscriptionsSelection()
            selection.ids = Set(meetings.map(\.id))
            let sut = window(over: controller, scopeRoot: harness.outputDir, selection: selection)

            try menuItem(item, of: sut, for: selection.ids).tap()
            var restored = false
            harness.fakeTrash.beforeMove = { _ in
                guard !restored else { return }
                restored = true
                do { try FileManager.default.moveItem(at: aside, to: track) } catch { XCTFail("could not put the file back: \(error)") }
            }
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

            XCTAssertTrue(restored, "test premise: the file comes back during the first meeting's move")
            XCTAssertFalse(harness.fakeTrash.moved.contains(track.lastPathComponent), "\(item) moved a file the dialog did not count")
            XCTAssertTrue(FileManager.default.fileExists(atPath: track.path))
            XCTAssertNil(controller.meetingFileStore.record(for: laterID)?.pending)
            XCTAssertNoThrow(try sut.inspect().find(text: Self.severalStoppedAfterOne))
            XCTAssertEqual(selection.ids, [laterID], "the meeting not acted on stays selected, to ask again")
            XCTAssertEqual(harness.deletedForGood, [])
        }
    }

    /// A file the Trash refuses stops its own meeting only: that row stays as "Deletion
    /// incomplete" with Retry Deletion, and the others go through (R5, R6).
    func testAMeetingThatFailsInTheBatchStaysAsDeletionIncomplete() throws {
        let cases: [(item: String, others: (PipelineController, UUID) -> Bool)] = [
            (A11yID.recordingsSelectionMoveAudioToTrash, { controller, id in
                controller.meetingFileStore.record(for: id)?.audioDeletion != nil
            }),
            (A11yID.recordingsSelectionMoveMeetingToTrash, { controller, id in
                !controller.transcriptionEntries.contains { $0.id == id }
            }),
        ]
        for testCase in cases {
            let harness = try makeSelectionHarness()
            let controller = harness.controller(queue: harness.makeQueue())
            let fine = try harness.recordedMeeting()
            let refused = try harness.recordedMeeting()
            let refusedName = try XCTUnwrap(refused.appPath).lastPathComponent
            harness.fakeTrash.refusal = { $0.lastPathComponent == refusedName ? CocoaError(.featureUnsupported) : nil }
            let selection = TranscriptionsSelection()
            selection.ids = [fine.id, refused.id]
            let sut = window(over: controller, scopeRoot: harness.outputDir, selection: selection)

            try menuItem(testCase.item, of: sut, for: selection.ids).tap()
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

            XCTAssertTrue(testCase.others(controller, fine.id))
            XCTAssertEqual(controller.meetingFileStore.record(for: refused.id)?.incomplete?.reason, "this volume has no Trash")
            let after = window(over: controller, scopeRoot: harness.outputDir, selection: selection)
            XCTAssertNoThrow(try after.inspect().find(text: "Deletion incomplete: this volume has no Trash"))
            XCTAssertNoThrow(try after.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingRetryDeletionButton(
                controller.transcriptionEntries.firstIndex { $0.id == refused.id } ?? -1,
            )))
        }
    }

    /// What the plan offers, the controller's actions accept: one action per meeting it
    /// applies to, and none of the others ever moves a file.
    func testAMixedSelectionMovesExactlyWhatThePlanSays() throws {
        let harness = try makeSelectionHarness()
        let queue = harness.makeQueue()
        let controller = harness.controller(queue: queue)
        let plain = try harness.recordedMeeting()
        let kept = try harness.recordedMeeting()
        XCTAssertTrue(controller.setKeep(jobID: kept.id, true), "test premise")
        let imported = try harness.importedMeeting()
        let source = try XCTUnwrap(imported.mixPath).path
        let selection = TranscriptionsSelection()
        selection.ids = [plain.id, kept.id, imported.id]
        let sut = window(over: controller, scopeRoot: harness.outputDir, selection: selection)

        try menuItem(A11yID.recordingsSelectionMoveMeetingToTrash, of: sut, for: selection.ids).tap()
        let message = try trashAlert(in: sut).message().text().string()
        XCTAssertTrue(message.contains("“Budget review” is marked Keep."), message)
        XCTAssertTrue(message.contains("Imported files stay where they are."), message)
        try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

        XCTAssertEqual(controller.transcriptionEntries, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source), "an imported file stays")
        XCTAssertEqual(harness.fakeTrash.moved.count, 5 + 5 + 2)
        XCTAssertEqual(harness.deletedForGood, [])
    }

    static let severalNothingMoved =
        "Nothing was moved: the files of a selected meeting changed while the dialog was open. Choose the action again to see what it moves now."
    static let severalStoppedAfterOne =
        "Stopped after 1 of 2 meetings: the files of the next one changed meanwhile. Choose the action again to see what it moves now."
}
