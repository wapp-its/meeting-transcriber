@testable import MeetingTranscriber
import XCTest

/// "Record (<App>)" after the person answered "Ignore" to "Record <App>
/// meeting?" while the call goes on: the offer, how it goes away, the click's
/// recording at the next poll, and what is asked afterwards. Driven on
/// `TestClock`, polling once a virtual second with a 10 s end grace and a 5 s
/// meeting-end countdown, so no test waits in real time. The refusals and
/// failures are in `WatchLoopRecordIgnoredTests+Refusals.swift`, the new-call
/// split with the real assertion detector in `WatchLoopRecordIgnoredSplitTests`.
@MainActor
final class WatchLoopRecordIgnoredTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // The doubles, the harness and the helpers down to `ignoreTheOpenQuestion`
    // are not private: WatchLoopRecordIgnoredTests+Refusals.swift shares them.
    // swiftlint:disable test_case_accessibility

    /// A call per app, keyed by identity key: a poll confirms the first
    /// meeting in `confirmed` whose signal is there and whose app is neither
    /// excluded nor reset at the poll before. That one-poll cooldown after a
    /// reset is what lets another app's call be detected while an ignored
    /// call is passed over every other poll by its quiet time.
    final class Detector: MeetingDetecting {
        private var confirmed: [DetectedMeeting] = []
        private var signalling: Set<String> = []
        private var cooling: Set<String> = []
        private(set) var confirmedMarks: [String] = []

        func checkOnce() -> DetectedMeeting? {
            checkOnce(excluding: [])
        }

        func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
            let skipped = cooling
            cooling = []
            return confirmed.first { meeting in
                let app = meeting.pattern.identityKey
                return signalling.contains(app) && !excludedApps.contains(app) && !skipped.contains(app)
            }
        }

        func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
            signalling.contains(meeting.pattern.identityKey)
        }

        func reset(appName: String?) {
            if let appName { cooling.insert(appName) }
        }

        func markConfirmed(appName: String) {
            confirmedMarks.append(appName)
        }

        /// `meeting`'s app is in a call: its signal is there, and a poll
        /// detects this meeting for it from now on.
        func call(_ meeting: DetectedMeeting) {
            let app = meeting.pattern.identityKey
            confirmed.removeAll { $0.pattern.identityKey == app }
            confirmed.append(meeting)
            signalling.insert(app)
        }

        /// The app's signal is gone.
        func hangUp(_ app: String) {
            signalling.remove(app)
        }
    }

    /// Everything a loop under test talks to. Every prompt parks until the
    /// test answers it. `onTick` runs after every virtual sleep, before the
    /// next poll, with the seconds since the clock started; it is handed the
    /// harness rather than capturing it, so no test builds a reference cycle.
    @MainActor
    final class Harness {
        static let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: start)
        let detector = Detector()
        let notifier = ConsentLoopDoubles.ParkingNotifier()
        let diagnostics = RecordingDiagnostics()
        var onTick: @MainActor (Harness, TimeInterval) async -> Void = { _, _ in }
        /// The recorder for each start, which can stop it only with a mix path.
        var nextRecorder: @MainActor (Harness) -> any RecordingProvider = { _ in Harness.recorder() }
        /// Read at every detection, like the setting.
        var recordWithoutAsking: [String] = []
        private(set) var recorderStarts = 0
        private(set) var phases: [WatchLoop.State] = []
        /// When each move into `.recording` happened, and why.
        private(set) var recordingStartTimes: [TimeInterval] = []
        private(set) var recordingStartCauses: [PhaseChangeCause] = []
        private(set) weak var loop: WatchLoop?

        func makeLoop(
            queue: PipelineQueue? = nil,
            declineCooldown: TimeInterval = 600,
            recordOnlyTo outputDir: URL? = nil,
        ) -> WatchLoop {
            let sleepProvider: (TimeInterval) async -> Void = { interval in
                await self.clock.sleep(for: interval)
                await self.onTick(self, self.elapsed)
            }
            let loop = WatchLoop(
                detector: detector,
                recorderFactory: {
                    self.recorderStarts += 1
                    return self.nextRecorder(self)
                },
                pipelineQueue: queue,
                pollInterval: 1,
                endGracePeriod: 10,
                // Far beyond any test, so only what a test does ends a recording.
                maxDuration: 1_000_000,
                meetingEndCountdown: 5,
                recordOnly: { outputDir != nil },
                recordOnlyDestination: { .unscoped(outputDir ?? FileManager.default.temporaryDirectory) },
                recordWithoutAskingApps: { self.recordWithoutAsking },
                notifier: notifier,
                diagnostics: diagnostics,
                nowProvider: { self.clock.now },
                sleepProvider: sleepProvider,
                consentPolicy: BrowserConsentPolicy(declineCooldown: declineCooldown, expiryCooldown: 5),
            )
            loop.permissionChecker = { .allHealthy }
            loop.onStateChange = { [weak self] _, next, cause in
                guard let self else { return }
                phases.append(next)
                if next == .recording {
                    recordingStartTimes.append(elapsed)
                    recordingStartCauses.append(cause)
                }
            }
            self.loop = loop
            return loop
        }

        /// A recorder whose mix path has no file, so a recording cut back at
        /// the end of a call finds nothing to cut.
        static func recorder() -> MockRecorder {
            let recorder = MockRecorder()
            recorder.mixPath = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_mix.wav")
            return recorder
        }

        var elapsed: TimeInterval {
            clock.now.timeIntervalSince(Self.start)
        }

        var noticeLines: [String] {
            diagnostics.lines.filter { $0.level == .notice }.map(\.line)
        }

        /// The four lines this feature writes.
        var ignoredCallLines: [String] {
            noticeLines.filter { $0.hasPrefix("ignore_offer") || $0.hasPrefix("record_ignored") }
        }

        var promptTitles: [String] {
            notifier.prompts.map(\.title)
        }
    }

    /// The three places a person answers "Ignore", plus the automation hook
    /// (`POST /action/confirmBrowserConsent`), which resolves the parked
    /// prompt the same way.
    enum IgnorePath: CaseIterable {
        case notification
        case menu
        case promptWindow
        case automation
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    var tmpDir: URL!

    // Stored, so the meeting a loop records is equal to these: each one
    // built anew would carry its own `detectedAt`.
    let teams = DetectedMeeting(pattern: .teams, windowTitle: "Quarterly Review", ownerName: "Microsoft Teams", windowPID: 4242)
    let zoom = DetectedMeeting(pattern: .zoom, windowTitle: "Quarterly Review", ownerName: "zoom.us", windowPID: 4343)

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "record-ignored")
    }

    func ignored(_ app: String) -> RecordAgainOffer {
        RecordAgainOffer(identityKey: app, appName: app, kind: .ignoredCall)
    }

    /// Wait for the question about `app`, answer it "Ignore" through `path`,
    /// and wait until the answer has landed.
    func ignoreTheOpenQuestion(about app: String, _ harness: Harness, _ loop: WatchLoop, via path: IgnorePath = .notification) async {
        await waitFor(harness.notifier.isParked && loop.pendingConsentQuestion?.identityKey == app, timeout: .seconds(5))
        guard let question = loop.pendingConsentQuestion else {
            XCTFail("\(app) is asked about")
            return
        }
        switch path {
        case .notification: harness.notifier.answer(.declined)
        case .menu: XCTAssertTrue(loop.answerParkedConsent(question, granted: false), "\(path)")
        case .promptWindow: XCTAssertTrue(loop.answerParkedConsent(question, answer: .declined), "\(path)")
        case .automation: XCTAssertTrue(harness.notifier.resolveBrowserConsent(granted: false), "\(path)")
        }
        await waitFor(loop.pendingConsentQuestion == nil, timeout: .seconds(5))
    }

    // swiftlint:enable test_case_accessibility

    // MARK: - R1: the offer after each Ignore

    /// Each way to answer Ignore offers "Record" while the call runs, and the
    /// first poll that finds the signal gone takes the offer away.
    func testRecordIsOfferedAfterEachIgnoreUntilTheCallEnds() async {
        for path in IgnorePath.allCases {
            let harness = Harness()
            let loop = harness.makeLoop()
            harness.detector.call(teams)
            loop.start()
            await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop, via: path)

            await waitFor(!loop.recordAgainOffers.isEmpty, timeout: .seconds(5))
            XCTAssertEqual(loop.recordAgainOffers, [ignored("Microsoft Teams")], "\(path)")
            XCTAssertEqual(harness.ignoredCallLines, ["ignore_offer_set app=Microsoft Teams"], "\(path): the key only, no title")
            XCTAssertEqual(harness.promptTitles, ["Record Microsoft Teams meeting?"], "\(path): the quiet time stands")
            XCTAssertEqual(harness.recorderStarts, 0, "\(path)")
            XCTAssertTrue(loop.appsHeldFromDetection.isEmpty, "\(path): nothing is held out of detection")

            harness.detector.hangUp("Microsoft Teams")
            await waitFor(loop.recordAgainOffers.isEmpty, timeout: .seconds(5))
            XCTAssertTrue(loop.ignoredCalls.ignoredApps.isEmpty, "\(path): released")
            XCTAssertEqual(harness.ignoredCallLines.last, "ignore_offer_released app=Microsoft Teams", "\(path)")
            XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "\(path): a click from the menu shown before")
            loop.stop()
        }
    }

    /// No offer after a question that expired unanswered, after "Never for
    /// this app", or after the decline that Stop Watching or a manual start
    /// books for an open question.
    func testNoOfferAfterAnExpiredQuestionNeverOrADeclineThatStopWatchingOrAManualStartBooked() async throws {
        for answer in [ConsentAnswer.expired, .never] {
            let harness = Harness()
            let loop = harness.makeLoop()
            harness.detector.call(teams)
            loop.start()
            await waitFor(harness.notifier.isParked, timeout: .seconds(5))
            harness.notifier.answer(answer)
            await waitFor(loop.pendingConsentQuestion == nil, timeout: .seconds(5))
            let answeredAt = harness.elapsed
            await waitFor(harness.elapsed >= answeredAt + 3, timeout: .seconds(5))

            XCTAssertTrue(loop.ignoredCalls.ignoredApps.isEmpty, "\(answer)")
            XCTAssertTrue(loop.recordAgainOffers.isEmpty, "\(answer)")
            XCTAssertTrue(harness.ignoredCallLines.isEmpty, "\(answer)")
            loop.stop()
        }

        let stopped = Harness()
        let stoppedLoop = stopped.makeLoop()
        stopped.detector.call(teams)
        stoppedLoop.start()
        await waitFor(stopped.notifier.isParked, timeout: .seconds(5))
        stoppedLoop.stop()
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertFalse(stopped.notifier.isParked, "precondition: Stop Watching answered the prompt")
        XCTAssertTrue(stoppedLoop.ignoredCalls.ignoredApps.isEmpty, "Stop Watching")
        XCTAssertTrue(stopped.ignoredCallLines.isEmpty, "Stop Watching")

        let manual = Harness()
        let manualLoop = manual.makeLoop()
        manual.detector.call(teams)
        manualLoop.start()
        await waitFor(manual.notifier.isParked, timeout: .seconds(5))
        // This process, so the manual recording's monitor finds it alive.
        try await manualLoop.startManualRecording(pid: getpid(), appName: "Microsoft Teams", title: "By hand")
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertFalse(manual.notifier.isParked, "precondition: the manual start answered the prompt")
        XCTAssertTrue(manualLoop.isActive, "precondition: the loop records by hand")
        XCTAssertTrue(manualLoop.ignoredCalls.ignoredApps.isEmpty, "a manual start")
        XCTAssertTrue(manual.ignoredCallLines.isEmpty, "a manual start")
        manualLoop.stopManualRecording()
    }

    // MARK: - R2: the question comes back, and each answer decides

    /// The quiet time runs as before: the question comes back once it is
    /// over, and the offer hides while it is open. No answer leaves the entry,
    /// a new Ignore replaces it with the newer meeting, Never forgets it.
    func testTheQuestionComesBackAfterTheQuietTimeAndHidesTheOfferWhileItIsOpen() async {
        let harness = Harness()
        let loop = harness.makeLoop(declineCooldown: 20)
        harness.detector.call(teams)
        var answered = 0
        var offersWhileAskedAgain: [[RecordAgainOffer]] = []
        var keptWhileAskedAgain: [Set<String>] = []
        var clicksWhileAskedAgain: [Bool] = []
        var offersAfterTheExpiry: [[RecordAgainOffer]] = []
        var askedAt: [TimeInterval] = []
        harness.onTick = { h, t in
            guard let loop = h.loop, h.notifier.isParked, h.notifier.prompts.count > answered else {
                // Between the expired third question and the fourth.
                if answered == 3, offersAfterTheExpiry.isEmpty, let loop = h.loop, loop.pendingConsentQuestion == nil {
                    offersAfterTheExpiry.append(loop.recordAgainOffers)
                }
                return
            }
            answered = h.notifier.prompts.count
            askedAt.append(t)
            if answered > 1 {
                offersWhileAskedAgain.append(loop.recordAgainOffers)
                keptWhileAskedAgain.append(loop.ignoredCalls.ignoredApps)
            }
            switch answered {
            case 1: h.notifier.answer(.declined)

            case 2:
                clicksWhileAskedAgain.append(loop.recordAgain(identityKey: "Microsoft Teams"))
                h.notifier.answer(.declined)

            case 3: h.notifier.answer(.expired)

            default: h.notifier.answer(.never)
            }
        }
        loop.start()

        await waitFor(answered == 4 && loop.pendingConsentQuestion == nil, timeout: .seconds(5))
        let neverAt = harness.elapsed
        await waitFor(harness.elapsed >= neverAt + 30, timeout: .seconds(5))

        XCTAssertEqual(harness.promptTitles.count, 4, "Never: not asked again")
        XCTAssertGreaterThanOrEqual(askedAt[1] - askedAt[0], 20, "after the quiet time, as before")
        XCTAssertEqual(offersWhileAskedAgain, [[], [], []], "hidden while the question is open")
        XCTAssertEqual(keptWhileAskedAgain, [["Microsoft Teams"], ["Microsoft Teams"], ["Microsoft Teams"]], "but kept")
        XCTAssertEqual(clicksWhileAskedAgain, [false], "a click while the question is open changes nothing")
        XCTAssertEqual(offersAfterTheExpiry, [[ignored("Microsoft Teams")]], "no answer leaves the entry")
        XCTAssertTrue(loop.ignoredCalls.ignoredApps.isEmpty, "Never forgets it")
        XCTAssertTrue(loop.recordAgainOffers.isEmpty)
        XCTAssertEqual(harness.ignoredCallLines, ["ignore_offer_set app=Microsoft Teams", "ignore_offer_set app=Microsoft Teams"])
        XCTAssertEqual(harness.recorderStarts, 0)
        loop.stop()
    }

    /// The second Ignore keeps the newer meeting: a click records that one.
    func testALaterIgnoreReplacesTheEntryWithTheNewerMeeting() async {
        let harness = Harness()
        let loop = harness.makeLoop(declineCooldown: 10)
        let laterTeams = DetectedMeeting(pattern: .teams, windowTitle: "Quarterly Review, part 2", ownerName: "Microsoft Teams", windowPID: 4545)
        harness.detector.call(teams)
        loop.start()
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
        harness.detector.call(laterTeams)
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)

        XCTAssertEqual(loop.ignoredCalls.ignoredMeetings, [laterTeams])
        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        await waitFor(loop.state == .recording, timeout: .seconds(5))
        XCTAssertEqual(loop.currentMeeting, laterTeams, "the newer meeting, process and title")
        loop.stop()
    }

    /// Any recording of the app forgets its entry: "Record" on the question
    /// that came back, and a detection after the app was switched to Record
    /// Without Asking. Neither is the click's recording.
    func testAnyRecordingOfTheAppForgetsItsIgnoredCall() async {
        for viaSetting in [false, true] {
            let label = viaSetting ? "switched to Record Without Asking" : "Record on the returning question"
            let harness = Harness()
            let loop = harness.makeLoop(declineCooldown: 10)
            harness.detector.call(teams)
            loop.start()
            await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
            await waitFor(!loop.recordAgainOffers.isEmpty, timeout: .seconds(5))

            if viaSetting {
                harness.recordWithoutAsking = ["Microsoft Teams"]
            } else {
                await waitFor(harness.notifier.isParked, timeout: .seconds(5))
                harness.notifier.answer(.granted)
            }
            await waitFor(loop.state == .recording, timeout: .seconds(5))

            XCTAssertEqual(harness.recordingStartCauses, [.regular], label)
            XCTAssertTrue(loop.ignoredCalls.ignoredApps.isEmpty, "\(label): forgotten")
            XCTAssertEqual(harness.ignoredCallLines, ["ignore_offer_set app=Microsoft Teams"], label)
            XCTAssertTrue(loop.stopDetectedRecording(), label)
            await waitFor(loop.state == .watching, timeout: .seconds(5))
            XCTAssertEqual(loop.recordAgainOffers, [RecordAgainOffer(identityKey: "Microsoft Teams", appName: "Microsoft Teams")], "\(label): held")
            loop.stop()
        }
    }

    // MARK: - R3: the click

    /// Clicked between two polls, the recording of the ignored meeting starts
    /// at the next one, with no question and no confirmation polls, and the
    /// loop marks it as the click's.
    func testAClickRecordsTheIgnoredMeetingAtTheNextPollWithoutAsking() async {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        var accepted = false
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            if h.notifier.isParked { h.notifier.answer(.declined) }
            if t == 6 { accepted = loop.recordAgain(identityKey: "Microsoft Teams") }
        }
        loop.start()

        await waitFor(harness.recorderStarts == 1 && loop.state == .recording, timeout: .seconds(5))
        XCTAssertTrue(accepted)
        XCTAssertEqual(harness.recordingStartTimes, [6], "at the poll after the click")
        XCTAssertEqual(harness.recordingStartCauses, [.recordAgain])
        XCTAssertEqual(loop.currentMeeting, teams, "the same meeting, process and title")
        XCTAssertEqual(harness.promptTitles, ["Record Microsoft Teams meeting?"], "not asked again")
        XCTAssertEqual(harness.detector.confirmedMarks, ["Microsoft Teams"])
        XCTAssertTrue(loop.ignoredCalls.ignoredApps.isEmpty, "the entry is lifted")
        XCTAssertTrue(loop.recordAgainOffers.isEmpty)
        XCTAssertEqual(
            harness.noticeLines,
            ["ignore_offer_set app=Microsoft Teams", "record_ignored app=Microsoft Teams", "meeting_title_rank at=detection rank=4 parts=1"],
        )
        loop.stop()
    }
}

