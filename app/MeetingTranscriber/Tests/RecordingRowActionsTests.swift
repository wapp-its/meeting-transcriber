@testable import MeetingTranscriber
import XCTest

/// The All Recordings window's row decision: the one main button (R6) and the
/// "…" menu (R7) for every job state, crossed with the three transcript
/// sources the regenerator reads and with the files present, missing and
/// present but unusable (R10).
final class RecordingRowActionsTests: XCTestCase {
    private typealias MainAction = RecordingRowActions.MainAction
    private typealias MenuItem = RecordingRowActions.MenuItem
    private typealias RecordedFiles = RecordingRowActions.RecordedFiles
    private typealias FilesOnDisk = RecordingRowActions.FilesOnDisk

    /// The states a job waits or runs in. With `.speakerNamingPending`,
    /// `.done` and `.error` below, every `JobState` case.
    private let liveStates: [JobState] = [.waiting, .transcribing, .diarizing, .generatingProtocol]
    private let eitherRetry = [true, false]

    private let everyRecordedFiles = [
        RecordedFiles(hasProtocol: true, hasTranscript: true),
        RecordedFiles(hasProtocol: true, hasTranscript: false),
        RecordedFiles(hasProtocol: false, hasTranscript: true),
        RecordedFiles(hasProtocol: false, hasTranscript: false),
    ]

    // MARK: - Files on disk

    /// The usual finished meeting: both files, the transcript readable.
    private let protocolAndTranscript = FilesOnDisk(
        protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile,
    )
    /// "Save raw transcript separately" off: the `.txt` was deleted after the
    /// job, and the protocol holds the full transcript.
    private let protocolHoldingTranscript = FilesOnDisk(
        protocolExists: true, transcriptExists: false, transcriptSource: .protocolOnly,
    )
    /// The `.txt` is missing and the protocol has no full transcript in it.
    private let protocolWithoutTranscript = FilesOnDisk(
        protocolExists: true, transcriptExists: false, transcriptSource: .none,
    )
    /// No protocol (generation off, or it failed), the transcript readable.
    private let transcriptOnly = FilesOnDisk(
        protocolExists: false, transcriptExists: true, transcriptSource: .transcriptFile,
    )
    /// Both files missing on disk.
    private let neither = FilesOnDisk(
        protocolExists: false, transcriptExists: false, transcriptSource: .none,
    )
    /// A blank or non-UTF-8 `.txt` and no protocol: the file can be opened,
    /// but the regenerator has nothing to send.
    private let unusableTranscript = FilesOnDisk(
        protocolExists: false, transcriptExists: true, transcriptSource: .none,
    )
    /// A blank or non-UTF-8 `.txt` next to a protocol holding the full
    /// transcript, which the regenerator falls back to.
    private let unusableTranscriptBesideFullProtocol = FilesOnDisk(
        protocolExists: true, transcriptExists: true, transcriptSource: .protocolOnly,
    )

    private var everyOnDisk: [FilesOnDisk] {
        [
            protocolAndTranscript, protocolHoldingTranscript, protocolWithoutTranscript, transcriptOnly,
            neither, unusableTranscript, unusableTranscriptBesideFullProtocol,
        ]
    }

    // MARK: - Helpers

    private func assertMainAction(
        states: [JobState], files: [RecordedFiles], canRetry: [Bool], _ expected: MainAction?,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        for state in states {
            for recorded in files {
                for retry in canRetry {
                    XCTAssertEqual(
                        RecordingRowActions.mainAction(state: state, files: recorded, canRetry: retry), expected,
                        "\(state), \(recorded), canRetry \(retry)", file: file, line: line,
                    )
                }
            }
        }
    }

    /// Each row's exact list, which pins the order and that no item appears twice.
    private func assertMenu(
        states: [JobState], canRetry: [Bool], _ rows: [(onDisk: FilesOnDisk, expected: [MenuItem])],
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        for state in states {
            for retry in canRetry {
                for row in rows {
                    XCTAssertEqual(
                        RecordingRowActions.menuItems(state: state, onDisk: row.onDisk, canRetry: retry), row.expected,
                        "\(state), \(row.onDisk), canRetry \(retry)", file: file, line: line,
                    )
                }
            }
        }
    }

