#if !APPSTORE

    @testable import MeetingTranscriber
    import UserNotifications
    import XCTest

    /// The local-model notices (spec R4, R5, R8) on the real manager over a
    /// fake scheduler: their categories and copy, one notification per
    /// episode, user info without background info, and the routing of each
    /// action to its own handler, never to the consent prompt.
    @MainActor
    final class NotificationManagerLocalModelTests: XCTestCase {
        // MARK: - Categories and content

        func testTheShortfallCategoriesOfferTheActionsR4AndR8Name() {
            let (manager, scheduler) = makeManager()
            manager.setUp()
            let actions = Dictionary(uniqueKeysWithValues: scheduler.categories.map { ($0.identifier, $0.actions.map(\.title)) })

            XCTAssertEqual(actions[NotificationManager.localModelLowMemoryCategoryID], ["Try Again", "Show Transcript"])
            XCTAssertEqual(actions[NotificationManager.localModelNoModelCategoryID], ["Open Settings"])
            XCTAssertNotNil(actions[NotificationManager.consentCategoryID], "registering replaced the consent category")
            XCTAssertNotNil(actions[NotificationManager.meetingEndCategoryID], "registering replaced the meeting-end category")
            XCTAssertTrue(scheduler.categories.flatMap(\.actions).allSatisfy { !$0.options.contains(.foreground) })
        }

        func testEachNoticeIsPostedWithTheMockupsTitle() throws {
            let (manager, scheduler) = makeManager()
            manager.setUp()
            let standup = try meeting("Standup", in: makeTempDirectory(prefix: "LocalModelNotices"))
            manager.postLocalModelNotice(.paused(jobID: standup.jobID, title: "Standup"))
            manager.postLocalModelNotice(.notWritten(.lowMemory, standup))
            manager.postLocalModelNotice(.notWritten(.noModel, standup))

            let posted = scheduler.added.map { [$0.content.title, $0.content.body, $0.content.categoryIdentifier] }
            XCTAssertEqual(posted, [
                ["Protocol paused for your recording", "Standup: the protocol is written once the recording has ended.", ""],
                [
                    "Protocol not written: low memory",
                    "Standup: there was not enough free memory for the local model. The transcript is saved.",
                    NotificationManager.localModelLowMemoryCategoryID,
                ],
                [
                    "Protocol not written: no local model",
                    "Standup: no local model is chosen, or it cannot be reached. Choose one in Settings → Output. The transcript is saved.",
                    NotificationManager.localModelNoModelCategoryID,
                ],
            ])
            XCTAssertEqual(manager.recentNotifications.map(\.title), posted.map { $0[0] })
        }

        // MARK: - Episodes

        func testAShortfallEpisodeKeepsOneNotificationUntilAProtocolIsWritten() throws {
            let (manager, scheduler) = makeManager()
            manager.setUp()
            let folder = try makeTempDirectory(prefix: "LocalModelNotices")
            let (first, second, third) = (meeting("First", in: folder), meeting("Second", in: folder), meeting("Third", in: folder))
            manager.postLocalModelNotice(.notWritten(.lowMemory, first))
            manager.postLocalModelNotice(.notWritten(.noModel, first))
            manager.postLocalModelNotice(.notWritten(.lowMemory, second))
            manager.postLocalModelNotice(.notWritten(.lowMemory, second))
            manager.endLocalModelNoticeEpisodes()
            manager.postLocalModelNotice(.notWritten(.lowMemory, third))

            let ids = scheduler.added.map(\.identifier)
            XCTAssertEqual(ids[0], ids[2], "a second job in the episode raised a new notification")
            XCTAssertEqual(ids[2], ids[3])
            XCTAssertNotEqual(ids[0], ids[1], "low memory and no model share a notification")
            XCTAssertNotEqual(ids[3], ids[4], "the episode outlived a written protocol")
            XCTAssertEqual(Self.jobIDs(scheduler.added[3]), [first.jobID, second.jobID], "a job counted twice")
            XCTAssertTrue(scheduler.added[3].content.body.hasPrefix("Second and 1 more meeting: "))
            XCTAssertEqual(Self.jobIDs(scheduler.added[4]), [third.jobID])
        }

        // MARK: - User info

        /// The system keeps user info on disk; background info never goes
        /// there, and only this process can give it back to Try Again.
        func testUserInfoNamesTheMeetingWithoutItsBackground() async throws {
            let (manager, scheduler) = makeManager()
            manager.setUp()
            let board = try meeting("Board", in: makeTempDirectory(prefix: "LocalModelNotices"), background: "Budget cut for team X")
            manager.postLocalModelNotice(.notWritten(.lowMemory, board))
            let posted = try XCTUnwrap(scheduler.added.first?.content)

            XCTAssertFalse(String(describing: posted.userInfo).contains("Budget"), "background info written into a notification")
            let decoded = try XCTUnwrap(LocalModelNoticeMeeting.meetings(in: posted.userInfo).first)
            XCTAssertEqual(decoded.jobID, board.jobID)
            XCTAssertEqual(decoded.transcriptURL.path, board.transcriptURL.path)
            XCTAssertEqual(decoded.template, .file(name: "Board"))
            XCTAssertNil(decoded.background)
            XCTAssertTrue(decoded.hadBackground)

            let responder = FakeNoticeResponder()
            manager.setLocalModelNoticeResponder(responder)
            // What the posted user info reads back as, handed over once per answer.
            let answer = { LocalModelNoticeMeeting.userInfo(for: [decoded]) }
            await manager.respond(toCategory: lowMemoryCategory, requestID: "any", actionID: tryAgain, userInfo: answer())
            XCTAssertEqual(responder.tried.map(\.background), ["Budget cut for team X"])

            let (restarted, _) = makeManager()
            restarted.setLocalModelNoticeResponder(responder)
            await restarted.respond(toCategory: lowMemoryCategory, requestID: "any", actionID: tryAgain, userInfo: answer())
            XCTAssertNil(responder.tried.last?.background)
            XCTAssertEqual(responder.tried.last?.hadBackground, true)
        }

        // MARK: - Routing

        /// Every local-model action, a tap or dismissal on a local-model
        /// notice, and a response from a category this build does not know,
        /// all under the id of a parked consent prompt: each reaches its own
        /// handler and the prompt is still waiting afterwards.
        func testEachLocalModelActionReachesItsHandlerAndNeverTheConsentPrompt() async throws {
            let (manager, scheduler) = makeManager()
            manager.setUp()
            let question = ConsentQuestion(app: "Browser Meetings", title: "Record this meeting?", body: "Browser")
            let prompt = Task { await manager.askToRecord(question) }
            try await waitUntil("the consent prompt is posted") { !scheduler.added.isEmpty }
            let standup = try meeting("Standup", in: makeTempDirectory(prefix: "LocalModelNotices"))
            try Data("Alice: hi".utf8).write(to: standup.transcriptURL)
            let userInfo = { LocalModelNoticeMeeting.userInfo(for: [standup]) }
            let (responder, effects) = (FakeNoticeResponder(), RecordedNoticeEffects())
            manager.setLocalModelNoticeResponder(responder)
            manager.localModelEffects = effects.effects
            let promptID = question.id.uuidString

            for action in [tryAgain, showTranscript, UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier] {
                await manager.respond(toCategory: lowMemoryCategory, requestID: promptID, actionID: action, userInfo: userInfo())
            }
            await manager.respond(toCategory: noModelCategory, requestID: promptID, actionID: openSettings, userInfo: userInfo())
            await manager.respond(toCategory: "SOME_FUTURE_CATEGORY", requestID: promptID, actionID: NotificationManager.recordActionID, userInfo: [:])
            await manager.respond(toCategory: "", requestID: promptID, actionID: NotificationManager.recordActionID, userInfo: [:])

            XCTAssertEqual(responder.tried.map(\.jobID), [standup.jobID])
            XCTAssertEqual(effects.opened, [standup.transcriptURL.path])
            XCTAssertEqual(effects.settingsOpened, 1)
            XCTAssertTrue(effects.revealed.isEmpty)
            XCTAssertTrue(manager.resolveBrowserConsent(granted: false), "a local-model action answered the consent prompt")
            let answer = await prompt.value
            XCTAssertEqual(answer, .declined)
        }

        func testTryAgainShowsTheTranscriptOfAMeetingWhoseFilesAreGone() async throws {
            let (manager, _) = makeManager()
            let gone = try meeting("Gone", in: makeTempDirectory(prefix: "LocalModelNotices"))
            let (responder, effects) = (FakeNoticeResponder(answer: false), RecordedNoticeEffects())
            manager.setLocalModelNoticeResponder(responder)
            manager.localModelEffects = effects.effects

            await manager.respond(
                toCategory: lowMemoryCategory, requestID: "any", actionID: tryAgain,
                userInfo: LocalModelNoticeMeeting.userInfo(for: [gone]),
            )

            XCTAssertEqual(responder.tried.map(\.jobID), [gone.jobID])
            XCTAssertEqual(effects.revealed, [gone.folder.path])
        }

        func testShowTranscriptOpensTheTranscriptElseTheProtocolElseRevealsTheFolder() throws {
            let standup = try meeting("Standup", in: makeTempDirectory(prefix: "LocalModelNotices"))
            let (transcript, protocolFile) = (standup.transcriptURL, standup.protocolURL)
            XCTAssertEqual(LocalModelTranscriptDestination.of(standup) { [transcript, protocolFile].contains($0) }, .open(transcript))
            XCTAssertEqual(LocalModelTranscriptDestination.of(standup) { $0 == protocolFile }, .open(protocolFile))
            XCTAssertEqual(LocalModelTranscriptDestination.of(standup) { _ in false }, .reveal(standup.folder))
        }

        // MARK: - Helpers

        private let lowMemoryCategory = NotificationManager.localModelLowMemoryCategoryID
        private let noModelCategory = NotificationManager.localModelNoModelCategoryID
        private let tryAgain = NotificationManager.localModelTryAgainActionID
        private let showTranscript = NotificationManager.localModelShowTranscriptActionID
        private let openSettings = NotificationManager.localModelOpenSettingsActionID

        private func makeManager() -> (NotificationManager, FakeNotificationScheduler) {
            let scheduler = FakeNotificationScheduler()
            return (NotificationManager(scheduler: scheduler) { true }, scheduler)
        }

        private func meeting(_ title: String, in folder: URL, background: String? = nil) -> LocalModelNoticeMeeting {
            LocalModelNoticeMeeting(
                jobID: UUID(), title: title, folder: folder, basename: "20261016_0900_\(title.lowercased())",
                template: .file(name: "Board"), background: background,
            )
        }

        private static func jobIDs(_ request: UNNotificationRequest) -> [UUID] {
            LocalModelNoticeMeeting.meetings(in: request.content.userInfo).map(\.jobID)
        }
    }

    /// Records each meeting Try Again is asked for and answers `answer`.
    @MainActor
    final class FakeNoticeResponder: LocalModelNoticeResponding {
        private(set) var tried: [LocalModelNoticeMeeting] = []
        private let answer: Bool

        init(answer: Bool = true) {
            self.answer = answer
        }

        // swiftlint:disable:next async_without_await
        func tryAgain(_ meeting: LocalModelNoticeMeeting) async -> Bool {
            tried.append(meeting)
            return answer
        }
    }

    /// Records what the notice actions open, reveal and show; files are
    /// looked up on disk.
    @MainActor
    final class RecordedNoticeEffects {
        /// Paths, since a folder URL read back may differ in its trailing slash.
        private(set) var opened: [String] = []
        private(set) var revealed: [String] = []
        private(set) var settingsOpened = 0

        var effects: LocalModelNoticeEffects {
            LocalModelNoticeEffects(
                open: { [self] in opened.append($0.path) },
                reveal: { [self] in revealed.append($0.path) },
                openSettings: { [self] in settingsOpened += 1 },
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            )
        }
    }

#endif