// MARK: - R4, R5: the recording ends like a detected one

/// Kept outside the class body, which is at SwiftLint's `type_body_length`.
extension WatchLoopRecordIgnoredTests {
    /// The click's recording ends with the call and makes one job, and the
    /// app's next call is asked about although the Ignore was less than ten
    /// minutes before. Without the click the quiet time runs as before.
    func testTheNextCallIsAskedAboutAfterTheIgnoredCallWasRecorded() async {
        for clicked in [true, false] {
            let label = clicked ? "recorded" : "not recorded"
            let harness = Harness()
            let queue = PipelineQueue(logDir: tmpDir)
            let loop = harness.makeLoop(queue: queue)
            harness.detector.call(teams)
            loop.start()
            await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
            if clicked {
                await waitFor(!loop.recordAgainOffers.isEmpty, timeout: .seconds(5))
                XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"), label)
                await waitFor(loop.state == .recording, timeout: .seconds(5))
            }

            harness.detector.hangUp("Microsoft Teams")
            await waitFor(loop.state == .watching && queue.jobs.count == (clicked ? 1 : 0) && loop.ignoredCalls.ignoredApps.isEmpty, timeout: .seconds(5))
            XCTAssertEqual(queue.jobs.count, clicked ? 1 : 0, "\(label): one job")
            XCTAssertEqual(
                harness.diagnostics.lines(.notice, startingWith: "recording_auto_stop").count, clicked ? 1 : 0,
                "\(label): ended by the end grace and its question",
            )
            XCTAssertTrue(loop.appsHeldFromDetection.isEmpty, "\(label): no hold is left")
            XCTAssertTrue(loop.recordAgainOffers.isEmpty, label)

            harness.detector.call(teams)
            let calledAt = harness.elapsed
            await waitFor(harness.notifier.prompts.count == 2 || harness.elapsed >= calledAt + 10, timeout: .seconds(5))
            XCTAssertLessThan(harness.elapsed, 600, "\(label): precondition: within the ten minutes")
            XCTAssertEqual(harness.notifier.prompts.count, clicked ? 2 : 1, "\(label): asked about as usual only after the click")
            XCTAssertEqual(harness.recorderStarts, clicked ? 1 : 0, label)
            loop.stop()
        }
    }

