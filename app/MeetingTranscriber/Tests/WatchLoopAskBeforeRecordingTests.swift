@testable import MeetingTranscriber
import XCTest

/// Every detected meeting asks before it records, unless its app is switched
/// to "record without asking". Driven through the real `start()` poll loop with
/// a scripted detector and a scripted notifier, never by calling the recording
/// start directly, so the gate is exercised where it runs.
/// `WatchLoopBrowserConsentTests` keeps the browser-specific cases.
@MainActor
final class WatchLoopAskBeforeRecordingTests: XCTestCase {
    /// Confirms the meetings in `confirmed`, first one first, the way the real
    /// detectors do when several apps are in a call: a poll returns the first
    /// confirmed meeting that is not excluded. A call counts as running while
    /// its app is in `running`.
    private final class ScriptedDetector: MeetingDetecting {
        var confirmed: [DetectedMeeting]
        var running: Set<String>

        init(_ confirmed: [DetectedMeeting]) {
            self.confirmed = confirmed
            running = Set(confirmed.map(\.pattern.appName))
        }

        func checkOnce() -> DetectedMeeting? {
            checkOnce(excluding: [])
        }

        func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
            confirmed.first { !excludedApps.contains($0.pattern.appName) }
        }

        func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
            running.contains(meeting.pattern.appName)
        }

        func reset(appName _: String?) {}

        /// The call in `app` is over: it is neither detected nor running.
        func end(_ app: String) {
            confirmed.removeAll { $0.pattern.appName == app }
            running.remove(app)
        }
    }

    /// Answers every prompt at once with a fixed answer and records what it was
    /// asked.
    private final class AnsweringNotifier: AppNotifying {
        let answer: ConsentAnswer
        private(set) var prompts: [(title: String, body: String)] = []

        init(_ answer: ConsentAnswer) {
            self.answer = answer
        }

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        // swiftlint:disable async_without_await
        @MainActor
        func askToRecord(title: String, body: String) async -> ConsentAnswer {
            prompts.append((title, body))
            return answer
        }
        // swiftlint:enable async_without_await
    }

    /// Parks every prompt until the test answers it, like the real
    /// notification does for up to `NotificationManager.consentPromptTimeout`.
    private final class ParkingNotifier: AppNotifying {
        private(set) var prompts: [(title: String, body: String)] = []
        private var continuation: CheckedContinuation<ConsentAnswer, Never>?

        var isParked: Bool {
            continuation != nil
        }

        func notify(title _: String, body _: String, urgency _: NotificationUrgency) {}

        @MainActor
        func askToRecord(title: String, body: String) async -> ConsentAnswer {
            prompts.append((title, body))
            return await withCheckedContinuation { self.continuation = $0 }
        }

        func answer(_ answer: ConsentAnswer) {
            let parked = continuation
            continuation = nil
            parked?.resume(returning: answer)
        }

        func resolveBrowserConsent(granted: Bool) -> Bool {
            guard isParked else { return false }
            answer(granted ? .granted : .declined)
            return true
        }
    }

    /// Hands out a fresh recorder per recording, so a test can count starts.
    @MainActor
    private final class Recorders {
        private(set) var all: [MockRecorder] = []

        var starts: Int {
            all.count { $0.startCalled }
        }

        func make() -> MockRecorder {
            let recorder = MockRecorder()
            recorder.mixPath = URL(fileURLWithPath: "/tmp/ask_first_mix_\(UUID().uuidString).wav")
            all.append(recorder)
            return recorder
        }
    }

    // MARK: - Meetings

    private func meeting(_ pattern: AppMeetingPattern, owner: String) -> DetectedMeeting {
        DetectedMeeting(pattern: pattern, windowTitle: "\(pattern.appName) Call", ownerName: owner, windowPID: 4321)
    }

    private var teams: DetectedMeeting {
        meeting(.teams, owner: "MSTeams")
    }

    private var zoom: DetectedMeeting {
        meeting(.zoom, owner: "zoom.us")
    }

    private var webex: DetectedMeeting {
        meeting(.webex, owner: "Webex")
    }

    /// A mic-input detection, as `MicInputDetector` reports it.
    private var weChat: DetectedMeeting {
        meeting(.wechat, owner: "WeChat")
    }

    /// Built through the production synthesis, as in `WatchLoopBrowserConsentTests`.
    private func browser(_ process: String = "Google Chrome") throws -> DetectedMeeting {
        let category = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns.first { $0.appName == AppMeetingPattern.browserMeetings.appName },
        )
        return meeting(PowerAssertionDetector.meetingIdentity(pattern: category, processName: process), owner: process)
    }

    // MARK: - Loop

    private func makeLoop(
        detector: any MeetingDetecting,
        notifier: any AppNotifying,
        recordWithoutAsking: [String] = [],
        denied: [String] = [],
        recordOnly: Bool = false,
    ) throws -> (WatchLoop, Recorders, InMemoryConsentDenyListStore) {
        let recorders = Recorders()
        let store = InMemoryConsentDenyListStore(denyList: ConsentDenyList(denied: denied))
        let output = try makeTempDirectory(prefix: "ask-first")
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorders.make() },
            pollInterval: 0.05,
            endGracePeriod: 0.05,
            recordOnly: { recordOnly },
            // Never the production staging directory: a stopped recording is
            // finalised, and record-only writes it out.
            recordOnlyDestination: { .unscoped(output) },
            recordWithoutAskingApps: { recordWithoutAsking },
            notifier: notifier,
            denyListStore: store,
        )
        loop.permissionChecker = { .allHealthy }
        return (loop, recorders, store)
    }

    /// Long enough for several 0.05 s polls, for asserting that nothing happens.
    private func severalPolls() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - R1 / R5: every answer, for every kind of app

    func testEveryAnswerForEveryKindOfApp() async throws {
        let kinds = try [("native", teams), ("mic-input", weChat), ("browser", browser())]
        let answers: [ConsentAnswer] = [.granted, .declined, .never, .expired]
        for (kind, detected) in kinds {
            for answer in answers {
                let app = detected.pattern.appName
                let label = "\(kind) app, \(answer)"
                let notifier = AnsweringNotifier(answer)
                let (loop, recorders, store) = try makeLoop(detector: ScriptedDetector([detected]), notifier: notifier)
                loop.start()

                if answer.isGranted {
                    await waitFor(recorders.starts == 1)
                } else {
                    await waitFor(!notifier.prompts.isEmpty)
                    await severalPolls()
                }

                XCTAssertEqual(recorders.starts, answer.isGranted ? 1 : 0, "\(label): only Record records")
                // Asked exactly once: after a no or no answer the cooldown (or the
                // denial) keeps the same call from being asked again at once.
                XCTAssertEqual(notifier.prompts.count, 1, "\(label): asked once")
                let prompt = try XCTUnwrap(notifier.prompts.first, label)
                XCTAssertEqual(prompt.title, "Record \(app) meeting?", label)
                XCTAssertTrue(prompt.body.contains(app), "\(label): the prompt names the app")
                XCTAssertEqual(store.isDenied(app), answer == .never, "\(label): only Never denies the app")
                loop.stop()
            }
        }
    }

    // MARK: - R2: record without asking

    func testAnAppSwitchedToRecordWithoutAskingStartsWithoutAPrompt() async throws {
        for detected in [teams, weChat] {
            let app = detected.pattern.appName
            // Declines if it is ever asked, so a prompt would also stop the recording.
            let notifier = AnsweringNotifier(.declined)
            let (loop, recorders, _) = try makeLoop(
                detector: ScriptedDetector([detected]), notifier: notifier, recordWithoutAsking: [app],
            )
            loop.start()
            await waitFor(recorders.starts == 1)
            XCTAssertEqual(recorders.starts, 1, "\(app): records without asking")
            XCTAssertTrue(notifier.prompts.isEmpty, "\(app): no prompt")
            loop.stop()
        }
    }

    /// The other half of R2, and the competing-meetings rule: only Teams is
    /// switched on, so Zoom and Webex ask, and Teams starts recording while the
    /// Zoom question is still open. Zoom and Webex come first in the
    /// detector's order, so this also fails if either the app being asked
    /// about or the app waiting for that answer is not excluded from detection.
    func testOtherAppsStillAskAndANoAskAppDoesNotWaitForTheirPrompt() async throws {
        let notifier = ParkingNotifier()
        let detector = ScriptedDetector([zoom])
        let (loop, recorders, _) = try makeLoop(
            detector: detector, notifier: notifier, recordWithoutAsking: ["Microsoft Teams"],
        )
        loop.start()
        await waitFor(notifier.isParked)
        XCTAssertEqual(notifier.prompts.map(\.title), ["Record Zoom meeting?"])

        detector.confirmed = [zoom, webex, teams]
        detector.running.formUnion(["Webex", "Microsoft Teams"])
        await waitFor(recorders.starts == 1)
        XCTAssertEqual(recorders.starts, 1, "Teams must record while the Zoom question is open")
        XCTAssertEqual(loop.currentMeeting?.pattern.appName, "Microsoft Teams")
        XCTAssertEqual(notifier.prompts.count, 1, "Teams is never asked about, and Webex waits for the Zoom answer")

        notifier.answer(.declined)
        loop.stop()
    }

    func testADeniedAppIsNeverRecordedEvenWhenSwitchedToRecordWithoutAsking() async throws {
        let notifier = AnsweringNotifier(.granted)
        let (loop, recorders, _) = try makeLoop(
            detector: ScriptedDetector([teams]),
            notifier: notifier,
            recordWithoutAsking: ["Microsoft Teams"],
            denied: ["Microsoft Teams"],
        )
        loop.start()
        await severalPolls()
        XCTAssertEqual(recorders.starts, 0, "Never outranks record without asking")
        XCTAssertTrue(notifier.prompts.isEmpty, "and a denied app is not asked either")
        loop.stop()
    }

    // MARK: - R3: browser meetings always ask

    func testABrowserMeetingAsksEvenWhenItsNameIsStoredAsRecordWithoutAsking() async throws {
        let chrome = try browser("Google Chrome")
        let notifier = AnsweringNotifier(.declined)
        let (loop, recorders, _) = try makeLoop(
            detector: ScriptedDetector([chrome]),
            notifier: notifier,
            recordWithoutAsking: ["Google Chrome", AppMeetingPattern.browserMeetings.appName],
        )
        loop.start()
        await waitFor(!notifier.prompts.isEmpty)
        XCTAssertEqual(notifier.prompts.count, 1, "a browser meeting must ask whatever is stored")
        XCTAssertEqual(recorders.starts, 0)
        loop.stop()
    }

    // MARK: - Competing meetings

    /// An approval is not a reservation: a Record that lands while another
    /// meeting records is dropped, and the call is asked about again once the
    /// recorder is free.
    func testARecordAnswerWhileAnotherMeetingRecordsIsDroppedAndAskedAgain() async throws {
        let notifier = ParkingNotifier()
        let detector = ScriptedDetector([zoom])
        let (loop, recorders, _) = try makeLoop(
            detector: detector, notifier: notifier, recordWithoutAsking: ["Microsoft Teams"],
        )
        loop.start()
        await waitFor(notifier.isParked)
        detector.confirmed = [zoom, teams]
        detector.running.insert("Microsoft Teams")
        await waitFor(recorders.starts == 1)
        XCTAssertEqual(loop.currentMeeting?.pattern.appName, "Microsoft Teams", "precondition: Teams is recording")

        notifier.answer(.granted)
        await severalPolls()
        XCTAssertEqual(recorders.starts, 1, "the Zoom answer must not start a second recording")

        detector.end("Microsoft Teams")
        await waitFor(notifier.prompts.count == 2, timeout: .seconds(2))
        XCTAssertEqual(notifier.prompts.map(\.title), ["Record Zoom meeting?", "Record Zoom meeting?"], "Zoom is asked about again")
        XCTAssertEqual(recorders.starts, 1, "and does not record on the dropped answer")

        notifier.answer(.declined)
        loop.stop()
    }

    func testARecordAnswerForAMeetingThatEndedIsDropped() async throws {
        let notifier = ParkingNotifier()
        let detector = ScriptedDetector([zoom])
        let (loop, recorders, _) = try makeLoop(detector: detector, notifier: notifier)
        loop.start()
        await waitFor(notifier.isParked)

        detector.end("Zoom")
        notifier.answer(.granted)
        await severalPolls()
        XCTAssertEqual(recorders.starts, 0, "a call that ended while asked about is not recorded")
        loop.stop()
    }

    func testAMeetingStartingDuringARecordingIsAskedAboutOnlyAfterIt() async throws {
        let notifier = AnsweringNotifier(.declined)
        let detector = ScriptedDetector([teams])
        let (loop, recorders, _) = try makeLoop(
            detector: detector, notifier: notifier, recordWithoutAsking: ["Microsoft Teams"],
        )
        loop.start()
        await waitFor(recorders.starts == 1)

        detector.confirmed = [teams, zoom]
        detector.running.insert("Zoom")
        await severalPolls()
        XCTAssertTrue(notifier.prompts.isEmpty, "nothing is asked while a recording runs")

        detector.end("Microsoft Teams")
        await waitFor(!notifier.prompts.isEmpty, timeout: .seconds(2))
        XCTAssertEqual(notifier.prompts.map(\.title), ["Record Zoom meeting?"])
        loop.stop()
    }

    /// One open prompt at a time: a second app that asks waits, unqueued, and
    /// is asked about once the first question is settled.
    func testASecondAppThatAsksWaitsForTheOpenPrompt() async throws {
        let notifier = ParkingNotifier()
        let detector = ScriptedDetector([zoom])
        let (loop, _, _) = try makeLoop(detector: detector, notifier: notifier)
        loop.start()
        await waitFor(notifier.isParked)

        detector.confirmed = [weChat, zoom]
        detector.running.insert("WeChat")
        await severalPolls()
        XCTAssertEqual(notifier.prompts.count, 1, "WeChat must not be asked while the Zoom prompt is open")

        notifier.answer(.declined)
        await waitFor(notifier.prompts.count == 2, timeout: .seconds(2))
        XCTAssertEqual(notifier.prompts.last?.title, "Record WeChat meeting?")

        notifier.answer(.declined)
        loop.stop()
    }

    // MARK: - Modes and exceptions

    func testRecordOnlyModeAsksTheSameWay() async throws {
        let notifier = AnsweringNotifier(.granted)
        let (loop, recorders, _) = try makeLoop(
            detector: ScriptedDetector([teams]), notifier: notifier, recordOnly: true,
        )
        loop.start()
        await waitFor(recorders.starts == 1)
        XCTAssertEqual(notifier.prompts.count, 1, "record-only asks first too")
        XCTAssertEqual(recorders.starts, 1, "and records on Record")
        loop.stop()
    }

    /// R7: the user starting a recording by hand is the answer.
    func testAManualStartNeverAsks() async throws {
        let notifier = AnsweringNotifier(.declined)
        let (loop, recorders, _) = try makeLoop(detector: ScriptedDetector([]), notifier: notifier)
        try await loop.startManualRecording(pid: 1234, appName: "Microsoft Teams", title: "Ad-hoc")
        XCTAssertEqual(recorders.starts, 1)
        XCTAssertTrue(notifier.prompts.isEmpty, "a manual start must never ask")
        loop.stopManualRecording()
    }

    /// The end-to-end lanes record the meeting simulator with nobody there to
    /// answer, so it must not ask.
    func testTheMeetingSimulatorRecordsWithoutAsking() async throws {
        let notifier = AnsweringNotifier(.declined)
        let (loop, recorders, _) = try makeLoop(
            detector: ScriptedDetector([meeting(.simulator, owner: "meeting-simulator")]), notifier: notifier,
        )
        loop.start()
        await waitFor(recorders.starts == 1)
        XCTAssertEqual(recorders.starts, 1)
        XCTAssertTrue(notifier.prompts.isEmpty)
        loop.stop()
    }
}
