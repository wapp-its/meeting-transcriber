#if !APPSTORE

    import AppKit
    import Foundation
    import UserNotifications

    // MARK: - The meeting a notice names

    /// The meeting a local-model notice is about, with what its actions need:
    /// where the transcript is (Show Transcript), and the template and
    /// background its protocol was due with (Try Again, spec R4).
    struct LocalModelNoticeMeeting: Equatable, Sendable {
        let jobID: UUID
        let title: String
        let folder: URL
        let basename: String
        let template: ProtocolTemplateID
        /// Held in this process only, never written into a notification: the
        /// system keeps a notification's user info on disk, and background info
        /// is never logged, put in a warning or reported (see `PipelineJob`).
        let background: String?
        /// Whether the job had background info, also once `background` is gone
        /// (a notice answered after the app restarted).
        let hadBackground: Bool

        init(jobID: UUID, title: String, folder: URL, basename: String, template: ProtocolTemplateID, background: String?) {
            let trimmed = background?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.init(
                jobID: jobID, title: title, folder: folder, basename: basename, template: template,
                background: trimmed.isEmpty ? nil : trimmed, hadBackground: !trimmed.isEmpty,
            )
        }

        private init(
            jobID: UUID, title: String, folder: URL, basename: String,
            template: ProtocolTemplateID, background: String?, hadBackground: Bool,
        ) {
            (self.jobID, self.title, self.folder, self.basename) = (jobID, title, folder, basename)
            (self.template, self.background, self.hadBackground) = (template, background, hadBackground)
        }

        var transcriptURL: URL {
            folder.appendingPathComponent("\(basename).txt")
        }

        var protocolURL: URL {
            folder.appendingPathComponent("\(basename).md")
        }

        /// This meeting with `background`, or as it is when `background` is nil.
        func restoring(background: String?) -> Self {
            guard let background else { return self }
            return Self(
                jobID: jobID, title: title, folder: folder, basename: basename,
                template: template, background: background, hadBackground: true,
            )
        }

        static let userInfoKey = "localModelMeetings"

        /// The user info a notice naming `meetings` carries: the meeting's
        /// target (folder and basename), job id, title and template, never its
        /// background. A notice on screen outlives the app, so a later version
        /// may read this; an entry it cannot read is left out (`meetings(in:)`).
        static func userInfo(for meetings: [Self]) -> [AnyHashable: Any] {
            let entries: [[String: Any]] = meetings.map { meeting in
                [
                    "jobID": meeting.jobID.uuidString, "title": meeting.title, "folder": meeting.folder.path,
                    "basename": meeting.basename, "template": meeting.template.storedValue,
                    "hadBackground": meeting.hadBackground,
                ]
            }
            return [userInfoKey: entries]
        }

        /// The meetings a notice's user info names, without their backgrounds.
        static func meetings(in userInfo: [AnyHashable: Any]) -> [Self] {
            guard let entries = userInfo[userInfoKey] as? [[String: Any]] else { return [] }
            return entries.compactMap { entry in
                guard let jobID = (entry["jobID"] as? String).flatMap(UUID.init(uuidString:)),
                      let title = entry["title"] as? String,
                      let folder = entry["folder"] as? String,
                      let basename = entry["basename"] as? String,
                      let template = entry["template"] as? String
                else { return nil }
                return Self(
                    jobID: jobID, title: title, folder: URL(filePath: folder, directoryHint: .isDirectory),
                    basename: basename, template: ProtocolTemplateID(storedValue: template),
                    background: nil, hadBackground: entry["hadBackground"] as? Bool ?? false,
                )
            }
        }
    }

    // MARK: - Notices

    /// What the person is told about a local generation (spec R4, R5, R8).
    enum LocalModelNotice: Equatable, Sendable {
        /// Why a protocol was not written. Each has its own notification, and
        /// one of each is open per episode (`LocalModelNoticeBook`).
        enum Shortfall: String, CaseIterable, Sendable {
            case lowMemory = "low-memory"
            case noModel = "no-model"

            /// The job's warning; the transcript is kept in both cases.
            var warning: String {
                switch self {
                case .lowMemory: "Protocol not written: low memory — transcript saved"
                case .noModel: "Protocol not written: no local model — transcript saved"
                }
            }
        }

        /// The warning of a protocol saved although the model stopped at its
        /// output limit (spec R7).
        static let incompleteWarning = "Protocol incomplete — the local model stopped at its output limit"

        /// A recording ended the job's helper; the protocol is written by
        /// itself once the recording has ended.
        case paused(jobID: UUID, title: String)
        /// The protocol was not written; the job keeps its transcript.
        case notWritten(Shortfall, LocalModelNoticeMeeting)
    }

    /// Runs Try Again for a meeting a notice names. `ProtocolRegenerator` is the
    /// one in the app.
    @MainActor
    protocol LocalModelNoticeResponding: AnyObject, Sendable {
        /// Makes the meeting's protocol again, its protocol stage only. False
        /// when the meeting's files are gone, so the caller shows what is left.
        func tryAgain(_ meeting: LocalModelNoticeMeeting) async -> Bool
    }

    /// What the notice actions do outside the app's own state, so a test sees
    /// each one without opening a file or a window.
    struct LocalModelNoticeEffects: Sendable {
        var open: @MainActor @Sendable (URL) -> Void
        var reveal: @MainActor @Sendable (URL) -> Void
        var openSettings: @MainActor @Sendable () -> Void
        var fileExists: @Sendable (URL) -> Bool

        static let live = Self(
            open: { NSWorkspace.shared.open($0) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            openSettings: { SettingsNavigation.shared.show(.output) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        )
    }

    /// Where Show Transcript takes the person: the raw transcript when it was
    /// kept, else the protocol (its Full Transcript section), else the folder.
    enum LocalModelTranscriptDestination: Equatable {
        case open(URL)
        case reveal(URL)

        static func of(_ meeting: LocalModelNoticeMeeting, fileExists: (URL) -> Bool) -> Self {
            if fileExists(meeting.transcriptURL) { return .open(meeting.transcriptURL) }
            if fileExists(meeting.protocolURL) { return .open(meeting.protocolURL) }
            return .reveal(meeting.folder)
        }
    }

    // MARK: - Episodes

    /// The open low-memory and no-model notices, one per shortfall.
    ///
    /// An episode runs from its first notice until a local protocol is
    /// written, by the queue or by a regeneration. A later job falling short
    /// in the same episode joins the open notification, posted again under
    /// the same identifier, which replaces it, instead of raising another one.
    ///
    /// `@unchecked Sendable`: every stored property is guarded by `lock`, since
    /// the notification delegate answers from an arbitrary queue.
    final class LocalModelNoticeBook: @unchecked Sendable {
        private struct Episode {
            let identifier: String
            var meetings: [LocalModelNoticeMeeting]
        }

        private let lock = NSLock()
        private var episodes: [LocalModelNotice.Shortfall: Episode] = [:]
        /// Kept past an episode's end, so a notice still on screen gets its
        /// meetings' backgrounds back. Lost with the process, never stored.
        private var backgrounds: [UUID: String] = [:]
        private weak var storedResponder: (any LocalModelNoticeResponding)?

        var responder: (any LocalModelNoticeResponding)? {
            get { lock.withLock { storedResponder } }
            set { lock.withLock { storedResponder = newValue } }
        }

        /// The identifier to post `notice` under and the meetings it names now.
        func file(_ notice: LocalModelNotice) -> (identifier: String, meetings: [LocalModelNoticeMeeting]) {
            switch notice {
            case let .paused(jobID, _):
                ("local-model-paused-\(jobID.uuidString)", [])

            case let .notWritten(shortfall, meeting):
                lock.withLock {
                    if let background = meeting.background { backgrounds[meeting.jobID] = background }
                    var episode = episodes[shortfall]
                        ?? Episode(identifier: "local-model-\(shortfall.rawValue)-\(UUID().uuidString)", meetings: [])
                    episode.meetings.removeAll { $0.jobID == meeting.jobID }
                    episode.meetings.append(meeting)
                    episodes[shortfall] = episode
                    return (episode.identifier, episode.meetings)
                }
            }
        }

        /// A local protocol was written: the next shortfall starts a new notice.
        func endEpisodes() {
            lock.withLock { episodes.removeAll() }
        }

        /// `meetings` with the backgrounds this process still holds for them.
        func restoringBackgrounds(_ meetings: [LocalModelNoticeMeeting]) -> [LocalModelNoticeMeeting] {
            lock.withLock { meetings.map { $0.restoring(background: backgrounds[$0.jobID]) } }
        }
    }

    // MARK: - From the queue to the notifier

    /// Turns one queue's local-model events into notices. Held by the closures
    /// it installs, so it lives exactly as long as that queue.
    @MainActor
    final class LocalModelJobNotices {
        private let notifier: any AppNotifying
        private let settings: AppSettings
        /// Jobs told about with a low-memory or no-model notice, whose end then
        /// posts no "Transcript Saved" beside it.
        private var noticedJobs: Set<UUID> = []
        /// Jobs told their protocol is paused, until they leave the protocol
        /// stage: one paused notice per stage, however often it is deferred.
        private var pausedJobs: Set<UUID> = []

        init(notifier: any AppNotifying, settings: AppSettings) {
            self.notifier = notifier
            self.settings = settings
        }

        /// Installs on `queue`, after its job-state callback is set: a job that
        /// ends with a low-memory or no-model notice gets no "Transcript Saved"
        /// beside it, so three such jobs in one episode raise one notification.
        func install(on queue: PipelineQueue) {
            let announce = queue.onJobStateChange
            queue.onJobStateChange = { [self] job, oldState, newState in
                if oldState == .generatingProtocol { pausedJobs.remove(job.id) }
                if newState.isTerminal, noticedJobs.remove(job.id) != nil, newState == .done { return }
                announce?(job, oldState, newState)
            }
            queue.onLocalModelEvent = { [self] event in post(event) }
        }

        private func post(_ event: PipelineQueue.LocalModelEvent) {
            switch event {
            case let .deferred(jobID, title):
                // Record-only mode holds the gate like a recording (spec A19), so
                // its switch-on ends a helper the same way; "paused for your
                // recording" would be wrong then, and the job stays in its
                // protocol state without a notice (A21). Remove this line to
                // post the paused notice in that case as well.
                guard !settings.recordOnly else { return }
                guard pausedJobs.insert(jobID).inserted else { return }
                notifier.postLocalModelNotice(.paused(jobID: jobID, title: title))

            case let .notWritten(shortfall, meeting):
                noticedJobs.insert(meeting.jobID)
                notifier.postLocalModelNotice(.notWritten(shortfall, meeting))

            case .written:
                notifier.endLocalModelNoticeEpisodes()
            }
        }
    }

    // MARK: - Categories, content and actions

    extension NotificationManager {
        /// One category per shortfall, because each offers its own actions:
        /// Try Again and Show Transcript for low memory (spec R4), Open
        /// Settings for no model (spec R8). The paused notice offers none.
        static let localModelLowMemoryCategoryID = "LOCAL_MODEL_LOW_MEMORY"
        static let localModelNoModelCategoryID = "LOCAL_MODEL_NO_MODEL"
        static let localModelTryAgainActionID = "LOCAL_MODEL_TRY_AGAIN"
        static let localModelShowTranscriptActionID = "LOCAL_MODEL_SHOW_TRANSCRIPT"
        static let localModelOpenSettingsActionID = "LOCAL_MODEL_OPEN_SETTINGS"

        static var localModelCategoryIDs: Set<String> {
            [localModelLowMemoryCategoryID, localModelNoModelCategoryID]
        }

        /// No `.foreground` on any action, for the consent prompt's reasons;
        /// opening a file or the Settings window activates what it shows.
        static func makeLocalModelCategories() -> Set<UNNotificationCategory> {
            let tryAgain = UNNotificationAction(identifier: localModelTryAgainActionID, title: "Try Again", options: [])
            let show = UNNotificationAction(identifier: localModelShowTranscriptActionID, title: "Show Transcript", options: [])
            let settings = UNNotificationAction(identifier: localModelOpenSettingsActionID, title: "Open Settings", options: [])
            return [
                UNNotificationCategory(
                    identifier: localModelLowMemoryCategoryID, actions: [tryAgain, show], intentIdentifiers: [], options: [],
                ),
                UNNotificationCategory(
                    identifier: localModelNoModelCategoryID, actions: [settings], intentIdentifiers: [], options: [],
                ),
            ]
        }

        /// Title, body and category of a notice naming `meetings` (the open
        /// episode's, newest last). The body names meetings by title, as every
        /// other notification of the app does, and never the background.
        static func localModelNoticeContent(
            for notice: LocalModelNotice, meetings: [LocalModelNoticeMeeting],
        ) -> (title: String, body: String, categoryID: String?) {
            switch notice {
            case let .paused(_, title):
                ("Protocol paused for your recording", "\(title): the protocol is written once the recording has ended.", nil)

            case .notWritten(.lowMemory, _):
                (
                    "Protocol not written: low memory",
                    "\(naming(meetings)): there was not enough free memory for the local model. \(transcriptsSaved(meetings))",
                    localModelLowMemoryCategoryID,
                )

            case .notWritten(.noModel, _):
                (
                    "Protocol not written: no local model",
                    "\(naming(meetings)): no local model is chosen, or it cannot be reached. Choose one in Settings → Output. \(transcriptsSaved(meetings))",
                    localModelNoModelCategoryID,
                )
            }
        }

        private static func naming(_ meetings: [LocalModelNoticeMeeting]) -> String {
            let latest = meetings.last?.title ?? ""
            switch meetings.count {
            case 0, 1: return latest
            case 2: return "\(latest) and 1 more meeting"
            default: return "\(latest) and \(meetings.count - 1) more meetings"
            }
        }

        private static func transcriptsSaved(_ meetings: [LocalModelNoticeMeeting]) -> String {
            meetings.count > 1 ? "The transcripts are saved." : "The transcript is saved."
        }

        /// Runs the action tapped on a local-model notice for every meeting it
        /// names. Try Again falls back to Show Transcript for a meeting whose
        /// files are gone. A tap on the body or a dismissal does nothing.
        func answerLocalModelNotice(actionID: String, meetings named: [LocalModelNoticeMeeting]) async {
            let meetings = localModelNotices.restoringBackgrounds(named)
            let effects = localModelEffects
            switch actionID {
            case Self.localModelTryAgainActionID:
                for meeting in meetings {
                    let started = await localModelNotices.responder?.tryAgain(meeting) ?? false
                    if !started { await Self.showTranscript(of: meeting, effects: effects) }
                }

            case Self.localModelShowTranscriptActionID:
                for meeting in meetings {
                    await Self.showTranscript(of: meeting, effects: effects)
                }

            case Self.localModelOpenSettingsActionID:
                await effects.openSettings()

            default:
                break
            }
        }

        @MainActor
        private static func showTranscript(of meeting: LocalModelNoticeMeeting, effects: LocalModelNoticeEffects) {
            switch LocalModelTranscriptDestination.of(meeting, fileExists: effects.fileExists) {
            case let .open(file): effects.open(file)
            case let .reveal(folder): effects.reveal(folder)
            }
        }
    }

#endif
