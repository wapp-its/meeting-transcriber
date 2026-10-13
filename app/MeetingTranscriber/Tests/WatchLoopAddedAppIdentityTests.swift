@testable import MeetingTranscriber
import XCTest

/// An app added through "Add App…" under the name "Zoom", next to the built-in
/// Zoom: the consent gate files every answer, cooldown and open question
/// under each app's own identity key, while the person reads "Zoom" for both.
/// Driven through the real `start()` poll loop, like
/// `WatchLoopAskBeforeRecordingTests`, whose doubles it shares.
@MainActor
final class WatchLoopAddedAppIdentityTests: XCTestCase {
    private typealias ScriptedDetector = ConsentLoopDoubles.ScriptedDetector
    private typealias AnsweringNotifier = ConsentLoopDoubles.AnsweringNotifier
    private typealias ParkingNotifier = ConsentLoopDoubles.ParkingNotifier
    private typealias Recorders = ConsentLoopDoubles.Recorders

    private let addedKey = "custom:com.example.zoom"

    private var builtInZoom: DetectedMeeting {
        DetectedMeeting(pattern: .zoom, windowTitle: "Zoom Call", ownerName: "zoom.us", windowPID: 4321)
    }

    private var addedZoom: DetectedMeeting {
        let pattern = MicInputDetector.MicPattern(
            appName: "Zoom", bundleIDs: ["com.example.zoom"], matchesHelpers: true, usesBuiltInMeetingPattern: false,
        ).meetingPattern
        return DetectedMeeting(pattern: pattern, windowTitle: "Zoom Call", ownerName: "Zoom", windowPID: 4322)
    }

    private func makeLoop(
        detector: any MeetingDetecting,
        notifier: any AppNotifying,
    ) throws -> (WatchLoop, Recorders, InMemoryConsentDenyListStore) {
        let recorders = Recorders()
        let store = InMemoryConsentDenyListStore()
        let output = try makeTempDirectory(prefix: "added-app-identity")
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorders.make() },
            pollInterval: 0.05,
            endGracePeriod: 0.05,
            meetingEndCountdown: 0.05,
            recordOnlyDestination: { .unscoped(output) },
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

    /// Asks about `first` and answers `answer`; then `second`'s call starts
    /// too. `second` must still be asked about, and once that question is
    /// settled and its call is over, `first` must still be held off: a Never,
    /// a decline and an unanswered prompt each keep an app quiet for at least
    /// a minute, longer than the test runs.
    private func assertAnswer(
        _ answer: ConsentAnswer,
        about first: DetectedMeeting,
        leavesAsked second: DetectedMeeting,
    ) async throws -> InMemoryConsentDenyListStore {
        let label = "\(answer) about \(first.pattern.identityKey)"
        let notifier = ParkingNotifier()
        let detector = ScriptedDetector([first])
        let (loop, _, store) = try makeLoop(detector: detector, notifier: notifier)
        loop.start()
        await waitFor(notifier.isParked)
        notifier.answer(answer)

        // The answered app comes last: unlike the real detectors, the scripted
        // one keeps returning a denied or cooling-down app, which would hide
        // any app listed after it.
        detector.confirmed = [second, first]
        detector.running = [first.pattern.identityKey, second.pattern.identityKey]
        await waitFor(notifier.prompts.count == 2, timeout: .seconds(2))
        XCTAssertEqual(notifier.prompts.count, 2, "\(label): the same-named app is still asked about")
        XCTAssertEqual(loop.pendingConsent?.identityKey, second.pattern.identityKey, label)
        XCTAssertEqual(notifier.prompts.map(\.title), ["Record Zoom meeting?", "Record Zoom meeting?"], label)

        notifier.answer(.declined)
        detector.end(second.pattern.identityKey)
        await severalPolls()
        XCTAssertEqual(notifier.prompts.count, 2, "\(label): the answered app is still held off")
        loop.stop()
        return store
    }

    func testAnAnswerAboutTheBuiltInAppLeavesTheAddedAppAsked() async throws {
        for answer: ConsentAnswer in [.never, .declined, .expired] {
            let store = try await assertAnswer(answer, about: builtInZoom, leavesAsked: addedZoom)
            XCTAssertEqual(store.denyList.denied, answer == .never ? ["Zoom"] : [], "\(answer): the built-in is denied by its name, as before")
        }
    }

    func testAnAnswerAboutTheAddedAppLeavesTheBuiltInAppAsked() async throws {
        for answer: ConsentAnswer in [.never, .declined, .expired] {
            let store = try await assertAnswer(answer, about: addedZoom, leavesAsked: builtInZoom)
            XCTAssertEqual(store.denyList.denied, answer == .never ? [addedKey] : [], "\(answer): stored by its key, never its name")
        }
    }

    func testWhileTheAddedAppIsAskedAboutTheGateHoldsItsKeyAndShowsItsName() async throws {
        let notifier = ParkingNotifier()
        let detector = ScriptedDetector([addedZoom])
        let (loop, _, _) = try makeLoop(detector: detector, notifier: notifier)
        loop.start()
        await waitFor(notifier.isParked)
        XCTAssertEqual(notifier.prompts.map(\.title), ["Record Zoom meeting?"])
        XCTAssertEqual(loop.pendingConsentApp, "Zoom", "/state and /v1/watch show the name")
        XCTAssertEqual(loop.appsExcludedFromDetection, [addedKey])

        // The built-in Zoom's call waits for that answer, under its own key.
        detector.confirmed = [builtInZoom, addedZoom]
        detector.running.insert("Zoom")
        await waitFor(loop.appsExcludedFromDetection.count == 2)
        XCTAssertEqual(loop.appsExcludedFromDetection, [addedKey, "Zoom"])
        XCTAssertEqual(notifier.prompts.count, 1, "and is not asked about while the question is open")

        notifier.answer(.declined)
        await waitFor(notifier.prompts.count == 2, timeout: .seconds(2))
        XCTAssertEqual(loop.pendingConsent?.identityKey, "Zoom", "then the built-in is asked about")
        XCTAssertEqual(Set(detector.resets), [addedKey], "the decline reset the detector by the added app's key")

        notifier.answer(.declined)
        loop.stop()
    }

    func testAGrantedAddedAppRecordsUnderItsNameAndResetsByItsKey() async throws {
        let detector = ScriptedDetector([addedZoom])
        let (loop, recorders, _) = try makeLoop(detector: detector, notifier: AnsweringNotifier(.granted))
        loop.start()
        await waitFor(recorders.starts == 1)
        XCTAssertEqual(loop.currentMeeting?.pattern.appName, "Zoom")
        XCTAssertEqual(loop.currentMeeting?.pattern.identityKey, addedKey)

        detector.end(addedKey)
        await waitFor(!detector.resets.isEmpty, timeout: .seconds(2))
        XCTAssertEqual(detector.resets, [addedKey], "the reset after the recording carries the key")
        loop.stop()
    }
}
