@testable import AudioTapLib
import AVFoundation
import CoreAudio
import XCTest

/// Pinning a microphone moves the engine's input unit off AVAudioEngine's own
/// default-device aggregate, and AVAudioEngine answers that move with an
/// `AVAudioEngineConfigurationChange` of its own a little later. When that
/// notification reaches an engine that has already started, the engine has
/// stopped itself and the capture handler restarts it, whose pin posts the next
/// one: a restart loop that never delivers a buffer. `MicPinSettle` spends the
/// pin's own notification before the engine starts.
///
/// Everything here runs against a private `NotificationCenter` and a stand-in
/// object, never a real engine: the CI runner has no input device, and reading
/// `AVAudioEngine.inputNode` there raises an uncatchable NSException. That the
/// session wires this around its real pin is the owner's headset check.
final class MicPinSettleTests: XCTestCase {
    /// What the notification is keyed on in production is the engine; any
    /// object does here. Sendable so a test can post for it from another queue.
    private final class StandInEngine: Sendable {}

    /// Records which observers were added and removed, and counts deliveries to
    /// them, so a test can tell an observer that was removed from one that
    /// merely stopped being waited on.
    private final class RecordingCenter: NotificationCenter, @unchecked Sendable {
        private let lock = NSLock()
        private var addedTokens: [AnyObject] = []
        private var removedTokens: [AnyObject] = []
        private var deliveryCount = 0

        var added: [AnyObject] {
            lock.withLock { addedTokens }
        }

        var removed: [AnyObject] {
            lock.withLock { removedTokens }
        }

        var deliveries: Int {
            lock.withLock { deliveryCount }
        }

        override func addObserver(
            forName name: Notification.Name?,
            object obj: Any?,
            queue: OperationQueue?,
            using block: @escaping @Sendable (Notification) -> Void,
        ) -> any NSObjectProtocol {
            let token = super.addObserver(forName: name, object: obj, queue: queue) { [weak self] note in
                self?.countDelivery()
                block(note)
            }
            lock.withLock { addedTokens.append(token) }
            return token
        }

        private func countDelivery() {
            lock.withLock { deliveryCount += 1 }
        }

        override func removeObserver(_ observer: Any) {
            lock.withLock { removedTokens.append(observer as AnyObject) }
            super.removeObserver(observer)
        }
    }

    private func post(_ center: NotificationCenter, for object: AnyObject) {
        center.post(name: .AVAudioEngineConfigurationChange, object: object)
    }

    // MARK: - Waiting for the pin's own change