    // MARK: - Main button (R6)

    func testMainActionCancelsAWaitingOrRunningJob() {
        assertMainAction(states: liveStates, files: everyRecordedFiles, canRetry: eitherRetry, .cancel)
    }

    func testMainActionNamesSpeakersWhileNamesAreAwaited() {
        assertMainAction(states: [.speakerNamingPending], files: everyRecordedFiles, canRetry: eitherRetry, .nameSpeakers)
    }

    /// The recorded files decide, not the disk: a file deleted since still
    /// gets its button and fails with "The file was moved or deleted.". A
    /// finished job that recorded neither file has no main button (R6's error
    /// case).
    func testMainActionOfAFinishedJobOpensItsProtocolElseItsTranscriptElseNothing() {
        assertMainAction(
            states: [.done], files: [RecordedFiles(hasProtocol: true, hasTranscript: true)], canRetry: eitherRetry,
            .openProtocol,
        )
        assertMainAction(
            states: [.done], files: [RecordedFiles(hasProtocol: true, hasTranscript: false)], canRetry: eitherRetry,
            .openProtocol,
        )
        assertMainAction(
            states: [.done], files: [RecordedFiles(hasProtocol: false, hasTranscript: true)], canRetry: eitherRetry,
            .openTranscript,
        )
        assertMainAction(
            states: [.done], files: [RecordedFiles(hasProtocol: false, hasTranscript: false)], canRetry: eitherRetry,
            nil,
        )
    }

    /// A finished job whose notes went only to Notion opens its page; a
    /// recorded file still wins, since the button names what it opens.
    func testMainActionOfAFinishedJobWithOnlyANotionPageOpensThePage() {
        assertMainAction(
            states: [.done], files: [RecordedFiles(hasProtocol: false, hasTranscript: false, hasNotionPage: true)],
            canRetry: eitherRetry, .openInNotion,
        )
        assertMainAction(
            states: [.done], files: [RecordedFiles(hasProtocol: true, hasTranscript: false, hasNotionPage: true)],
            canRetry: eitherRetry, .openProtocol,
        )
        assertMainAction(
            states: [.done], files: [RecordedFiles(hasProtocol: false, hasTranscript: true, hasNotionPage: true)],
            canRetry: eitherRetry, .openTranscript,
        )
    }

    func testMainActionOfAFailedJobIsRetryWhenThePipelineWouldTakeItElseRemove() {
        assertMainAction(states: [.error], files: everyRecordedFiles, canRetry: [true], .retry)
        assertMainAction(states: [.error], files: everyRecordedFiles, canRetry: [false], .remove)
    }

    // MARK: - "…" menu (R7)

    /// A waiting or running job lists nothing, whatever is on disk.
    func testMenuOfALiveJobIsEmpty() {
        assertMenu(states: liveStates, canRetry: eitherRetry, everyOnDisk.map { ($0, []) })
    }

    func testMenuWhileNamesAreAwaitedListsTheFilesOnDiskThenDismiss() {
        assertMenu(states: [.speakerNamingPending], canRetry: eitherRetry, [
            (protocolAndTranscript, [.openProtocol, .openTranscript, .showInFinder, .dismiss]),
            (protocolHoldingTranscript, [.openProtocol, .showInFinder, .dismiss]),
            (protocolWithoutTranscript, [.openProtocol, .showInFinder, .dismiss]),
            (transcriptOnly, [.openTranscript, .showInFinder, .dismiss]),
            (neither, [.dismiss]),
            (unusableTranscript, [.openTranscript, .showInFinder, .dismiss]),
            (unusableTranscriptBesideFullProtocol, [.openProtocol, .openTranscript, .showInFinder, .dismiss]),
        ])
    }

