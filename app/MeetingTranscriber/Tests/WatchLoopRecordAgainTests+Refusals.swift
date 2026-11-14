@testable import MeetingTranscriber
import XCTest

/// "Record Again" clicks that start nothing, and recordings that fail: the
/// call ended before the poll, a stale menu, two clicks, a failed start, the
/// error state, another app's approved answer, and Stop Watching. Driven
/// through the real poll loop like the rest of this class.
extension WatchLoopRecordAgainTests {
    /// The call ends after the click and before the poll: that poll releases
    /// the hold first, then drops the click.
    func testAClickForACallThatEndedBeforeThePollIsDropped() async {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        var accepted = false
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            if t == 5 { loop.stopDetectedRecording() }
            if t == 8 {
                accepted = loop.recordAgain(identityKey: "Microsoft Teams")
                h.detector.hangUp("Microsoft Teams")
            }
        }
        loop.start()

        await waitFor(harness.elapsed >= 12, timeout: .seconds(5))
        XCTAssertTrue(accepted, "precondition: taken while the hold stood")
        XCTAssertEqual(harness.recorderStarts, 1, "nothing records")
        XCTAssertNil(loop.recordAgainRequest)
        XCTAssertEqual(harness.noticeLines, [
            "recording_stopped_by_hand trigger=auto", "redetect_hold_set app=Microsoft Teams",
            "redetect_hold_released app=Microsoft Teams", "record_again_dropped app=Microsoft Teams",
        ])
        loop.stop()
    }

    /// A click whose hold is not there, or that comes while the loop is not
    /// watching, is refused and leaves no trace. (After the release, and for
    /// a call held on resume, in the R1 tests.)
    func testAClickFromAStaleMenuChangesNothingAndLogsNothing() async {
        let harness = Harness()
        let loop = harness.makeLoop(recordWithoutAsking: ["Microsoft Teams", "Zoom"])
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "idle")
        harness.detector.call(teams)
        loop.start()
        await stopByHand("Microsoft Teams", loop)
        XCTAssertFalse(loop.recordAgain(identityKey: "Zoom"), "an app that is not held")

        harness.detector.call(zoom)
        await waitFor(loop.state == .recording, timeout: .seconds(5))
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "while a recording runs")
        XCTAssertNil(loop.recordAgainRequest)
        loop.stop()
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "after Stop Watching")

        XCTAssertEqual(harness.recorderStarts, 2)
        XCTAssertTrue(harness.recordAgainLines.isEmpty)
    }

    /// Clicks before the poll: a repeat keeps the one request, another app's
    /// is refused, and one recording starts.
    func testTwoClicksBeforeThePollStartOneRecording() async {
        let harness = Harness()
        let loop = harness.makeLoop(recordWithoutAsking: ["Microsoft Teams", "Zoom"])
        harness.detector.call(teams)
        loop.start()
        await stopByHand("Microsoft Teams", loop)
        harness.detector.call(zoom)
        await stopByHand("Zoom", loop)

        XCTAssertTrue(loop.recordAgain(identityKey: "Zoom"))
        XCTAssertTrue(loop.recordAgain(identityKey: "Zoom"), "a repeat keeps the one request")
        XCTAssertFalse(loop.recordAgain(identityKey: "Microsoft Teams"), "the next poll starts one recording")
        await waitFor(harness.recorderStarts == 3, timeout: .seconds(5))
        let startedAt = harness.elapsed
        await waitFor(harness.elapsed >= startedAt + 3, timeout: .seconds(5))

        XCTAssertEqual(harness.recorderStarts, 3)
        XCTAssertEqual(loop.currentMeeting, zoom)
        XCTAssertEqual(harness.recordAgainLines, ["record_again app=Zoom"])
        XCTAssertEqual(loop.appsHeldFromDetection, ["Microsoft Teams"])
        loop.stop()
    }

    /// Reported as any detected meeting's failed start; the hold is not put
    /// back, so the still-running call is detected anew after the error
    /// pause (A6).
    func testARecorderThatFailsToStartIsReportedAndTheCallIsDetectedAnew() async {
        let harness = Harness()
        harness.nextRecorder = { h in h.recorderStarts == 2 ? ThrowingRecorder() as any RecordingProvider : Harness.recorder() }
        let queue = PipelineQueue(logDir: tmpDir)
        let loop = harness.makeLoop(queue: queue)
        var lastErrorDuringError: String?
        harness.onTick = { h, _ in
            if h.loop?.state == .error { lastErrorDuringError = h.loop?.lastError }
        }
        harness.detector.call(teams)
        loop.start()
        await stopByHand("Microsoft Teams", loop)

        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        await waitFor(harness.recorderStarts == 3 && loop.state == .recording, timeout: .seconds(5))

        XCTAssertEqual(harness.phases, [.watching, .recording, .watching, .recording, .error, .watching, .recording])
        XCTAssertNotNil(lastErrorDuringError, "reported as for any detected meeting")
        XCTAssertEqual(harness.recordingStartCauses, [.regular, .recordAgain, .regular], "detected anew")
        let failedAt = harness.recordingStartTimes[1]
        XCTAssertGreaterThanOrEqual(harness.recordingStartTimes[2] - failedAt, 10, "after the error pause")
        XCTAssertEqual(harness.diagnostics.lines(.notice, startingWith: "redetect_hold_set").count, 1, "the hold is not put back")
        XCTAssertEqual(queue.jobs.count, 1, "no job for the failed start")
        loop.stop()
    }

    /// A recording whose stop failed: the loop sits in its error state with
    /// the hold already placed, and the offer shows only once it watches
    /// again.
    func testNoOfferWhileTheLoopIsInItsErrorState() async {
        let harness = Harness()
        harness.nextRecorder = { _ in MockRecorder() } // no mix path: the stop throws
        let loop = harness.makeLoop()
        var offersDuringError: [[RecordAgainOffer]] = []
        harness.onTick = { h, _ in
            if let loop = h.loop, loop.state == .error { offersDuringError.append(loop.recordAgainOffers) }
        }
        harness.detector.call(teams)
        loop.start()
        await stopByHand("Microsoft Teams", loop)

        XCTAssertFalse(offersDuringError.isEmpty, "precondition: the error state was seen")
        XCTAssertTrue(offersDuringError.allSatisfy(\.isEmpty))
        XCTAssertEqual(loop.recordAgainOffers.map(\.identityKey), ["Microsoft Teams"])
        loop.stop()
    }

    /// Zoom's answer arrives while Teams is held, and the Teams click wins
    /// the poll. The answer is dropped without a decline: Zoom's call ends
    /// and a new one starts during the recording, and once that recording
    /// ends the new call is asked about, not recorded on the old answer.
    func testAnApprovedAnswerForAnotherAppIsDroppedWhenAClickStartsARecording() async {
        let harness = Harness()
        harness.notifier.parksPrompts = true
        let loop = harness.makeLoop(recordWithoutAsking: ["Microsoft Teams"])
        harness.detector.call(teams)
        var approvedBeforeTheClick = false
        harness.onTick = { h, t in
            guard let loop = h.loop else { return }
            switch t {
            case 3: loop.stopDetectedRecording()

            case 4: h.detector.call(self.zoom)

            case 6:
                h.notifier.answerPrompt(.granted)
                for _ in 0 ..< 50 where loop.approvedConsentMeeting == nil {
                    await Task.yield()
                }
                approvedBeforeTheClick = loop.approvedConsentMeeting?.pattern == .zoom
                loop.recordAgain(identityKey: "Microsoft Teams")

            case 8: h.detector.hangUp("Zoom")

            case 9: h.detector.call(self.zoom)

            case 10: h.detector.hangUp("Microsoft Teams")

            default: break
            }
        }
        loop.start()

        await waitFor(harness.notifier.prompts.count == 2, timeout: .seconds(5))
        XCTAssertTrue(approvedBeforeTheClick, "precondition: Zoom's approval waited at the click's poll")
        XCTAssertEqual(harness.recordingStartCauses, [.regular, .recordAgain], "the click won the poll")
        XCTAssertEqual(harness.notifier.prompts, ["Record Zoom meeting?", "Record Zoom meeting?"], "asked about again")
        XCTAssertEqual(harness.recorderStarts, 2, "not recorded on the dropped answer")
        loop.stop()
    }

    /// Stop Watching between the click and the poll discards the click with
    /// the holds; watching again detects the call as usual.
    func testStopWatchingDiscardsAParkedClick() async {
        let harness = Harness()
        let loop = harness.makeLoop()
        harness.detector.call(teams)
        loop.start()
        await stopByHand("Microsoft Teams", loop)

        XCTAssertTrue(loop.recordAgain(identityKey: "Microsoft Teams"))
        loop.stop()
        XCTAssertNil(loop.recordAgainRequest)
        XCTAssertTrue(loop.recordAgainOffers.isEmpty)

        loop.start()
        await waitFor(harness.recorderStarts == 2, timeout: .seconds(5))
        XCTAssertEqual(harness.recordingStartCauses, [.regular, .regular], "detected, not the discarded click")
        XCTAssertTrue(harness.recordAgainLines.isEmpty)
        loop.stop()
    }
}