    /// The production shape: the change arrives from AVFAudio's private queue a
    /// little after the pin returned.
    func testAChangePostedFromAnotherQueueSettles() {
        let center = NotificationCenter()
        let engine = StandInEngine()

        let outcome = MicPinSettle.run(observing: engine, center: center, timeout: 2) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                center.post(name: .AVAudioEngineConfigurationChange, object: engine)
            }
            return true
        }

        guard case let .settled(afterSeconds) = outcome else {
            XCTFail("a change 50 ms after the pin must settle, got \(outcome)")
            return
        }
        XCTAssertGreaterThanOrEqual(afterSeconds, 0.04, "it waited for the change, not past it")
        XCTAssertLessThan(afterSeconds, 2, "it returned when the change came, not at the timeout")
    }

    /// No change within the timeout: the engine starts anyway.
    func testNoChangeTimesOut() {
        let center = NotificationCenter()

        let outcome = MicPinSettle.run(observing: StandInEngine(), center: center, timeout: 0.05) { true }

        guard case let .timedOut(afterSeconds) = outcome else {
            XCTFail("no change must time out, got \(outcome)")
            return
        }
        XCTAssertGreaterThanOrEqual(afterSeconds, 0.04, "it waited the timeout out")
        XCTAssertLessThan(afterSeconds, 1)
    }

    /// Only the engine being pinned counts: every engine in the process posts
    /// under the same name, the outgoing one of a restart included.
    func testAChangeForAnotherObjectIsIgnored() {
        let center = NotificationCenter()
        let engine = StandInEngine()
        let otherEngine = StandInEngine()

        let outcome = MicPinSettle.run(observing: engine, center: center, timeout: 0.05) {
            self.post(center, for: otherEngine)
            return true
        }

        guard case .timedOut = outcome else {
            XCTFail("another engine's change must not settle this one, got \(outcome)")
            return
        }
    }

    /// The reason the observer is registered before the pin runs: a change
    /// posted inside the set itself must not be missed.
    func testAChangePostedInsideThePinCounts() {
        let center = NotificationCenter()
        let engine = StandInEngine()

        let outcome = MicPinSettle.run(observing: engine, center: center, timeout: 5) {
            self.post(center, for: engine)
            return true
        }

        guard case let .settled(afterSeconds) = outcome else {
            XCTFail("a change posted inside the pin must settle, got \(outcome)")
            return
        }
        XCTAssertLessThan(afterSeconds, 1, "it was already there, so nothing was waited for")
    }

    /// Nothing pinned, an unresolvable UID, or a unit already on the device:
    /// no change is coming, so nothing is waited for.
    func testAPinThatDidNotMoveTheUnitDoesNotWait() {
        let started = ContinuousClock.now

        let outcome = MicPinSettle.run(observing: StandInEngine(), center: NotificationCenter(), timeout: 5) {
            false
        }

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "it must not wait out the timeout")
    }

    /// The duration is the clock's, read after the pin returned and again when
    /// the wait ended, so it is how long the start was held up by the settle.
    func testTheDurationComesFromTheInjectedClock() {
        let center = NotificationCenter()
        let engine = StandInEngine()
        var readings: [TimeInterval] = [100, 100.125]

        let outcome = MicPinSettle.run(
            observing: engine, center: center, timeout: 5,
            clock: { readings.removeFirst() },
            pin: {
                self.post(center, for: engine)
                return true
            },
        )

        XCTAssertEqual(outcome, .settled(afterSeconds: 0.125))
    }

    // MARK: - The observer does not outlive the call

    /// A left-over observer would hold the stand-in engine and signal a
    /// semaphore nobody waits on for the rest of the process's life. Every
    /// path removes the observer it added, and a later post reaches nothing.
    func testTheObserverIsRemovedOnEveryPath() {
        let paths: [(name: String, postInsidePin: Bool, moved: Bool)] = [
            ("settled", true, true),
            ("timedOut", false, true),
            ("notNeeded", false, false),
        ]
        for path in paths {
            let center = RecordingCenter()
            let engine = StandInEngine()

            _ = MicPinSettle.run(observing: engine, center: center, timeout: 0.01) {
                if path.postInsidePin { self.post(center, for: engine) }
                return path.moved
            }

            XCTAssertEqual(center.added.count, 1, "\(path.name): one observer per run")
            XCTAssertEqual(center.removed.count, 1, "\(path.name): the observer must be removed")
            XCTAssertIdentical(center.added.first, center.removed.first, "\(path.name): the same observer")

            let deliveriesBefore = center.deliveries
            post(center, for: engine)
            XCTAssertEqual(center.deliveries, deliveriesBefore, "\(path.name): a later post reaches nothing")
        }
    }

    // MARK: - When a pin calls for a settle

    /// Only a set that was accepted and moved the unit off another device
    /// produces the change; every other start goes ahead at once. A unit whose
    /// device could not be read before the set might have moved, so it waits:
    /// the cost is the bounded timeout, against an engine the late change stops.
    func testOnlyAnAcceptedSetThatMovesTheUnitCallsForASettle() {
        let uid = "AppleUSBAudioEngine:Vendor:Headset:0123456789:1"
        let requested: AudioDeviceID = 42
        let cases: [(name: String, outcome: MicDevicePinOutcome, before: AudioDeviceID?, moved: Bool)] = [
            ("nothing pinned", .notRequested, nil, false),
            ("unresolvable UID", .unresolvedUID(uid), nil, false),
            (
                "refused",
                .set(uid: uid, requested: requested, status: kAudioUnitErr_InvalidPropertyValue, actual: 7),
                7, false,
            ),
            ("already on it", .set(uid: uid, requested: requested, status: noErr, actual: requested), requested, false),
            ("moved", .set(uid: uid, requested: requested, status: noErr, actual: requested), 7, true),
            ("unknown before", .set(uid: uid, requested: requested, status: noErr, actual: requested), nil, true),
        ]
        for entry in cases {
            XCTAssertEqual(
                MicPinSettle.pinMovedUnit(entry.outcome, deviceBefore: entry.before), entry.moved, entry.name,
            )
        }
    }

    // MARK: - What the log says

    func testTheLogLineWording() {
        XCTAssertNil(MicPinSettle.Outcome.notNeeded.logLine, "an unpinned start has nothing to report")
        XCTAssertEqual(
            MicPinSettle.Outcome.settled(afterSeconds: 0.1234).logLine,
            "Mic: the configured microphone's configuration change arrived 123 ms after binding it and was absorbed before the engine started",
        )
        XCTAssertEqual(
            MicPinSettle.Outcome.timedOut(afterSeconds: 0.5003).logLine,
            "Mic: no configuration change within 500 ms of binding the configured microphone; starting the engine anyway",
        )
    }

    /// The line is unconditional and lands in the exported diagnostics, so it
    /// must not name the device, whatever the pin it followed was given.
    func testNoLogLineCarriesTheDeviceUID() {
        let uid = "AppleUSBAudioEngine:Vendor:Headset:0123456789:1"
        let center = NotificationCenter()
        let engine = StandInEngine()
        var pinned: String?

        let settled = MicPinSettle.run(observing: engine, center: center, timeout: 5) {
            pinned = uid
            self.post(center, for: engine)
            return true
        }
        let timedOut = MicPinSettle.run(observing: engine, center: center, timeout: 0.01) {
            pinned = uid
            return true
        }

        XCTAssertEqual(pinned, uid)
        for line in [settled.logLine, timedOut.logLine].compactMap(\.self) {
            XCTAssertFalse(line.contains(uid), line)
            XCTAssertFalse(line.contains("0123456789"), line)
        }
    }
}
