@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The rows' audio line, Keep, the two Trash items with their confirmation and Retry
/// Deletion. What each says for which state is covered by `RecordingAudioLineTests`,
/// `RecordingRowActionsTests` and `TrashConfirmationTextTests`; here is whether the
/// row shows it and which action each control reaches.
extension TranscriptionsViewTests {
    typealias Meeting = RecordingRowActions.Meeting
    typealias AudioOnDisk = RecordingAudioLine.AudioOnDisk

    static let threeTracks = AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 48_000_000)
    static let noAudioLeft = AudioOnDisk(presentCount: 0, unreachableCount: 0, totalCount: 3, bytes: 0)
    static let unpluggedAudio = AudioOnDisk(presentCount: 0, unreachableCount: 3, totalCount: 3, bytes: 0)
    static let nothingMoved = "Nothing was moved: the meeting's files changed while the dialog was open. Choose the action again to see what it moves now."

    /// Each Trash item of a first row, and what confirming it calls.
    static func trashItems(_ row: TranscriptionEntry) -> [(item: String, call: String)] {
        [
            (A11yID.recordingMenuMoveAudioToTrash(0), "moveAudioToTrash \(row.id)"),
            (A11yID.recordingMenuMoveMeetingToTrash(0), "moveMeetingToTrash \(row.id)"),
        ]
    }

    /// What `RecordingRowActions` says the row's menu may offer now.
    static func isDisabled(_ item: RecordingRowActions.RowMenuItem) -> Bool {
        switch item {
        case let .item(item): item == .regenerate(enabled: false)
        case let .keep(_, enabled), let .moveAudioToTrash(enabled), let .moveMeetingToTrash(enabled): !enabled
        }
    }

    /// A finished meeting's record: its tracks, a transcript and its notes.
    func meeting(
        _ entry: TranscriptionEntry, origin: MeetingFileRecord.Origin = .recorded, exporting: Bool = false,
        audio: AudioOnDisk = threeTracks, change: (inout MeetingFileRecord) -> Void = { _ in },
    ) -> Meeting {
        let listed: [(role: MeetingFile.Role, name: String)] = [
            (.mix, "mix.wav"), (.appTrack, "app.wav"), (.micTrack, "mic.wav"), (.transcript, "text.txt"), (.protocol, "notes.md"),
        ]
        var record = MeetingFileRecord(
            jobID: entry.id, origin: origin, recordingDate: Date(timeIntervalSinceReferenceDate: 780_000_000),
            files: listed.map { file in
                MeetingFile(role: file.role, path: "/rec/\(entry.id)_\(file.name)", identity: nil, owned: origin.owns(file.role), state: .present)
            },
            createdBy: RetentionFixture.thisBuild,
        )
        record.outcome = .finished(protocolExpected: true)
        change(&record)
        return Meeting(record: record, notionExportRunning: exporting, audio: audio)
    }

    /// A window whose rows have these meetings, the rest no record. Every meeting
    /// with a record is in this build's retention registry, its notes written.
    private func actions(
        _ meetings: [(entry: TranscriptionEntry, meeting: Meeting)], retention: RecordingRetentionSettings = .init(enabled: false, days: 30),
        base: AllRecordingsActions = .noop,
    ) -> AllRecordingsActions {
        var actions = base
        actions.filesOnDisk = { Self.recordedFilesOnDisk($0) }
        actions.meetingFiles = { id in meetings.first { $0.entry.id == id }?.meeting.record }
        actions.audioOnDisk = { entry in meetings.first { $0.entry.id == entry.id }?.meeting.audio }
        actions.retention = { retention }
        actions.retainedRecording = { id in
            guard meetings.contains(where: { $0.entry.id == id }) else { return nil }
            let recorded = Date(timeIntervalSinceReferenceDate: 780_000_000)
            return RetainedRecording(
                jobID: id, paths: [], root: URL(fileURLWithPath: "/rec"), recordedAt: recorded, eligibleAt: recorded, outputPath: nil,
            )
        }
        actions.bundleID = RetentionFixture.thisBuild
        return actions
    }

    private func finished(_ title: String = "Retro") -> TranscriptionEntry {
        entry(title, protocolPath: "/out/\(title).md", transcriptPath: "/out/\(title).txt")
    }

    func texts(in view: TranscriptionsView) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func keepToggle(_ index: Int, in view: TranscriptionsView) throws -> InspectableView<ViewType.Toggle> {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingMenuKeep(index)).toggle()
    }

    func trashAlert(in view: TranscriptionsView) throws -> InspectableView<ViewType.Alert> {
        try view.inspect().find(ViewType.Alert.self)
    }

    func tapInTrashAlert(_ identifier: String, in view: TranscriptionsView) throws {
        try trashAlert(in: view).actions().find(viewWithAccessibilityIdentifier: identifier).button().tap()
    }

    // MARK: - Audio line and Keep badge

    /// The line for a recorded row, by the setting the window was handed; a kept
    /// meeting's badge after its title; a drive that is not connected keeps the items;
    /// a row without a record has no line, no badge and none of the three items.
    func testARowShowsItsAudioLineAndBadgeFromItsRecord() throws {
        let plain = finished("Plain")
        let due = finished("Due")
        let kept = finished("Kept")
        let unplugged = finished("Unplugged")
        let noRecord = finished("No record")
        let withLine = [
            (entry: plain, meeting: meeting(plain) { $0.excludedFromAutomaticDeletion = true }),
            (entry: due, meeting: meeting(due)),
            (entry: kept, meeting: meeting(kept) { $0.keep = true }),
            (entry: unplugged, meeting: meeting(unplugged, audio: Self.unpluggedAudio)),
        ]
        let sut = makeView([plain, due, kept, unplugged, noRecord], actions: actions(withLine, retention: .init(enabled: true, days: 30)))

        let shown = try texts(in: sut).filter { $0.hasPrefix("Audio") }
        XCTAssertEqual(shown, [
            "Audio · 48 MB",
            "Audio · 48 MB · deleted automatically at the next check",
            "Audio · 48 MB · kept, never deleted automatically",
            "Audio · on a drive that is not connected",
        ])

        let badge = try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingKeepBadge(2)).text()
        XCTAssertEqual(try badge.string(), "Keep")
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingKeepBadge(0)))

        XCTAssertFalse(try keepToggle(3, in: sut).isDisabled())
        XCTAssertFalse(try button(A11yID.recordingMenuMoveAudioToTrash(3), in: sut).isDisabled())
        XCTAssertFalse(try button(A11yID.recordingMenuMoveMeetingToTrash(3), in: sut).isDisabled())

        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingKeepBadge(4)))
        XCTAssertThrowsError(try keepToggle(4, in: sut))
        XCTAssertThrowsError(try button(A11yID.recordingMenuMoveAudioToTrash(4), in: sut))
        XCTAssertThrowsError(try button(A11yID.recordingMenuMoveMeetingToTrash(4), in: sut))
    }

    /// A meeting the queue still lists is judged by the row's live state and export,
    /// over what its record says.
    func testTheLineAndTheItemsTakeTheRowsLiveExportAndState() throws {
        var job = PipelineJob(
            meetingTitle: "Exporting", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/x_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        job.protocolPath = URL(fileURLWithPath: "/out/x.md")
        job.beginNotionExport(speakerNames: [])
        let exporting = TranscriptionEntry(job: job, finishOrder: nil)
        let naming = entry("Naming", state: .speakerNamingPending, transcriptPath: "/out/n.txt")
        let meetings = [
            (entry: exporting, meeting: meeting(exporting)),
            (entry: naming, meeting: meeting(naming)),
        ]
        let sut = makeView([exporting, naming], actions: actions(meetings, retention: .init(enabled: true, days: 30)))

        XCTAssertEqual(try texts(in: sut).filter { $0.hasPrefix("Audio") }, [
            "Audio · 48 MB · deleted automatically at the next check",
            "Audio · 48 MB · kept until the speakers are named",
        ])
        for index in 0 ... 1 {
            XCTAssertTrue(try keepToggle(index, in: sut).isDisabled())
            XCTAssertTrue(try button(A11yID.recordingMenuMoveAudioToTrash(index), in: sut).isDisabled())
            XCTAssertTrue(try button(A11yID.recordingMenuMoveMeetingToTrash(index), in: sut).isDisabled())
        }
    }

    /// The window stays open and the store changes the record: the body asked for it,
    /// so SwiftUI redraws, and the redraw shows the new line.
    func testARecordChangedWhileTheWindowIsOpenUpdatesTheRow() throws {
        let row = finished()
        let folder = try makeTempDirectory(prefix: "transcriptions_view_test")
        let track = folder.appendingPathComponent("mix.wav")
        try Data(count: 48_000_000).write(to: track)
        let store = MeetingFileStore(path: folder.appendingPathComponent("records/meeting_files.json"))
        var created = MeetingFileRecord(
            jobID: row.id, origin: .recorded, recordingDate: nil, files: [MeetingFile(role: .mix, url: track, owned: true)],
        )
        created.outcome = .finished(protocolExpected: false)
        XCTAssertTrue(store.create(created), "test premise")
        var actions = actions([])
        actions.meetingFiles = { store.record(for: $0) }
        actions.audioOnDisk = { entry in
            store.record(for: entry.id).map { AllRecordingsActions.readAudioOnDisk(of: $0, scopeRoot: folder) }
        }
        let sut = makeView([row], actions: actions)

        let redraw = expectation(description: "the row's next draw is asked for")
        let before = withObservationTracking {
            (try? texts(in: sut).filter { $0.hasPrefix("Audio") }) ?? []
        } onChange: {
            redraw.fulfill()
        }
        XCTAssertEqual(before, ["Audio · 48 MB"])
        XCTAssertNoThrow(try button(A11yID.recordingMenuMoveAudioToTrash(0), in: sut))

        try FileManager.default.removeItem(at: track)
        store.update(jobID: row.id) { record in
            record.files[0].state = .gone
            record.audioDeletion = .init(kind: .automatic, at: Date())
        }

        wait(for: [redraw], timeout: 0)
        let line = try XCTUnwrap(texts(in: sut).first { $0.hasPrefix("Audio") })
        XCTAssertTrue(line.hasPrefix("Audio deleted automatically on "), line)
        XCTAssertThrowsError(try button(A11yID.recordingMenuMoveAudioToTrash(0), in: sut), "no audio left to move")
    }

    // MARK: - Keep

    /// Keep shows its check mark when kept, and hands its action the toggled value.
    func testKeepCallsSetKeepWithTheToggledValue() throws {
        let unkept = finished("Unkept")
        let kept = finished("Kept")
        var calls: [String] = []
        let sut = makeView(
            [unkept, kept],
            actions: actions(
                [(unkept, meeting(unkept)), (kept, meeting(kept) { $0.keep = true })],
                base: recording { calls.append($0) },
            ),
        )
        XCTAssertEqual(try keepToggle(0, in: sut).labelView().text().string(), "Keep (Never Delete Automatically)")
        XCTAssertFalse(try keepToggle(0, in: sut).isOn())
        XCTAssertTrue(try keepToggle(1, in: sut).isOn())

        try keepToggle(0, in: sut).tap()
        try keepToggle(1, in: sut).tap()

        XCTAssertEqual(calls, ["setKeep \(unkept.id) true", "setKeep \(kept.id) false"])
    }

    // MARK: - Trash confirmations

    /// Each Trash item only asks, with the text of its own decision. Cancel changes
    /// nothing; confirming runs the action on the row's meeting and closes the dialog.
    func testEachTrashItemAsksFirstAndOnlyConfirmingRunsIt() throws {
        let row = finished()
        let other = finished("Other")
        let record = meeting(row)
        let onDisk = Self.recordedFilesOnDisk(row)
        let cases: [(item: String, label: String, text: TrashConfirmationText, call: String)] = [
            (
                A11yID.recordingMenuMoveAudioToTrash(1), "Move Audio to Trash…",
                TrashConfirmationText.moveAudio(
                    meetingTitle: row.title, record: record.record, audio: record.audio, transcriptSource: onDisk.transcriptSource,
                ),
                "moveAudioToTrash \(row.id)",
            ),
            (
                A11yID.recordingMenuMoveMeetingToTrash(1), "Move Meeting to Trash…",
                TrashConfirmationText.moveMeeting(
                    meetingTitle: row.title, record: record.record, audio: record.audio, hasNotionPage: false, hasFailedExport: false,
                ),
                "moveMeetingToTrash \(row.id)",
            ),
        ]
        for testCase in cases {
            var calls: [String] = []
            let sut = makeView(
                [other, row],
                actions: actions([(other, meeting(other)), (row, record)], base: recording { calls.append($0) }),
            )
            XCTAssertThrowsError(try trashAlert(in: sut), "a dialog before any click")

            let item = try button(testCase.item, in: sut)
            XCTAssertEqual(try item.labelView().text().string(), testCase.label)
            try item.tap()
            XCTAssertEqual(calls, [], testCase.label)
            let alert = try trashAlert(in: sut)
            XCTAssertEqual(try alert.title().string(), testCase.text.title)
            XCTAssertEqual(try alert.message().text().string(), testCase.text.lines.joined(separator: "\n\n"))
            let confirm = try alert.actions().find(viewWithAccessibilityIdentifier: A11yID.recordingTrashConfirmButton).button()
            XCTAssertEqual(try confirm.labelView().text().string(), "Move to Trash")
            XCTAssertEqual(try confirm.role(), .destructive)
            let cancel = try alert.actions().find(viewWithAccessibilityIdentifier: A11yID.recordingTrashCancelButton).button()
            XCTAssertEqual(try cancel.labelView().text().string(), "Cancel")
            XCTAssertEqual(try cancel.role(), .cancel)

            try tapInTrashAlert(A11yID.recordingTrashCancelButton, in: sut)
            XCTAssertThrowsError(try trashAlert(in: sut), testCase.label)
            XCTAssertEqual(calls, [], testCase.label)

            try button(testCase.item, in: sut).tap()
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)
            XCTAssertEqual(calls, [testCase.call])
            XCTAssertThrowsError(try trashAlert(in: sut), testCase.label)
        }
    }

    /// The dialog reads the row: a file the disk answered gone, what the regenerator
    /// could read, the Notion page and a failed export each change what it says.
    func testTheConfirmationIsBuiltFromWhatTheRowFound() throws {
        var job = PipelineJob(
            meetingTitle: "Exported", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/x_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        job.protocolPath = URL(fileURLWithPath: "/out/x.md")
        job.recordNotionPage(NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"), databaseID: "db")
        job.finishNotionExport(succeeded: true)
        let exported = TranscriptionEntry(job: job, finishOrder: nil)
        job.beginNotionExport(speakerNames: [])
        job.finishNotionExport(succeeded: false)
        let failedExport = TranscriptionEntry(job: job, finishOrder: nil)
        var noPageJob = PipelineJob(
            meetingTitle: "No page", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/rec/y_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        noPageJob.state = .done
        noPageJob.protocolPath = URL(fileURLWithPath: "/out/y.md")
        noPageJob.beginNotionExport(speakerNames: [])
        noPageJob.finishNotionExport(succeeded: false)
        let failedBeforeAPage = TranscriptionEntry(job: noPageJob, finishOrder: nil)
        var gone = meeting(failedExport)
        gone = Meeting(
            record: gone.record, notionExportRunning: false,
            audio: AudioOnDisk(presentCount: 2, unreachableCount: 0, totalCount: 3, bytes: 1000, gonePaths: ["/rec/\(failedExport.id)_mic.wav"]),
        )

        var audioActions = actions([(failedExport, gone)])
        audioActions.filesOnDisk = { _ in FilesOnDisk(protocolExists: true, transcriptExists: false, transcriptSource: .none) }
        let moveAudio = makeView([failedExport], actions: audioActions)
        try button(A11yID.recordingMenuMoveAudioToTrash(0), in: moveAudio).tap()
        XCTAssertEqual(
            try trashAlert(in: moveAudio).message().text().string(),
            TrashConfirmationText.moveAudio(
                meetingTitle: failedExport.title, record: gone.record, audio: gone.audio, transcriptSource: .none,
            ).lines.joined(separator: "\n\n"),
        )

        // A failed export can leave its page behind, which nothing opens but which stays.
        for (row, page, failed) in [(exported, true, false), (failedExport, true, true), (failedBeforeAPage, false, true)] {
            let meeting = meeting(row)
            let sut = makeView([row], actions: actions([(row, meeting)]))
            try button(A11yID.recordingMenuMoveMeetingToTrash(0), in: sut).tap()
            XCTAssertEqual(
                try trashAlert(in: sut).message().text().string(),
                TrashConfirmationText.moveMeeting(
                    meetingTitle: row.title, record: meeting.record, audio: meeting.audio, hasNotionPage: page, hasFailedExport: failed,
                ).lines.joined(separator: "\n\n"),
                row.title,
            )
        }
    }

    /// Answering a dialog reads the rows' files again at the next draw.
    func testConfirmingReadsTheRowsFilesAgain() throws {
        let row = finished()
        var fileReads = 0
        var audioReads = 0
        var actions = actions([(row, meeting(row))])
        let readFiles = actions.filesOnDisk
        let readAudio = actions.audioOnDisk
        actions.filesOnDisk = { entry in
            fileReads += 1
            return readFiles(entry)
        }
        actions.audioOnDisk = { entry in
            audioReads += 1
            return readAudio(entry)
        }
        let sut = makeView([row], actions: actions)
        _ = try sut.inspect().find(text: "Retro")
        XCTAssertEqual([fileReads, audioReads], [1, 1])

        try button(A11yID.recordingMenuMoveAudioToTrash(0), in: sut).tap()
        try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)
        XCTAssertEqual([fileReads, audioReads], [1, 2], "the confirmation checks the audio itself")
        _ = try sut.inspect().find(text: "Retro")

        XCTAssertEqual([fileReads, audioReads], [2, 3])
    }

    /// A dialog answers for the files it named, and fewer is no harm: a file gone since
    /// it opened does not stop the rest.
    func testConfirmingStillRunsWhenAFileWentSinceTheDialogOpened() throws {
        let row = finished()
        let mic = "/rec/\(row.id)_mic.wav"
        for (item, call) in Self.trashItems(row) {
            var gone: Set<String> = []
            var calls: [String] = []
            var actions = actions([(row, meeting(row))], base: recording { calls.append($0) })
            actions.audioOnDisk = { _ in AudioOnDisk(presentCount: 3, unreachableCount: 0, totalCount: 3, bytes: 1000, gonePaths: gone) }
            let sut = makeView([row], actions: actions)

            try button(item, in: sut).tap()
            gone = [mic]
            try tapInTrashAlert(A11yID.recordingTrashConfirmButton, in: sut)

            XCTAssertEqual(calls, [call])
            XCTAssertThrowsError(try sut.inspect().find(text: Self.nothingMoved))
        }
    }

    // MARK: - Retry Deletion

    /// A row whose deletion stopped: its reason replaces the status line, and
    /// "Retry Deletion" replaces the row's usual button and hands it the row's job.
    func testRetryDeletionIsTheMainButtonWhileADeletionIsIncomplete() throws {
        let row = finished()
        let stopped = meeting(row, audio: AudioOnDisk(presentCount: 1, unreachableCount: 0, totalCount: 3, bytes: 1000)) { record in
            record.incomplete = .init(reason: "this volume has no Trash", paths: ["/rec/a"], kind: .audioToTrash)
        }
        var calls: [String] = []
        let sut = makeView([row], actions: actions([(row, stopped)], base: recording { calls.append($0) }))

        let retry = try button(A11yID.recordingRetryDeletionButton(0), in: sut)
        XCTAssertEqual(try retry.labelView().text().string(), "Retry Deletion")
        XCTAssertThrowsError(try button(A11yID.recordingMainButton(0), in: sut), "the usual button stays out")
        XCTAssertNoThrow(try sut.inspect().find(text: "Deletion incomplete: this volume has no Trash"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Audio · 2 of 3 files moved to the Trash"))
        let status = JobMenuSummary.status(state: row.state, hasWarnings: false, progress: row.state.label)
        XCTAssertThrowsError(try sut.inspect().find(text: status), "the status line gives way")
        XCTAssertNoThrow(try makeView([row], actions: actions([(row, meeting(row))])).inspect().find(text: status), "test premise")
        try retry.tap()

        XCTAssertEqual(calls, ["retryDeletion \(row.id)"])
    }

    // MARK: - A regeneration

    /// A run writes its meeting's notes when it ends, and once the record is gone
    /// nothing lists that file. So what removes a whole meeting waits; what leaves
    /// its record in place does not.
    func testWhileARegenerationRunsNothingRemovesAWholeMeeting() throws {
        let plain = finished("Plain")
        let halfMoved = finished("Half moved")
        let audioStopped = finished("Audio stopped")
        let stopped = { (kind: MeetingFileRecord.DeletionKind) in
            { (record: inout MeetingFileRecord) in
                record.incomplete = .init(reason: "reason", paths: [], kind: kind)
            }
        }
        let meetings = [
            (entry: plain, meeting: meeting(plain)),
            (entry: halfMoved, meeting: meeting(halfMoved, change: stopped(.meetingToTrash))),
            (entry: audioStopped, meeting: meeting(audioStopped, change: stopped(.audioToTrash))),
        ]
        for (phase, regenerating) in [(ProtocolRegenerator.Phase.running, true), (.idle, false), (.failed("reason"), false)] {
            let sut = makeView(
                meetings.map(\.entry), actions: actions(meetings), regenerationPhase: phase,
            )

            XCTAssertEqual(try button(A11yID.recordingMenuMoveMeetingToTrash(0), in: sut).isDisabled(), regenerating, "\(phase)")
            XCTAssertEqual(try button(A11yID.recordingRetryDeletionButton(1), in: sut).isDisabled(), regenerating, "\(phase)")
            XCTAssertFalse(try button(A11yID.recordingMenuMoveAudioToTrash(0), in: sut).isDisabled(), "\(phase)")
            XCTAssertFalse(try keepToggle(0, in: sut).isDisabled(), "\(phase)")
            XCTAssertFalse(try button(A11yID.recordingRetryDeletionButton(2), in: sut).isDisabled(), "\(phase)")
        }
    }

    // MARK: - Privacy

    /// The new controls and the dialog carry a row's index or nothing: never its title
    /// or a file name, which the dialog's text is full of.
    func testNoNewIdentifierCarriesATitleOrPath() throws {
        let row = finished("Board Meeting")
        let meeting = meeting(row) { $0.keep = true }
        let sut = makeView([row], actions: actions([(row, meeting)]))
        try button(A11yID.recordingMenuMoveAudioToTrash(0), in: sut).tap()

        let identifiers = try sut.inspect()
            .findAll { (try? $0.accessibilityIdentifier()) != nil }
            .map { try $0.accessibilityIdentifier() }

        XCTAssertEqual(Set(identifiers), [
            A11yID.transcriptionsSearchField,
            A11yID.recordingsOpenFolderButton,
            A11yID.recordingsRegenerateFromFileButton,
            A11yID.transcriptionsFooter,
            A11yID.recordingKeepBadge(0),
            A11yID.recordingMainButton(0),
            A11yID.recordingMoreButton(0),
            A11yID.recordingMenuOpenProtocol(0),
            A11yID.recordingMenuOpenTranscript(0),
            A11yID.recordingMenuShowInFinder(0),
            A11yID.recordingMenuRegenerate(0),
            A11yID.recordingMenuKeep(0),
            A11yID.recordingMenuMoveAudioToTrash(0),
            A11yID.recordingMenuMoveMeetingToTrash(0),
            A11yID.recordingTrashCancelButton,
            A11yID.recordingTrashConfirmButton,
        ])
    }
}
