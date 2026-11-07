@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// "Nothing would go" saves a shorter value with nobody asked, and the next check then
/// deletes by it. So the controller's answer has to hold at the moment it returns, and
/// what it cannot vouch for is no answer at all (R10).
@MainActor
final class RetentionPreviewFreshAnswerTests: XCTestCase {
    private typealias Selection = RetentionPreview.Selection
    private typealias FileOnDisk = RetentionPreview.FileOnDisk

    private let busy = LiveMeetingState(state: .transcribing, notionExportRunning: false)

    private func controller(
        _ bed: RetentionCheckBed,
        store: MeetingFileStore? = nil,
        queueCannotAnswerFor unknown: Set<UUID> = [],
        readFile: @escaping @Sendable (String) -> FileOnDisk = FileOnDisk.read,
    ) -> RecordingRetentionController {
        RecordingRetentionController(
            settings: bed.settings,
            store: store ?? bed.store,
            remover: MeetingFileRemover { url in
                XCTFail("the automatic check moved \(url.lastPathComponent) to the Trash")
            },
            liveState: { bed.live[$0] },
            liveStateIsKnown: { !unknown.contains($0) },
            isListed: { bed.listed.contains($0) },
            securityScope: bed.harness.scopes.access,
            calendar: bed.calendar,
            now: { bed.clock },
            readFile: readFile,
        )
    }

    private func choice(_ bed: RetentionCheckBed, over sut: RecordingRetentionController) -> RetentionChoice {
        RetentionChoice(settings: bed.settings, actions: RetentionSettingsActions(
            preview: { await sut.preview(for: $0) },
            apply: { sut.apply($0) },
        ))
    }