    /// A file missing on disk leaves its item out, and Show in Finder goes
    /// with the last of them. Regenerate is always listed and disabled exactly
    /// when the regenerator has no source: an existing but blank transcript
    /// alone does not enable it, the protocol's full transcript does. With
    /// neither file the menu holds only the disabled Regenerate.
    func testMenuOfAFinishedJobLeavesOutMissingFilesAndDisablesRegenerateWithoutASource() {
        assertMenu(states: [.done], canRetry: eitherRetry, [
            (protocolAndTranscript, [.openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true)]),
            (protocolHoldingTranscript, [.openProtocol, .showInFinder, .regenerate(enabled: true)]),
            (protocolWithoutTranscript, [.openProtocol, .showInFinder, .regenerate(enabled: false)]),
            (transcriptOnly, [.openTranscript, .showInFinder, .regenerate(enabled: true)]),
            (neither, [.regenerate(enabled: false)]),
            (unusableTranscript, [.openTranscript, .showInFinder, .regenerate(enabled: false)]),
            (
                unusableTranscriptBesideFullProtocol,
                [.openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true)],
            ),
        ])
    }

    /// A finished job with a Notion page lists "Open in Notion" after its
    /// files and before Regenerate, also when no file is left.
    func testMenuOfAFinishedJobWithANotionPageListsItAfterTheFiles() {
        for retry in eitherRetry {
            XCTAssertEqual(
                RecordingRowActions.menuItems(state: .done, onDisk: protocolAndTranscript, canRetry: retry, hasNotionPage: true),
                [.openProtocol, .openTranscript, .showInFinder, .openInNotion, .regenerate(enabled: true)],
            )
            XCTAssertEqual(
                RecordingRowActions.menuItems(state: .done, onDisk: neither, canRetry: retry, hasNotionPage: true),
                [.openInNotion, .regenerate(enabled: false)],
            )
        }
    }

    /// Regenerate appears on a failed job only when there is a source, Retry
    /// only when the pipeline would take it, Remove always, last.
    func testMenuOfARetryableFailedJobListsRegenerateOnlyWithASourceThenRetryAndRemove() {
        assertMenu(states: [.error], canRetry: [true], [
            (
                protocolAndTranscript,
                [.openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true), .retry, .remove],
            ),
            (protocolHoldingTranscript, [.openProtocol, .showInFinder, .regenerate(enabled: true), .retry, .remove]),
            (protocolWithoutTranscript, [.openProtocol, .showInFinder, .retry, .remove]),
            (transcriptOnly, [.openTranscript, .showInFinder, .regenerate(enabled: true), .retry, .remove]),
            (neither, [.retry, .remove]),
            (unusableTranscript, [.openTranscript, .showInFinder, .retry, .remove]),
            (
                unusableTranscriptBesideFullProtocol,
                [.openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true), .retry, .remove],
            ),
        ])
    }

    /// The row's main button is then Remove, and the menu repeats it.
    func testMenuOfAFailedJobThatCannotBeRetriedHasRemoveButNoRetry() {
        assertMenu(states: [.error], canRetry: [false], [
            (protocolAndTranscript, [.openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true), .remove]),
            (protocolHoldingTranscript, [.openProtocol, .showInFinder, .regenerate(enabled: true), .remove]),
            (protocolWithoutTranscript, [.openProtocol, .showInFinder, .remove]),
            (transcriptOnly, [.openTranscript, .showInFinder, .regenerate(enabled: true), .remove]),
            (neither, [.remove]),
            (unusableTranscript, [.openTranscript, .showInFinder, .remove]),
            (
                unusableTranscriptBesideFullProtocol,
                [.openProtocol, .openTranscript, .showInFinder, .regenerate(enabled: true), .remove],
            ),
        ])
    }
}

// MARK: - A meeting's files (R4, R5, R6)

/// Keep and the two Trash items, and Retry Deletion as the main button. Every
/// `JobState` crossed with what the row's record says, and against the actions
/// themselves: an item the menu offers is one its action accepts.
extension RecordingRowActionsTests {
    private typealias AudioOnDisk = RecordingAudioLine.AudioOnDisk
    private typealias Fixture = RetentionFixture
    private typealias Meeting = RecordingRowActions.Meeting
    private typealias RowMenuItem = RecordingRowActions.RowMenuItem
    private typealias RowMainAction = RecordingRowActions.RowMainAction
    private typealias Deletion = MeetingFileRecord.DeletionFailure