    /// Stopped by hand while the signal stays, the app is held and "Record
    /// Again" is offered for it, as after any detected recording.
    func testStoppedByHandTheAppIsHeldAndRecordAgainIsOffered() async {
        let harness = Harness()
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        harness.detector.call(teams)
        loop.start()
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
        await waitFor(!loop.recordAgainOffers.isEmpty, timeout: .seconds(5))
        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        await waitFor(loop.state == .recording, timeout: .seconds(5))

        XCTAssertTrue(loop.stopDetectedRecording())
        await waitFor(loop.state == .watching && queue.jobs.count == 1, timeout: .seconds(5))

        XCTAssertEqual(queue.jobs.map(\.meetingTitle), ["Quarterly Review"])
        XCTAssertEqual(loop.appsHeldFromDetection, ["Microsoft Teams"])
        XCTAssertEqual(loop.recordAgainOffers, [RecordAgainOffer(identityKey: "Microsoft Teams", appName: "Microsoft Teams")])
        loop.stop()
    }

    /// Record-only: the click's WAVs and sidecar are written as a detected
    /// meeting's, labelled `auto` (A5).
    func testRecordOnlyWritesTheClicksRecordingWithAnAutoTrigger() async throws {
        let harness = Harness()
        let recorder = try makeRecorderWithTracks(basename: "20261116_100000")
        harness.nextRecorder = { _ in recorder }
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue, recordOnlyTo: outputDir)
        harness.detector.call(teams)
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            if h.notifier.isParked { h.notifier.answer(.declined) }
            if t == 4 { loop.recordAgain(identityKey: "Microsoft Teams") }
            if t == 6 { loop.stopDetectedRecording() }
        }
        loop.start()

        await waitFor(loop.state == .watching && recorder.stopCalled, timeout: .seconds(5))
        loop.stop()

        XCTAssertEqual(harness.recordingStartCauses, [.recordAgain])
        XCTAssertTrue(queue.jobs.isEmpty, "record-only enqueues no job")
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: outputDir, basename: "20261116_100000"))
        XCTAssertEqual(sidecar.trigger, .auto)
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("20261116_100000\(suffix)").path))
        }
    }

    /// Three 5 s, 16 kHz tracks under `basename`, shaped like a dual-source
    /// recording, so record-only has files to write out.
    private func makeRecorderWithTracks(basename: String) throws -> MockRecorder {
        let recorder = MockRecorder()
        let samples = (0 ..< 5 * 16000).map { Float($0 % 1000) / 2000 }
        var urls: [URL] = []
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let url = tmpDir.appendingPathComponent("\(basename)\(suffix)")
            try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: url)
            urls.append(url)
        }
        recorder.mixPath = urls[0]
        recorder.appPath = urls[1]
        recorder.micPath = urls[2]
        return recorder
    }
}
