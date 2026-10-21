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
