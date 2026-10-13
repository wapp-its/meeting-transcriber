@testable import MeetingTranscriber
import XCTest

/// "Record with Options…" (spec gh-2, R10): the options travel with the
/// answer that resolved the open prompt into the job that recording becomes,
/// and into no other. Driven through the real poll loop with the scripted
/// detector, notifier and recorders of `WatchLoopAskBeforeRecordingTests`, and
/// a queue whose default template is not the built-in, so a stamped default
/// cannot be mistaken for an unset template.
@MainActor
final class WatchLoopConsentOptionsTests: XCTestCase {
    private typealias ScriptedDetector = WatchLoopAskBeforeRecordingTests.ScriptedDetector
    private typealias ParkingNotifier = WatchLoopAskBeforeRecordingTests.ParkingNotifier
    private typealias Recorders = WatchLoopAskBeforeRecordingTests.Recorders

    private static let defaultTemplate = ProtocolTemplateID.file(name: "Default")
    private let options = MeetingProtocolOptions(template: .file(name: "Board"), rawBackground: " Agenda: budget ")

    private let zoom = DetectedMeeting(pattern: .zoom, windowTitle: "Zoom Call", ownerName: "zoom.us", windowPID: 4321)
    private let teams = DetectedMeeting(pattern: .teams, windowTitle: "Teams Call", ownerName: "MSTeams", windowPID: 4322)

    private struct Harness {
        let loop: WatchLoop
        let detector: ScriptedDetector
        let notifier: ParkingNotifier
        let recorders: Recorders
        let queue: PipelineQueue
    }

