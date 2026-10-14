import Foundation
@testable import MeetingTranscriber

/// Test doubles for driving the consent gate through the real `start()` poll
/// loop, shared by `WatchLoopAskBeforeRecordingTests` and
/// `WatchLoopAddedAppIdentityTests`.
///
/// Extracted rather than copied, like `PowerAssertionFixture`: two copies of a
/// scripted detector drift apart, and a drifted double tests nothing.
enum ConsentLoopDoubles {
    /// Confirms the meetings in `confirmed`, first one first, the way the real
    /// detectors do when several apps are in a call: a poll returns the first
    /// confirmed meeting that is not excluded. A call counts as running while
    /// its app is in `running`.
    ///
    /// Keyed by `pattern.identityKey`, as the real detectors are. That is the
    /// app name for every built-in app, so a test about built-ins can name
    /// them; an app added through "Add App…" is `custom:<bundleID>`.
    final class ScriptedDetector: MeetingDetecting {
        var confirmed: [DetectedMeeting]
        var running: Set<String>
        /// The key each `reset(appName:)` carried, in order.
        private(set) var resets: [String?] = []

        init(_ confirmed: [DetectedMeeting]) {
            self.confirmed = confirmed
            running = Set(confirmed.map(\.pattern.identityKey))
        }

        func checkOnce() -> DetectedMeeting? {
            checkOnce(excluding: [])
        }

        func checkOnce(excluding excludedApps: Set<String>) -> DetectedMeeting? {
            confirmed.first { !excludedApps.contains($0.pattern.identityKey) }
        }

        func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
            running.contains(meeting.pattern.identityKey)
        }

        func reset(appName: String?) {
            resets.append(appName)
        }

        /// The call in `app` is over: it is neither detected nor running.
        func end(_ app: String) {
            confirmed.removeAll { $0.pattern.identityKey == app }
            running.remove(app)
        }
    }

    /// Answers every prompt at once with a fixed answer and records what it was
    /// asked.
    final class AnsweringNotifier: AppNotifying {
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
    final class ParkingNotifier: AppNotifying {
        private(set) var prompts: [(title: String, body: String)] = []
        /// The id the parked prompt was asked under, as the real coordinator keys it.
        private(set) var parkedID: UUID?
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

        @MainActor
        func askToRecord(_ question: ConsentQuestion) async -> ConsentAnswer {
            parkedID = question.id
            return await askToRecord(title: question.title, body: question.body)
        }

        func answer(_ answer: ConsentAnswer) {
            let parked = continuation
            continuation = nil
            parkedID = nil
            parked?.resume(returning: answer)
        }

        func resolveBrowserConsent(granted: Bool) -> Bool {
            guard isParked else { return false }
            answer(granted ? .granted : .declined)
            return true
        }

        /// Answers only the prompt parked under `id`, like the real coordinator.
        func answerConsentPrompt(id: UUID, granted: Bool) -> Bool {
            guard isParked, parkedID == id else { return false }
            answer(granted ? .granted : .declined)
            return true
        }
    }

    /// Hands out a fresh recorder per recording, so a test can count starts.
    @MainActor
    final class Recorders {
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
}
