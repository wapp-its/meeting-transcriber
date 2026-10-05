import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoopConsent")

/// Recording-consent gate, split out of `WatchLoop` to keep its body under the
/// line-length cap. Every detected meeting passes through it: a meeting asks
/// before recording unless its app records without asking
/// (`AppMeetingPattern.asksBeforeRecording`), and browser meetings always ask
/// (issue #503).
///
/// The answer is awaited in its own task rather than inline in the poll loop
/// (issue #543). Inline, `detector.checkOnce()` was not called at all while a
/// prompt was open — up to `NotificationManager.consentPromptTimeout` of not
/// looking, during which a call that needs no prompt went unnoticed. Google
/// Meet raises the same WebRTC assertion on a page you cannot even join, so a
/// stale link was enough to freeze detection for a minute.
extension WatchLoop {
    /// Whether this meeting has to wait for the user instead of recording now.
    /// Returns immediately in every case.
    ///
    /// True also covers "we are already asking about another app", "a recent
    /// decline still suppresses the question" and "the user said never for
    /// this app" — all reasons to skip the meeting, none a reason to ask again.
    func requestConsentIfNeeded(for meeting: DetectedMeeting) -> Bool {
        let app = meeting.pattern.appName
        let isDenied = denyListStore.isDenied(app)
        // A denial outranks "record without asking": Never is the user's word
        // about the app, so it is checked by the policy below even for an app
        // that would otherwise record at once.
        if !isDenied, !meeting.pattern.asksBeforeRecording(recordWithoutAsking: recordWithoutAskingApps()) {
            return false
        }
        // One question at a time. The detector re-detects the same call every
        // poll, so without this the loop would post a fresh prompt every few
        // seconds while the first one is still on screen. Another app that
        // needs a prompt is not queued either: it is detected again once this
        // question is settled, and asked about then if its call still runs.
        guard pendingConsentApp == nil else { return true }

        guard case .ask = consentPolicy.decision(
            app: app, now: nowProvider(), isDenied: isDenied,
        ) else {
            detector.reset(appName: app) // re-detect after the debounce
            return true
        }

        pendingConsentApp = app
        // `app` is the concrete app: a browser meeting is carried under the
        // process that held the assertion, so the debounce above and the name
        // below refer to the same one browser. `ownerName` is the fallback
        // because an empty identity would otherwise produce a prompt naming
        // nothing at all.
        let appLabel = app.isEmpty ? meeting.ownerName : app
        consentTask = Task { [weak self] in
            guard let self else { return }
            let answer = await notifier.askToRecord(
                title: "Record \(appLabel) meeting?",
                body: "A meeting is active in \(appLabel).",
            )
            finishConsent(for: meeting, answer: answer)
        }
        return true
    }

    /// Take the approved meeting, if any, clearing it. The poll loop is the
    /// only caller: recordings start there and nowhere else, so two of them
    /// cannot overlap.
    func takeApprovedConsentMeeting() -> DetectedMeeting? {
        defer { approvedConsentMeeting = nil }
        return approvedConsentMeeting
    }

    /// Answer a parked prompt as a decline, for `stop()`. Routed through the
    /// notifier so the real prompt's parked continuation completes; without it
    /// the question would linger for the rest of its timeout.
    func declineParkedConsent() {
        guard pendingConsentApp != nil else { return }
        _ = notifier.resolveBrowserConsent(granted: false)
        // Cleared regardless of whether anything was waiting: a notifier with
        // no coordinator behind it never resolves, and a prompt stuck
        // "pending" forever would silence every future question.
        clearConsentState()
    }

    /// Land the user's answer. Main-actor isolated like the rest of
    /// `WatchLoop`, so it cannot race the poll loop's reads.
    private func finishConsent(for meeting: DetectedMeeting, answer: ConsentAnswer) {
        let app = meeting.pattern.appName
        clearConsentState()

        guard answer.isGranted else {
            // A refusal and a prompt nobody saw are different facts, and the
            // cooldown treats them differently: ten minutes of quiet after a
            // no, one minute after silence. Never is a third fact and outlives
            // both, and takes no cooldown of its own.
            switch answer {
            case .expired:
                consentPolicy.recordExpiry(app: app, now: nowProvider())

            case .never:
                // No decline cooldown alongside it. The denial already
                // suppresses, and a cooldown would outlive a Settings "Remove"
                // by up to ten minutes, so undoing a mistaken Never would
                // silently keep doing nothing.
                denyListStore.deny(app)

            default:
                consentPolicy.recordDecline(app: app, now: nowProvider())
            }
            detector.reset(appName: app)
            return
        }
        // Minutes can pass between prompt and click, and watching may have been
        // switched off in between — recording then would be recording without
        // having been asked to watch at all.
        guard isActive else {
            logger.info("Consent granted for \(app, privacy: .public) after watching stopped — ignoring")
            return
        }
        // An approval is not a reservation. Another app's call may have
        // started recording while the question was open (it needed no
        // prompt), and only one recording runs at a time; holding the answer
        // until that one ends would start a recording long after the user
        // agreed to it, on the strength of an answer about a moment that has
        // passed. Drop it: if this call is still running once the recorder is
        // free, it is detected and asked about again.
        guard state != .recording else {
            logger.info("Consent granted for \(app, privacy: .public) while another meeting is recording — dropped")
            return
        }
        // The call itself may also have ended while the question sat there.
        guard detector.isMeetingActive(meeting) else {
            detector.reset(appName: app)
            return
        }
        approvedConsentMeeting = meeting
    }
}