    private func makeHarness(recordWithoutAsking: [String] = [], pollInterval: TimeInterval = 0.05) throws -> Harness {
        let output = try makeTempDirectory(prefix: "consent-options")
        let defaultTemplate: () -> ProtocolTemplateID = { Self.defaultTemplate }
        let queue = PipelineQueue(logDir: output, stagingDir: output, defaultProtocolTemplateProvider: defaultTemplate)
        let recorders = Recorders()
        let detector = ScriptedDetector([zoom])
        let notifier = ParkingNotifier()
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorders.make() },
            pipelineQueue: queue,
            pollInterval: pollInterval,
            endGracePeriod: 0.05,
            meetingEndCountdown: 0.05,
            recordWithoutAskingApps: { recordWithoutAsking },
            notifier: notifier,
        )
        loop.permissionChecker = { .allHealthy }
        return Harness(loop: loop, detector: detector, notifier: notifier, recorders: recorders, queue: queue)
    }

    /// Starts watching and returns the Zoom question once its prompt is parked.
    private func openZoomPrompt(_ harness: Harness) async throws -> ConsentQuestion {
        harness.loop.start()
        await waitFor(harness.notifier.isParked)
        return try XCTUnwrap(harness.loop.pendingConsentQuestion, "precondition: the Zoom prompt is open")
    }

    /// Ends the call in `app` once it records, and returns the job it became.
    private func finishRecording(_ harness: Harness, app: String) async throws -> PipelineJob {
        await waitFor(harness.loop.currentMeeting?.pattern.appName == app, timeout: .seconds(2))
        harness.detector.end(app)
        await waitFor(harness.queue.jobs.contains { $0.appName == app }, timeout: .seconds(2))
        return try XCTUnwrap(harness.queue.jobs.last { $0.appName == app }, "\(app) must have been recorded")
    }

    /// After a dropped grant: Zoom's call is asked about again, Record is
    /// tapped in its notification, and that recording must not carry the
    /// options the dropped grant came with.
    private func assertTheNextZoomRecordingHasNoOptions(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async throws {
        await waitFor(harness.notifier.prompts.count == 2, timeout: .seconds(2))
        XCTAssertEqual(harness.notifier.prompts.count, 2, "Zoom is asked about again", file: file, line: line)
        harness.notifier.answer(.granted)
        let job = try await finishRecording(harness, app: "Zoom")
        XCTAssertEqual(job.protocolTemplate, Self.defaultTemplate, file: file, line: line)
        XCTAssertNil(job.protocolBackground, file: file, line: line)
        harness.loop.stop()
    }

    // MARK: - Answering with options

    /// Also answers again from a menu that has not caught up: that plain
    /// Record finds the prompt resolved and must not overwrite the options.
    func testRecordWithOptionsRecordsTheMeetingWithThem() async throws {
        let harness = try makeHarness()
        let question = try await openZoomPrompt(harness)

        XCTAssertTrue(harness.loop.answerParkedConsent(question, granted: true, protocolOptions: options))
        XCTAssertFalse(harness.loop.answerParkedConsent(question, granted: true), "the prompt is already resolved")
        let job = try await finishRecording(harness, app: "Zoom")

        XCTAssertEqual(harness.recorders.starts, 1)
        XCTAssertEqual(job.protocolTemplate, .file(name: "Board"))
        XCTAssertEqual(job.protocolBackground, "Agenda: budget")
        harness.loop.stop()
    }

    func testANotificationAnswerAndThePlainMenuRecordGetTheDefaultTemplateAndNoBackground() async throws {
        let answers: [(String, (Harness, ConsentQuestion) -> Void)] = [
            ("notification", { harness, _ in harness.notifier.answer(.granted) }),
            ("menu Record", { harness, question in XCTAssertTrue(harness.loop.answerParkedConsent(question, granted: true)) }),
        ]
        for (name, answer) in answers {
            let harness = try makeHarness()
            let question = try await openZoomPrompt(harness)

            answer(harness, question)
            let job = try await finishRecording(harness, app: "Zoom")

            XCTAssertEqual(job.protocolTemplate, Self.defaultTemplate, name)
            XCTAssertNil(job.protocolBackground, name)
            harness.loop.stop()
        }
    }

    // MARK: - A question that is not the open one

    /// A replaced question (same text, another prompt) and one already answered
    /// in its notification: neither answers, neither starts a recording, and
    /// the recording the open prompt then starts carries no options.
    func testAStaleOrReplacedQuestionAnswersNothingAndLeavesNoOptionsBehind() async throws {
        let replaced = try makeHarness()
        let open = try await openZoomPrompt(replaced)
        let sameText = ConsentQuestion(app: open.app, title: open.title, body: open.body)
        XCTAssertFalse(replaced.loop.answerParkedConsent(sameText, granted: true, protocolOptions: options))
        await severalPolls()
        XCTAssertEqual(replaced.recorders.starts, 0, "a replaced question starts nothing")
        replaced.notifier.answer(.granted)
        let afterReplaced = try await finishRecording(replaced, app: "Zoom")
        XCTAssertEqual(afterReplaced.protocolTemplate, Self.defaultTemplate)
        XCTAssertNil(afterReplaced.protocolBackground)
        replaced.loop.stop()

        let answered = try makeHarness()
        let question = try await openZoomPrompt(answered)
        answered.notifier.answer(.granted)
        XCTAssertFalse(answered.loop.answerParkedConsent(question, granted: true, protocolOptions: options))
        let afterAnswered = try await finishRecording(answered, app: "Zoom")
        XCTAssertEqual(answered.recorders.starts, 1, "only the notification's answer records")
        XCTAssertEqual(afterAnswered.protocolTemplate, Self.defaultTemplate)
        XCTAssertNil(afterAnswered.protocolBackground)
        answered.loop.stop()
    }

    // MARK: - Dropped grants drop their options

    func testAGrantDroppedBecauseWatchingStoppedDropsItsOptions() async throws {
        let harness = try makeHarness()
        let question = try await openZoomPrompt(harness)

        XCTAssertTrue(harness.loop.answerParkedConsent(question, granted: true, protocolOptions: options))
        harness.loop.stop()
        await severalPolls()
        XCTAssertEqual(harness.recorders.starts, 0, "an answer landing after Stop Watching records nothing")

        harness.loop.start()
        try await assertTheNextZoomRecordingHasNoOptions(harness)
    }

    /// The answer has landed and waits for the next poll when watching stops.
    /// A slow poll keeps the approval parked long enough to stop in between;
    /// the restarted loop must ask again rather than record on it.
    func testAnApprovalWaitingForThePollLoopIsDroppedWithItsOptionsWhenWatchingStops() async throws {
        let harness = try makeHarness(pollInterval: 0.3)
        let question = try await openZoomPrompt(harness)

        XCTAssertTrue(harness.loop.answerParkedConsent(question, granted: true, protocolOptions: options))
        await waitFor(harness.loop.approvedConsentMeeting != nil)
        XCTAssertNotNil(harness.loop.approvedConsentMeeting, "precondition: the approval waits for the poll loop")
        harness.loop.stop()

        harness.loop.start()
        try await assertTheNextZoomRecordingHasNoOptions(harness)
    }

    func testAGrantDroppedBecauseAnotherMeetingRecordsDropsItsOptions() async throws {
        let harness = try makeHarness(recordWithoutAsking: ["Microsoft Teams"])
        let question = try await openZoomPrompt(harness)
        harness.detector.confirmed = [zoom, teams]
        harness.detector.running.insert("Microsoft Teams")
        await waitFor(harness.recorders.starts == 1)

        XCTAssertTrue(harness.loop.answerParkedConsent(question, granted: true, protocolOptions: options))
        await severalPolls()
        XCTAssertEqual(harness.recorders.starts, 1, "the Zoom answer must not start a second recording")

        let teamsJob = try await finishRecording(harness, app: "Microsoft Teams")
        XCTAssertEqual(teamsJob.protocolTemplate, Self.defaultTemplate)
        try await assertTheNextZoomRecordingHasNoOptions(harness)
    }

    func testAGrantDroppedBecauseTheCallEndedDropsItsOptions() async throws {
        let harness = try makeHarness()
        let question = try await openZoomPrompt(harness)

        harness.detector.end("Zoom")
        XCTAssertTrue(harness.loop.answerParkedConsent(question, granted: true, protocolOptions: options))
        await severalPolls()
        XCTAssertEqual(harness.recorders.starts, 0, "a call that ended while asked about is not recorded")

        harness.detector.confirmed = [zoom]
        harness.detector.running.insert("Zoom")
        try await assertTheNextZoomRecordingHasNoOptions(harness)
    }

    /// Long enough for several 0.05 s polls, for asserting that nothing happens.
    private func severalPolls() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}