    private func setRecordFile(_ bed: RetentionCheckBed, readable: Bool) throws {
        let path = bed.harness.recordPath.path
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o600 : 0o000], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
    }

    private func removeAudio(of record: MeetingFileRecord, in bed: RetentionCheckBed) throws {
        for path in bed.audioPaths(record) {
            try bed.removeBehindTheApp(path)
        }
    }

    private func audioBytes(of record: MeetingFileRecord, in bed: RetentionCheckBed) throws -> Int64 {
        try bed.audioPaths(record).reduce(0) { total, path in
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
            return try total + XCTUnwrap(size)
        }
    }

    // MARK: - A record file that does not read

    /// The store keeps what it held, and that is older than the file: another build, or
    /// another part of this one, may have written since. An empty cache read as nothing
    /// to delete, and one meeting too few read as a promise of less than goes.
    func testARecordFileThatDoesNotReadTellsNothing() async throws {
        for cached in [0, 1] {
            let bed = try makeRetentionCheckBed()
            for _ in 0 ..< cached {
                try bed.meeting()
            }
            let cache = MeetingFileStore(path: bed.harness.recordPath)
            try bed.meeting()
            try setRecordFile(bed, readable: false)

            let answer = await controller(bed, store: cache).preview(for: .days30)

            XCTAssertNil(answer, "\(cached) meetings in the store's memory")
        }
    }

    /// The user's whole way: no value saved, so the check deletes nothing once the file
    /// reads again, and the next choice asks with everything counted.
    func testAValueNotCheckedStaysUnsavedAndIsAskedAgainOnceTheFileReads() async throws {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        let cache = MeetingFileStore(path: bed.harness.recordPath)
        let record = try bed.meeting()
        try setRecordFile(bed, readable: false)
        let sut = controller(bed, store: cache)
        let choice = choice(bed, over: sut)

        choice.choose(.days30)
        await choice.checking?.value

        XCTAssertEqual(bed.settings.recordingRetention, .never)
        XCTAssertEqual(choice.shown, .never, "the picker goes back")
        XCTAssertEqual(choice.notChecked, .days30)
        XCTAssertNil(choice.preview)

        try setRecordFile(bed, readable: true)
        await sut.checkNow()
        try bed.assertUntouched(record, "the check after the failed read")

        choice.choose(.days30)
        await choice.checking?.value

        XCTAssertEqual(choice.preview?.meetingCount, 1)
        XCTAssertNil(choice.notChecked)
        XCTAssertEqual(bed.settings.recordingRetention, .never)
    }

    /// "Nothing would go" saves the value, so an answer that cannot be told must not read
    /// as that, and the picker going back on its own needs a word.
    func testAValueWhoseEffectCannotBeToldIsNotSavedAndSaysSo() async throws {
        let line = "Could not read which meetings “After 30 days” would delete, so the setting did not change. Try again later."
        let goes = RetentionPreview(
            Selection(
                records: [RetentionFixture.record()], live: { _ in nil }, retention: .days30,
                now: RetentionFixture.longAfter, calendar: RetentionFixture.calendar,
            ),
        ) { _ in .present(bytes: 100) }
        for next in [RecordingRetention.days30, .never] {
            let settings = try makeRetentionCheckBed().settings
            settings.recordingRetention = .days90
            let check = StubbedCheck()
            let choice = RetentionChoice(settings: settings, actions: RetentionSettingsActions(
                preview: { _ in check.answer },
                apply: { XCTFail("applied \($0)") },
            ))
            let view = OutputSettingsView(settings: settings, retentionChoice: choice)
            func picker() throws -> InspectableView<ViewType.Picker> {
                try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.recordingRetentionPicker).find(ViewType.Picker.self)
            }

            try picker().select(value: RecordingRetention.days30)
            await choice.checking?.value

            XCTAssertEqual(settings.recordingRetention, .days90)
            XCTAssertEqual(try picker().selectedValue(RecordingRetention.self), .days90, "the picker goes back")
            XCTAssertFalse(choice.isChecking)
            XCTAssertThrowsError(try view.inspect().find(ViewType.Alert.self))
            XCTAssertNoThrow(try view.inspect().find(text: line))

            check.answer = goes
            try picker().select(value: next)
            await choice.checking?.value

            XCTAssertThrowsError(try view.inspect().find(text: line), "the next choice answers it")
            XCTAssertEqual(next == .never ? settings.recordingRetention : choice.preview?.retention, next)
        }
    }

    // MARK: - A queue that cannot answer

    func testAMeetingTheQueueCannotAnswerForLeavesTheSelectionIncomplete() {
        let due = RetentionFixture.record()
        let kept = RetentionFixture.record { $0.keep = true }
        var asked: [UUID] = []

        let selection = Selection(
            records: [due, kept], live: { _ in self.busy },
            isKnown: { id in
                asked.append(id)
                return false
            },
            retention: .days30, now: RetentionFixture.longAfter, calendar: RetentionFixture.calendar,
        )

        XCTAssertFalse(selection.isComplete)
        XCTAssertEqual(selection.meetings, [])
        XCTAssertEqual(asked, [due.jobID], "what the record holds back needs no queue")
    }

    /// A job known to be busy holds its audio back for now: that is a real "nothing".
    func testAJobKnownToBeBusyLeavesTheSelectionComplete() {
        let selection = Selection(
            records: [RetentionFixture.record()], live: { _ in self.busy }, isKnown: { _ in true },
            retention: .days30, now: RetentionFixture.longAfter, calendar: RetentionFixture.calendar,
        )

        XCTAssertTrue(selection.isComplete)
        XCTAssertEqual(selection.meetings, [])
    }

    func testAQueueThatCannotAnswerTellsNothingWhateverTheOtherMeetingsSay() async throws {
        let bed = try makeRetentionCheckBed()
        let unknown = try bed.meeting()
        try bed.meeting()

        let answer = await controller(bed, queueCannotAnswerFor: [unknown.jobID]).preview(for: .days30)

        XCTAssertNil(answer, "the alert would promise less than goes once the queue answers")
    }

    private func bareRun() throws -> (harness: MeetingDeletionHarness, pipeline: PipelineController, retention: RecordingRetentionController) {
        let harness = try makeRetentionCheckBed().harness
        harness.settings.recordingRetention = .never
        let pipeline = harness.controller()
        return (harness, pipeline, RecordingRetentionController(pipeline: pipeline))
    }

    private func breakSnapshot(of harness: MeetingDeletionHarness) throws {
        try Data("not json".utf8).write(to: harness.logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
    }

    /// The real wiring: `liveMeetingState` answers waiting here to hold the audio back,
    /// which the preview must not take for a job known to be waiting.
    func testASnapshotThatDoesNotReadTellsNothing() async throws {
        let (harness, pipeline, retention) = try bareRun()
        _ = try harness.recordedMeeting()
        try breakSnapshot(of: harness)

        let unread = await retention.preview(for: .afterProtocol)
        XCTAssertNil(unread, "no queue has read it yet")

        pipeline.activate { MockEngine() }
        pipeline.rebuild()
        XCTAssertEqual(pipeline.queue.jobs.count, 0, "test premise")

        let tried = await retention.preview(for: .afterProtocol)
        XCTAssertNil(tried, "a queue tried and holds nothing")
    }

    func testASnapshotThatReadsAgainAnswersAgain() async throws {
        let (harness, _, retention) = try bareRun()
        _ = try harness.recordedMeeting()
        try breakSnapshot(of: harness)
        let broken = await retention.preview(for: .afterProtocol)
        XCTAssertNil(broken, "test premise")

        try PipelineSnapshot.save([], to: harness.logDir)
        let answer = await retention.preview(for: .afterProtocol)

        XCTAssertEqual(answer?.meetingCount, 1)
    }

    /// A job the snapshot does say is waiting is known, so this one is a real "nothing".
    func testAJobWaitingInAReadableSnapshotIsKnown() async throws {
        let (harness, pipeline, retention) = try bareRun()
        var job = try harness.recordedMeeting()
        job.state = .waiting
        try PipelineSnapshot.save([job], to: harness.logDir)

        let answer = await retention.preview(for: .afterProtocol)

        XCTAssertEqual(answer?.isEmpty, true)
        XCTAssertTrue(pipeline.knowsLiveState(jobID: job.id))
    }

    /// The queue's own jobs do not depend on the file it could not read.
    func testAJobTheQueueHoldsIsKnownWithASnapshotThatDoesNotRead() throws {
        let (harness, pipeline, _) = try bareRun()
        let job = try harness.recordedMeeting()
        try breakSnapshot(of: harness)
        XCTAssertFalse(pipeline.knowsLiveState(jobID: job.id), "test premise")

        pipeline.queue.jobs.append(job)

        XCTAssertTrue(pipeline.knowsLiveState(jobID: job.id))
    }

    // MARK: - What changes while the disk answers

    /// Runs `change` while the disk is held on its first read, and answers from the disk
    /// after that. A's audio is gone, so only A would be read, and an answer from before
    /// the wait would say nothing goes.
    private func preview(
        _ bed: RetentionCheckBed, whileTheDiskAnswers change: () throws -> Void,
    ) async throws -> (answer: RetentionPreview?, reads: [String]) {
        let disk = HeldRead()
        let sut = controller(bed) { path in
            disk.enter(path)
            return FileOnDisk.read(path)
        }

        let answer = Task { await sut.preview(for: .days30) }
        await waitFor { disk.hasEntered }
        try change()
        disk.release()

        return await (answer.value, disk.paths)
    }

    private func bedWithAudioGone() throws -> RetentionCheckBed {
        let bed = try makeRetentionCheckBed()
        bed.settings.recordingRetention = .never
        try removeAudio(of: bed.meeting(), in: bed)
        return bed
    }

    func testAMeetingThatFinishesWhileTheDiskAnswersIsCounted() async throws {
        let bed = try bedWithAudioGone()
        let finishing = try bed.meeting()
        bed.live[finishing.jobID] = busy

        let (answer, reads) = try await preview(bed) { bed.live[finishing.jobID] = nil }

        XCTAssertEqual(answer?.meetingCount, 1)
        XCTAssertEqual(answer?.bytes, try audioBytes(of: finishing, in: bed))
        XCTAssertEqual(reads.count, Set(reads).count, "each file is read once")
    }

    /// Other parts of the app, and other builds, write through a store of their own.
    func testAMeetingWrittenWhileTheDiskAnswersIsCounted() async throws {
        let bed = try bedWithAudioGone()
        let elsewhere = MeetingFileStore(path: bed.harness.recordPath)
        var written: MeetingFileRecord?

        let (answer, _) = try await preview(bed) { written = try bed.meeting(writtenBy: elsewhere) }

        XCTAssertEqual(answer?.meetingCount, 1)
        XCTAssertEqual(answer?.bytes, try audioBytes(of: XCTUnwrap(written), in: bed))
    }

    /// The other way round, the count follows too: the rule is what decides, not what it
    /// said before the wait.
    func testAMeetingKeptWhileTheDiskAnswersIsNoLongerCounted() async throws {
        let bed = try makeRetentionCheckBed()
        let record = try bed.meeting()

        let (answer, _) = try await preview(bed) { XCTAssertTrue(bed.store.setKeep(true, jobID: record.jobID), "test premise") }

        XCTAssertEqual(answer?.isEmpty, true)
    }

    /// A record file that stops reading during the wait is no answer either.
    func testARecordFileThatStopsReadingWhileTheDiskAnswersTellsNothing() async throws {
        let bed = try makeRetentionCheckBed()
        try bed.meeting()

        let (answer, _) = try await preview(bed) { try setRecordFile(bed, readable: false) }

        XCTAssertNil(answer)
    }

    func testAValueIsNotSavedUnseenWhenAMeetingFinishesWhileTheDiskAnswers() async throws {
        let bed = try bedWithAudioGone()
        let finishing = try bed.meeting()
        bed.live[finishing.jobID] = busy
        let disk = HeldRead()
        let sut = controller(bed) { path in
            disk.enter(path)
            return FileOnDisk.read(path)
        }
        let choice = choice(bed, over: sut)

        choice.choose(.days30)
        await waitFor { disk.hasEntered }
        bed.live[finishing.jobID] = nil
        disk.release()
        await choice.checking?.value

        XCTAssertEqual(bed.settings.recordingRetention, .never, "saved with nobody asked")
        XCTAssertEqual(choice.preview?.meetingCount, 1)
    }

    /// Reading again stays inside the one scope, and closes it once.
    func testAllReadsHappenInsideOneScope() async throws {
        let bed = try bedWithAudioGone()
        bed.settings.setCustomOutputDir(bed.harness.outputDir)
        let root = try XCTUnwrap(bed.settings.customOutputDir, "test premise")
        let finishing = try bed.meeting()
        bed.live[finishing.jobID] = busy
        let scopes = bed.harness.scopes
        let disk = HeldRead()
        let sut = controller(bed) { path in
            disk.enter(path, open: scopes.opened.count - scopes.closed.count)
            return FileOnDisk.read(path)
        }

        let answer = Task { await sut.preview(for: .days30) }
        await waitFor { disk.hasEntered }
        bed.live[finishing.jobID] = nil
        disk.release()
        _ = await answer.value

        XCTAssertEqual(Set(disk.openScopes), [1])
        XCTAssertEqual(scopes.opened.map(\.path), [root.path])
        XCTAssertEqual(scopes.closed.map(\.path), [root.path], "left open")
    }
}

/// What a stubbed check answers: nil until the test says otherwise.
@MainActor
private final class StubbedCheck {
    var answer: RetentionPreview?
}

/// Holds every read until the test lets them go, and tells what was read.
private final class HeldRead: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var read: [String] = []
    private var open: [Int] = []

    var hasEntered: Bool {
        condition.withLock { entered }
    }

    var paths: [String] {
        condition.withLock { read }
    }

    var openScopes: [Int] {
        condition.withLock { open }
    }

    func enter(_ path: String, open scopes: Int = 0) {
        condition.lock()
        defer { condition.unlock() }
        entered = true
        read.append(path)
        open.append(scopes)
        // Bounded, so a test that never releases fails instead of hanging.
        let deadline = Date().addingTimeInterval(5)
        while !released, condition.wait(until: deadline) {}
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}