    /// The states the items stay listed but disabled in (R4).
    private var waitingStates: [JobState] {
        liveStates + [.speakerNamingPending]
    }

    private func audio(present: Int = 3, unreachable: Int = 0) -> AudioOnDisk {
        AudioOnDisk(presentCount: present, unreachableCount: unreachable, totalCount: 3, bytes: Int64(present) * 1000)
    }

    private func meeting(_ record: MeetingFileRecord = RetentionFixture.record(), exporting: Bool = false, audio: AudioOnDisk? = nil) -> Meeting {
        Meeting(record: record, notionExportRunning: exporting, audio: audio ?? self.audio())
    }

    private func incomplete(_ kind: MeetingFileRecord.DeletionKind) -> MeetingFileRecord {
        Fixture.record { $0.incomplete = Deletion(reason: "r", paths: [], kind: kind) }
    }

    /// What `meeting` adds to the row's menu, after asserting that it comes after
    /// everything the row listed without it, unchanged.
    private func added(state: JobState, _ meeting: Meeting?, file: StaticString = #filePath, line: UInt = #line) -> [RowMenuItem] {
        let before = RecordingRowActions.menuItems(state: state, onDisk: protocolAndTranscript, canRetry: true)
            .map(RowMenuItem.item)
        let all = RecordingRowActions.menuItems(state: state, onDisk: protocolAndTranscript, canRetry: true, meeting: meeting)
        XCTAssertEqual(Array(all.prefix(before.count)), before, "\(state)", file: file, line: line)
        return Array(all.dropFirst(before.count))
    }

    private func allThree(enabled: Bool, checked: Bool = false) -> [RowMenuItem] {
        [.keep(checked: checked, enabled: enabled), .moveAudioToTrash(enabled: enabled), .moveMeetingToTrash(enabled: enabled)]
    }

    // MARK: Menu

    func testTheItemsFollowRegenerateInTheMockupsOrder() {
        XCTAssertEqual(
            RecordingRowActions.menuItems(
                state: .done, onDisk: protocolAndTranscript, canRetry: false, meeting: meeting(), hasNotionPage: true,
            ),
            [
                .item(.openProtocol), .item(.openTranscript), .item(.showInFinder), .item(.openInNotion),
                .item(.regenerate(enabled: true)),
                .keep(checked: false, enabled: true), .moveAudioToTrash(enabled: true), .moveMeetingToTrash(enabled: true),
            ],
        )
    }

    /// Each row: what it adds to a finished row, and with `false` to one still
    /// waiting, running or waiting for names. A failed row never lists them (A3).
    func testEveryStateCrossedWithWhatTheRecordSays() {
        let onlyMeeting: (Bool) -> [RowMenuItem] = { [.moveMeetingToTrash(enabled: $0)] }
        let rows: [(String, Meeting?, (Bool) -> [RowMenuItem])] = [
            ("no record (A2)", nil, { _ in [] }),
            ("a finished recording", meeting(), { self.allThree(enabled: $0) }),
            ("kept", meeting(Fixture.record { $0.keep = true }), { self.allThree(enabled: $0, checked: true) }),
            ("an import (A4)", meeting(Fixture.record(origin: .imported)), onlyMeeting),
            ("an import with a copy of the app's", meeting(Fixture.record(origin: .imported) { $0.files.append(Fixture.file(.mix16k, "c.wav")) }), onlyMeeting),
            ("a failed meeting (A3)", meeting(Fixture.record(outcome: .failed)), { _ in [] }),
            ("left the queue unfinished", meeting(Fixture.record(outcome: .leftUnfinished)), { _ in [] }),
            ("no audio left", meeting(audio: audio(present: 0)), onlyMeeting),
            ("audio only out of reach", meeting(audio: audio(present: 0, unreachable: 3)), { self.allThree(enabled: $0) }),
            ("the record lists no audio left", meeting(Fixture.record { $0.setAudio(to: .gone) }), onlyMeeting),
            ("Move Audio incomplete", meeting(incomplete(.audioToTrash)), { self.allThree(enabled: $0) }),
            ("Move Meeting incomplete", meeting(incomplete(.meetingToTrash)), { enabled in
                [.keep(checked: false, enabled: enabled), .moveAudioToTrash(enabled: false), .moveMeetingToTrash(enabled: enabled)]
            }),
        ]
        for (name, meeting, expected) in rows {
            XCTAssertEqual(added(state: .done, meeting), expected(true), name)
            for state in waitingStates {
                XCTAssertEqual(added(state: state, meeting), expected(false), "\(name), \(state)")
            }
            XCTAssertEqual(added(state: .error, meeting), [], name)
        }
    }

