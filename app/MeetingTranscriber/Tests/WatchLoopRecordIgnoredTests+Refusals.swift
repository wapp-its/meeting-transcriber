@testable import MeetingTranscriber
import XCTest

/// "Record (<App>)" clicks that start nothing, and recordings that fail: the
/// call ended before the poll, a stale menu, two clicks, a failed start, the
/// error state, another app's approved answer, and Stop Watching. Driven
/// through the real poll loop like the rest of this class.
extension WatchLoopRecordIgnoredTests {
    /// The call ends after the click and before the poll: that poll releases
    /// the entry first, then drops the click.
    func testAClickForACallThatEndedBeforeThePollIsDropped() async {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        var accepted = false
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            if h.notifier.isParked { h.notifier.answer(.declined) }
            if t == 5 {
                accepted = loop.recordAgain(identityKey: "Microsoft Teams")
                h.detector.hangUp("Microsoft Teams")
            }
        }
        loop.start()

        await waitFor(harness.elapsed >= 9, timeout: .seconds(5))
        XCTAssertTrue(accepted, "precondition: taken while the entry stood")
        XCTAssertEqual(harness.recorderStarts, 0, "nothing records")
        XCTAssertNil(loop.recordAgainRequest)
        XCTAssertEqual(harness.noticeLines, [
            "ignore_offer_set app=Microsoft Teams", "ignore_offer_released app=Microsoft Teams",
            "record_ignored_dropped app=Microsoft Teams",
        ])
        loop.stop()
    }

    /// A click whose entry is not there, or that comes while the loop is not
    /// watching, is refused and leaves no trace. (After the release, and
    /// while the question is asked again, in the R1 and R2 tests.)
    func testAClickFromAStaleMenuChangesNothingAndLogsNothing() async {
        let harness = Harness()
        harness.recordWithoutAsking = ["Zoom"]
        let loop = harness.makeLoop()
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "idle")
        harness.detector.call(teams)
        loop.start()
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
        XCTAssertFalse(loop.recordAgain(identityKey: "Zoom"), "an app that was not ignored")

        harness.detector.call(zoom)
        await waitFor(loop.state == .recording, timeout: .seconds(5))
        XCTAssertEqual(loop.ignoredCalls.ignoredApps, ["Microsoft Teams"], "precondition: still ignored")
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "while another recording runs")
        XCTAssertNil(loop.recordAgainRequest)
        loop.stop()
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "after Stop Watching")

        XCTAssertEqual(harness.recorderStarts, 1)
        XCTAssertEqual(harness.ignoredCallLines, ["ignore_offer_set app=Microsoft Teams"])
    }

    /// An ignored call next to a held one: one line each, by name. Clicks
    /// before the poll: a repeat keeps the one request, another app's is
    /// refused, and one recording starts; the held app stays held.
    func testTwoClicksBeforeThePollStartOneRecording() async {
        let harness = Harness()
        harness.recordWithoutAsking = ["Zoom"]
        let loop = harness.makeLoop()
        harness.detector.call(zoom)
        loop.start()
        await waitFor(loop.state == .recording, timeout: .seconds(5))
        XCTAssertTrue(loop.stopDetectedRecording())
        await waitFor(loop.state == .watching && loop.appsHeldFromDetection == ["Zoom"], timeout: .seconds(5))
        harness.detector.call(teams)
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
        await waitFor(loop.recordAgainOffers.count == 2, timeout: .seconds(5))
        XCTAssertEqual(loop.recordAgainOffers, [ignored("Microsoft Teams"), RecordAgainOffer(identityKey: "Zoom", appName: "Zoom")])

        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"), "a repeat keeps the one request")
        XCTAssertFalse(loop.recordAgain(identityKey: "Zoom"), "the next poll starts one recording")
        await waitFor(harness.recorderStarts == 2, timeout: .seconds(5))
        let startedAt = harness.elapsed
        await waitFor(harness.elapsed >= startedAt + 3, timeout: .seconds(5))

        XCTAssertEqual(harness.recorderStarts, 2)
        XCTAssertEqual(loop.currentMeeting, teams)
        XCTAssertEqual(harness.recordingStartCauses, [.regular, .recordAgain])
        XCTAssertEqual(harness.ignoredCallLines, ["ignore_offer_set app=Microsoft Teams", "record_ignored app=Microsoft Teams"])
        XCTAssertEqual(loop.appsHeldFromDetection, ["Zoom"])
        loop.stop()
    }

    /// Reported as any detected meeting's failed start; the entry is not put
    /// back, and since the click ended the quiet time, the still-running call
    /// is asked about anew after the error pause (A7).
    func testARecorderThatFailsToStartIsReportedAndTheCallIsAskedAboutAnew() async {
        let harness = Harness()
        harness.nextRecorder = { _ in ThrowingRecorder() }
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        var lastErrorDuringError: String?
        var offersDuringError: [[RecordAgainOffer]] = []
        harness.onTick = { h, _ in
            guard let loop = h.loop, loop.state == .error else { return }
            lastErrorDuringError = loop.lastError
            offersDuringError.append(loop.recordAgainOffers)
        }
        harness.detector.call(teams)
        loop.start()
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
        await waitFor(!loop.recordAgainOffers.isEmpty, timeout: .seconds(5))
        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        await waitFor(harness.notifier.prompts.count == 2, timeout: .seconds(5))

        XCTAssertEqual(harness.phases, [.watching, .recording, .error, .watching])
        XCTAssertNotNil(lastErrorDuringError, "reported as for any detected meeting")
        XCTAssertFalse(offersDuringError.isEmpty, "precondition: the error state was seen")
        XCTAssertTrue(offersDuringError.allSatisfy(\.isEmpty), "no offer while the loop is in its error state")
        XCTAssertEqual(harness.promptTitles, ["Record Microsoft Teams meeting?", "Record Microsoft Teams meeting?"], "asked about anew")
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "ignore_offer_set").count, 1, "the entry is not put back")
        XCTAssertTrue(loop.ignoredCalls.ignoredApps.isEmpty)
        XCTAssertEqual(queue.jobs.count, 0, "no job for the failed start")
        loop.stop()
    }

    /// Teams' entry stands while the loop goes into its error state for
    /// another app's failed start: no offer then, and the offer shows again
    /// once it watches again.
    func testNoOfferWhileTheLoopIsInItsErrorState() async {
        let harness = Harness()
        harness.recordWithoutAsking = ["Zoom"]
        harness.nextRecorder = { h in h.recorderStarts == 1 ? ThrowingRecorder() as any RecordingProvider : Harness.recorder() }
        let loop = harness.makeLoop()
        var offersDuringError: [[RecordAgainOffer]] = []
        harness.onTick = { h, _ in
            if let loop = h.loop, loop.state == .error { offersDuringError.append(loop.recordAgainOffers) }
        }
        harness.detector.call(teams)
        loop.start()
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
        harness.detector.call(zoom)
        await waitFor(harness.recorderStarts == 2 && loop.state == .recording, timeout: .seconds(5))
        harness.detector.hangUp("Zoom")
        await waitFor(loop.state == .watching && !loop.recordAgainOffers.isEmpty, timeout: .seconds(5))

        XCTAssertFalse(offersDuringError.isEmpty, "precondition: the error state was seen")
        XCTAssertTrue(offersDuringError.allSatisfy(\.isEmpty))
        XCTAssertEqual(loop.recordAgainOffers, [ignored("Microsoft Teams")])
        loop.stop()
    }

    /// Zoom's question is answered Record while Teams is ignored, and the
    /// Teams click wins the poll. The answer is dropped without a decline:
    /// once the click's recording ends, Zoom's call is asked about again,
    /// not recorded on the old answer.
    func testAnApprovedAnswerForAnotherAppIsDroppedWhenAClickStartsARecording() async {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        var approvedBeforeTheClick = false
        var clicked = false
        harness.onTick = { h, _ in
            guard let loop = h.loop, h.notifier.isParked else { return }
            if loop.pendingConsentQuestion?.identityKey == "Microsoft Teams" {
                h.notifier.answer(.declined)
                h.detector.call(self.zoom)
            } else if !clicked, loop.pendingConsentQuestion?.identityKey == "Zoom" {
                h.notifier.answer(.granted)
                for _ in 0 ..< 50 where loop.approvedConsentMeeting == nil {
                    await Task.yield()
                }
                approvedBeforeTheClick = loop.approvedConsentMeeting?.pattern == .zoom
                clicked = loop.recordAgain(identityKey: "Microsoft Teams")
            }
        }
        loop.start()

        await waitFor(loop.state == .recording, timeout: .seconds(5))
        XCTAssertTrue(approvedBeforeTheClick, "precondition: Zoom's approval waited at the click's poll")
        XCTAssertTrue(clicked)
        XCTAssertEqual(loop.currentMeeting, teams, "the click won the poll")
        XCTAssertEqual(harness.recordingStartCauses, [.recordAgain])
        harness.detector.hangUp("Microsoft Teams")
        await waitFor(harness.notifier.prompts.count == 3, timeout: .seconds(5))

        XCTAssertEqual(harness.promptTitles, ["Record Microsoft Teams meeting?", "Record Zoom meeting?", "Record Zoom meeting?"], "asked about again")
        XCTAssertEqual(harness.recorderStarts, 1, "not recorded on the dropped answer")
        loop.stop()
    }

    /// Stop Watching between the click and the poll discards the click with
    /// every entry; watching again records nothing on it.
    func testStopWatchingDiscardsTheIgnoredCallsAndAParkedClick() async {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        loop.start()
        await ignoreTheOpenQuestion(about: "Microsoft Teams", harness, loop)
        await waitFor(!loop.recordAgainOffers.isEmpty, timeout: .seconds(5))

        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        loop.stop()
        XCTAssertNil(loop.recordAgainRequest)
        XCTAssertTrue(loop.ignoredCalls.ignoredApps.isEmpty)
        XCTAssertTrue(loop.recordAgainOffers.isEmpty)

        loop.start()
        let restartedAt = harness.elapsed
        await waitFor(harness.elapsed >= restartedAt + 5, timeout: .seconds(5))
        XCTAssertEqual(harness.recorderStarts, 0, "not the discarded click")
        XCTAssertTrue(loop.recordAgainOffers.isEmpty)
        XCTAssertEqual(harness.ignoredCallLines, ["ignore_offer_set app=Microsoft Teams"])
        loop.stop()
    }
}