    func testAFinishedRowIsDisabledWhileItsActionsWouldRefuse() {
        let rows: [(String, Meeting)] = [
            ("a Notion export running (A9)", meeting(exporting: true)),
            ("a deletion pending", meeting(Fixture.record { $0.pending = .init(kind: .audioToTrash, paths: []) })),
            ("no outcome on the record, another build's run", meeting(Fixture.record(outcome: .inProgress))),
        ]
        for (name, meeting) in rows {
            XCTAssertEqual(added(state: .done, meeting), allThree(enabled: false), name)
        }
    }

    // MARK: Main button

    func testRetryDeletionWinsWhileADeletionIsIncomplete() {
        for kind in [MeetingFileRecord.DeletionKind.audioToTrash, .meetingToTrash] {
            for files in everyRecordedFiles + [RecordedFiles(hasProtocol: false, hasTranscript: false, hasNotionPage: true)] {
                XCTAssertEqual(
                    RecordingRowActions.mainAction(state: .done, files: files, canRetry: true, meeting: meeting(incomplete(kind))),
                    .retryDeletion, "\(kind), \(files)",
                )
            }
        }
    }

    /// The button stays the row's usual one for as long as the retry would refuse,
    /// or it would do nothing and hide "Name Speakers" or "Retry".
    func testTheRowKeepsItsMainButtonWhileARetryWouldRefuse() {
        let files = RecordedFiles(hasProtocol: true, hasTranscript: true)
        for state in waitingStates + [.error] {
            XCTAssertEqual(
                RecordingRowActions.mainAction(state: state, files: files, canRetry: true, meeting: meeting(incomplete(.audioToTrash))),
                RecordingRowActions.mainAction(state: state, files: files, canRetry: true).map(RowMainAction.action), "\(state)",
            )
        }
        let rows: [(String, Meeting)] = [
            ("an export running", meeting(incomplete(.audioToTrash), exporting: true)),
            ("a deletion pending", meeting(Fixture.record { record in
                record.incomplete = Deletion(reason: "r", paths: [], kind: .audioToTrash)
                record.pending = .init(kind: .audioToTrash, paths: [])
            })),
            ("an automatic one", meeting(incomplete(.automatic))),
            ("not finished", meeting(Fixture.record(outcome: .inProgress) { $0.incomplete = Deletion(reason: "r", paths: [], kind: .audioToTrash) })),
            ("nothing incomplete", meeting()),
        ]
        for (name, meeting) in rows {
            XCTAssertEqual(
                RecordingRowActions.mainAction(state: .done, files: files, canRetry: true, meeting: meeting), .action(.openProtocol), name,
            )
        }
    }

    func testARowWithoutARecordKeepsItsMainButton() {
        for state in liveStates + [.speakerNamingPending, .done, .error] {
            for files in everyRecordedFiles {
                XCTAssertEqual(
                    RecordingRowActions.mainAction(state: state, files: files, canRetry: false, meeting: nil),
                    RecordingRowActions.mainAction(state: state, files: files, canRetry: false).map(RowMainAction.action),
                )
            }
        }
    }

    // MARK: Against the actions

    /// A button that does nothing, or a meeting the menu holds back for no reason, is
    /// the two rules drifting apart. R4 takes Keep away with the last audio file; the
    /// action has no such rule, as a stale menu may still ask for it.
    @MainActor
    func testWhatARowOffersIsWhatItsActionAccepts() throws {
        let changes: [(String, (inout MeetingFileRecord) -> Void)] = [
            ("as it finished", { _ in }),
            ("kept", { $0.keep = true }),
            ("in progress", { $0.outcome = .inProgress }),
            ("failed", { $0.outcome = .failed }),
            ("left unfinished", { $0.outcome = .leftUnfinished }),
            ("a deletion pending", { $0.pending = .init(kind: .audioToTrash, paths: []) }),
            ("no audio left", { $0.setAudio(to: .gone) }),
            ("Move Audio incomplete", { $0.incomplete = Deletion(reason: "r", paths: [], kind: .audioToTrash) }),
            ("Move Meeting incomplete", { $0.incomplete = Deletion(reason: "r", paths: [], kind: .meetingToTrash) }),
            ("an automatic deletion incomplete", { $0.incomplete = Deletion(reason: "r", paths: [], kind: .automatic) }),
        ]
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        for origin in [MeetingFileRecord.Origin.recorded, .imported] {
            for (name, change) in changes {
                try assertOffersMatchTheActions(controller, harness, origin: origin, name: name, change: change)
            }
        }
    }

    /// Each action gets a meeting of its own, as it changes the record and the disk.
    @MainActor
    private func assertOffersMatchTheActions(
        _ controller: PipelineController, _ harness: MeetingDeletionHarness,
        origin: MeetingFileRecord.Origin, name: String, change: (inout MeetingFileRecord) -> Void,
    ) throws {
        let actions: [(String, (RowMenuItem) -> Bool, (UUID) -> Bool)] = [
            ("Keep", { if case .keep(_, enabled: true) = $0 { true } else { false } }, { controller.setKeep(jobID: $0, true) }),
            ("Move Audio", { $0 == .moveAudioToTrash(enabled: true) }, { controller.moveAudioToTrash(jobID: $0) }),
            ("Move Meeting", { $0 == .moveMeetingToTrash(enabled: true) }, { controller.moveMeetingToTrash(jobID: $0) }),
        ]
        for (action, isOffered, run) in actions {
            let (job, meeting) = try finishedMeeting(in: harness, origin: origin, change: change)
            let offered = RecordingRowActions.menuItems(
                state: .done, onDisk: protocolAndTranscript, canRetry: false, meeting: meeting,
            ).contains(where: isOffered)
            let accepted = run(job.id)
            let onlyTheMenuRefuses = origin == .recorded && name == "no audio left" && action == "Keep"
            XCTAssertEqual(offered, accepted && !onlyTheMenuRefuses, "\(origin), \(name), \(action)")
        }
        let (job, meeting) = try finishedMeeting(in: harness, origin: origin, change: change)
        let main = RecordingRowActions.mainAction(
            state: .done, files: RecordedFiles(hasProtocol: true, hasTranscript: true), canRetry: false, meeting: meeting,
        )
        XCTAssertEqual(main == .retryDeletion, controller.retryDeletion(jobID: job.id), "\(origin), \(name), Retry Deletion")
    }

    @MainActor
    private func makeDeletionHarness() throws -> MeetingDeletionHarness {
        let suite = "RecordingRowActions-\(getpid())-\(UUID().uuidString)"
        let root = try makeTempDirectory(prefix: "row-actions")
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)), defaultOutputDir: root.appendingPathComponent("output"),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try MeetingDeletionHarness(root: root, settings: settings)
    }

    /// A meeting with its files on disk and `change` applied to its record, and what
    /// a row reads of it.
    @MainActor
    private func finishedMeeting(
        in harness: MeetingDeletionHarness, origin: MeetingFileRecord.Origin, change: (inout MeetingFileRecord) -> Void,
    ) throws -> (PipelineJob, Meeting) {
        let job = try origin == .recorded ? harness.recordedMeeting() : harness.importedMeeting()
        XCTAssertTrue(harness.store.update(jobID: job.id, change), "test premise")
        let record = try harness.record(of: job)
        let left = record.filesCovered(by: .audioToTrash).filter { MeetingFilePresence.of($0.path) != .gone }.count
        return (job, meeting(record, audio: audio(present: left)))
    }
}
