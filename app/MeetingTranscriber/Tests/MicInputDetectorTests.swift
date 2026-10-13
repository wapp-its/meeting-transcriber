@testable import MeetingTranscriber
import XCTest

// MARK: - Test Helpers

private func makeDetector(confirmationCount: Int = 1) -> MicInputDetector {
    let detector = MicInputDetector(confirmationCount: confirmationCount)
    detector.windowListProvider = { [] } // no real windows in unit tests
    return detector
}

private func snapshot(
    _ bundleID: String,
    pid: pid_t = 4321,
    running: Bool = true,
) -> MicInputDetector.AudioProcessSnapshot {
    MicInputDetector.AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: running)
}

private func customPattern(appName: String, bundleID: String) -> MicInputDetector.MicPattern {
    MicInputDetector.MicPattern(appName: appName, bundleIDs: [bundleID], matchesHelpers: true, usesBuiltInMeetingPattern: false)
}

// MARK: - Detection Tests

final class MicInputDetectorTests: XCTestCase {
    func testNoProcessesReturnsNil() {
        let detector = makeDetector()
        detector.processProvider = { [] }
        XCTAssertNil(detector.checkOnce())
    }

    /// Exercises the real Core Audio bridging, which the injected
    /// `processProvider` otherwise hides: hand-rolled property sizes and an
    /// `UnsafeMutablePointer` round-trip for the CFString. A mistake there
    /// yields garbage rather than a compile error, so assert the shape of what
    /// comes back. The list may legitimately be empty on a headless runner.
    func testSystemAudioProcessesReturnsWellFormedSnapshots() {
        for snapshot in MicInputDetector.systemAudioProcesses() {
            XCTAssertFalse(
                snapshot.bundleID.isEmpty,
                "a snapshot is only produced for a process that reported a bundle ID",
            )
            XCTAssertGreaterThan(snapshot.pid, 0, "\(snapshot.bundleID) reported a non-positive pid")
        }
    }

    /// A watched app with no `AppMeetingPattern` must still detect, with a
    /// synthesised pattern and the placeholder title, instead of dropping the
    /// meeting on the floor.
    func testWatchedAppWithoutMeetingPatternStillDetects() {
        let detector = MicInputDetector(
            patterns: [MicInputDetector.MicPattern(appName: "Unlisted Call App", bundleIDs: ["com.example.unlisted"])],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.processProvider = { [snapshot("com.example.unlisted", pid: 99)] }

        let result = detector.checkOnce()
        XCTAssertEqual(result?.pattern.appName, "Unlisted Call App")
        XCTAssertEqual(result?.pattern.ownerNames, ["Unlisted Call App"])
        XCTAssertEqual(result?.windowPID, 99)
        XCTAssertEqual(result?.windowTitle, "Unlisted Call App Call")
    }

    /// The default install watches none of these apps, and then this channel
    /// must cost nothing: no Core Audio enumeration per poll, and no diagnostic
    /// naming the bundle of every app that touches the mic.
    func testUnwatchedInstallDoesNotEnumerateAudioProcesses() {
        let detector = MicInputDetector(patterns: MicInputDetector.patterns(watching: []), confirmationCount: 1)
        detector.windowListProvider = { [] }
        var providerCalls = 0
        detector.processProvider = {
            providerCalls += 1
            return [snapshot("com.tencent.xinWeChat")]
        }
        XCTAssertNil(detector.checkOnce())
        XCTAssertEqual(providerCalls, 0)
    }

    func testDetectsWeChatCall() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", pid: 777)] }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "WeChat")
        // No window title available (empty list) → clean placeholder.
        XCTAssertEqual(result?.windowTitle, "WeChat Call")
        XCTAssertEqual(result?.windowPID, 777)
    }

    func testDetectsTencentMeetingViaWemeetBundle() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.wemeet")] }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Tencent Meeting")
    }

    /// The international build ships as VooV Meeting under its own bundle ID,
    /// so watching only the mainland one would miss those users entirely.
    func testDetectsVooVMeetingInternationalBundle() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.tencentmeeting")] }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Tencent Meeting")
    }

    func testIdleProcessDoesNotDetect() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", running: false)] }
        XCTAssertNil(detector.checkOnce())
    }

    func testUnwatchedBundleDoesNotDetect() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.apple.VoiceMemos")] }
        XCTAssertNil(detector.checkOnce())
    }

    func testConfirmationThresholdNeedsConsecutiveHits() {
        let detector = makeDetector(confirmationCount: 2)
        detector.processProvider = { [snapshot("com.tencent.xinWeChat")] }
        XCTAssertNil(detector.checkOnce(), "first hit must not confirm")
        XCTAssertNotNil(detector.checkOnce(), "second consecutive hit confirms")
    }

    func testInterruptedHitsResetCounter() {
        let detector = makeDetector(confirmationCount: 2)
        var running = true
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", running: running)] }
        XCTAssertNil(detector.checkOnce())
        running = false
        XCTAssertNil(detector.checkOnce())
        running = true
        XCTAssertNil(detector.checkOnce(), "counter must restart after the gap")
    }

    func testIsMeetingActiveTracksInputState() throws {
        let detector = makeDetector()
        var running = true
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", running: running)] }
        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertTrue(detector.isMeetingActive(meeting))
        running = false
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    func testIsMeetingActiveIsFalseForForeignApp() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat")] }
        let foreign = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Weekly | Microsoft Teams",
            ownerName: "MSTeams",
            windowPID: 1,
        )
        XCTAssertFalse(detector.isMeetingActive(foreign), "assertion-detected apps are not this detector's business")
    }

    func testResetStartsCooldown() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat")] }
        XCTAssertNotNil(detector.checkOnce())
        detector.reset(appName: "WeChat")
        XCTAssertNil(detector.checkOnce(), "cooldown must suppress re-detection")
    }

    func testEveryDefaultPatternHasMeetingPattern() {
        // Drift guard, mirroring the assertion detector's: a mic pattern with no
        // AppMeetingPattern would silently fall back to placeholder titles.
        for pattern in MicInputDetector.defaultPatterns {
            XCTAssertNotNil(
                AppMeetingPattern.forAppName(pattern.appName),
                "MicPattern \(pattern.appName) has no AppMeetingPattern",
            )
        }
    }

    func testPatternsWatchingFiltersBySelection() {
        let all = MicInputDetector.patterns(watching: ["WeChat", "Tencent Meeting", "FaceTime", "WhatsApp"])
        XCTAssertEqual(all.count, MicInputDetector.defaultPatterns.count)
        let none = MicInputDetector.patterns(watching: [])
        XCTAssertTrue(none.isEmpty)
        let one = MicInputDetector.patterns(watching: ["WeChat"])
        XCTAssertEqual(one.map(\.appName), ["WeChat"])
    }

    func testCustomAppDetectsViaHelperAndTapsMainApp() throws {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: [], customBundleIDs: ["com.example.callapp"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { $0 == "com.example.callapp" ? 100 : nil }
        detector.processProvider = { [snapshot("com.example.callapp.helper", pid: 555)] }

        let result = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(result.windowPID, 100)
        XCTAssertTrue(detector.isMeetingActive(result))
    }

    func testCustomAppMainProcessKeepsItsOwnPID() {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: [], customBundleIDs: ["com.example.callapp"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in 100 }
        detector.processProvider = { [snapshot("com.example.callapp", pid: 555)] }

        XCTAssertEqual(detector.checkOnce()?.windowPID, 555)
    }

    func testCustomAppIgnoresBundleSharingOnlyAPrefix() {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: [], customBundleIDs: ["com.example.callapp"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.processProvider = { [snapshot("com.example.callappextra", pid: 555)] }

        XCTAssertNil(detector.checkOnce())
    }

    func testUnrelatedCustomAppNamedLikeABuiltInStaysActiveWhileItsHelperHoldsTheMic() throws {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: ["WeChat"])
                + [customPattern(appName: "WeChat", bundleID: "com.example.wechat")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in nil }
        detector.processProvider = { [snapshot("com.example.wechat.helper")] }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testCustomAppNamedLikeABuiltInInAnotherCaseStaysActiveAndCoolsDown() throws {
        let detector = MicInputDetector(
            patterns: [customPattern(appName: "Whatsapp", bundleID: "com.example.whatsapp")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.processProvider = { [snapshot("com.example.whatsapp")] }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Whatsapp")
        XCTAssertTrue(detector.isMeetingActive(meeting))

        detector.reset(appName: meeting.pattern.identityKey)
        XCTAssertNil(detector.checkOnce(), "cooldown must apply under the key the meeting was reported with")
    }

    // MARK: - Same-named apps

    /// Built-in WeChat beside an app added under the same name, both holding
    /// the microphone. Confirms in one poll, so a reset, which still restarts
    /// every app's count, shows only what its cooldown does.
    private func sameNamedWeChat() -> MicInputDetector {
        let detector = MicInputDetector(
            patterns: MicInputDetector.patterns(watching: ["WeChat"])
                + [customPattern(appName: "WeChat", bundleID: "com.example.wechat")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in nil }
        detector.processProvider = { [snapshot("com.tencent.xinWeChat", pid: 1), snapshot("com.example.wechat", pid: 2)] }
        return detector
    }

    func testANeverForOneOfTwoSameNamedAppsLeavesTheOtherDetected() {
        let addedKey = "custom:com.example.wechat"

        let builtInDenied = sameNamedWeChat()
        builtInDenied.isIdentityDenied = { $0 == "WeChat" }
        XCTAssertEqual(builtInDenied.checkOnce()?.pattern.identityKey, addedKey, "denying the built-in leaves the added one detected")
        XCTAssertNil(builtInDenied.checkOnce(excluding: [addedKey]), "and the built-in is not")

        let addedDenied = sameNamedWeChat()
        addedDenied.isIdentityDenied = { $0 == addedKey }
        XCTAssertEqual(addedDenied.checkOnce()?.pattern.identityKey, "WeChat", "denying the added one leaves the built-in detected")
        XCTAssertNil(addedDenied.checkOnce(excluding: ["WeChat"]), "and the added one is not")
    }

    func testAResetCoolsDownOnlyTheSameNamedAppItNames() throws {
        let detector = sameNamedWeChat()
        let builtIn = try XCTUnwrap(detector.checkOnce(excluding: ["custom:com.example.wechat"]))
        XCTAssertEqual(builtIn.pattern.identityKey, "WeChat")

        detector.reset(appName: builtIn.pattern.identityKey)
        XCTAssertEqual(detector.checkOnce()?.pattern.identityKey, "custom:com.example.wechat", "the added one is detected on the next poll")
        XCTAssertNil(detector.checkOnce(excluding: ["custom:com.example.wechat"]), "while the built-in cools down")
    }

    func testOneOfTwoSameNamedAppsHoldingTheMicDoesNotKeepTheOthersMeetingActive() throws {
        let detector = sameNamedWeChat()
        let builtIn = try XCTUnwrap(detector.checkOnce(excluding: ["custom:com.example.wechat"]))
        let added = try XCTUnwrap(detector.checkOnce(excluding: ["WeChat"]))

        detector.processProvider = { [snapshot("com.example.wechat")] }
        XCTAssertFalse(detector.isMeetingActive(builtIn), "the added app's microphone use must not keep the built-in's meeting active")
        XCTAssertTrue(detector.isMeetingActive(added))

        detector.processProvider = { [snapshot("com.tencent.xinWeChat")] }
        XCTAssertFalse(detector.isMeetingActive(added), "nor the built-in's the added app's")
        XCTAssertTrue(detector.isMeetingActive(builtIn))
    }

    func testTwoAddedAppsWithTheSameNameKeepSeparateCooldownsAndLiveness() throws {
        let detector = MicInputDetector(
            patterns: [customPattern(appName: "Meet", bundleID: "com.a.meet"), customPattern(appName: "Meet", bundleID: "com.b.meet")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in nil }
        detector.processProvider = { [snapshot("com.a.meet", pid: 1), snapshot("com.b.meet", pid: 2)] }

        let first = try XCTUnwrap(detector.checkOnce(excluding: ["custom:com.b.meet"]))
        XCTAssertEqual(first.pattern.identityKey, "custom:com.a.meet")
        detector.reset(appName: first.pattern.identityKey)
        let second = try XCTUnwrap(detector.checkOnce(), "the other one is not cooled down")
        XCTAssertEqual(second.pattern.identityKey, "custom:com.b.meet")

        detector.processProvider = { [snapshot("com.b.meet")] }
        XCTAssertFalse(detector.isMeetingActive(first), "one added app's microphone use must not keep the other's meeting active")
        XCTAssertTrue(detector.isMeetingActive(second))
    }

    /// Two added apps whose bundle IDs are prefix-related (`com.acme.meet`
    /// and `com.acme.meet.beta`) are kept apart whichever was added first:
    /// helper matching must not file the second app, or its own helper,
    /// under the first app's key.
    func testPrefixRelatedAddedAppsAreFiledUnderTheMostSpecificBundleID() throws {
        let main = customPattern(appName: "Meet", bundleID: "com.acme.meet")
        let detector = MicInputDetector(
            patterns: [main, customPattern(appName: "Meet", bundleID: "com.acme.meet.beta")],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { _ in nil }
        let mainMeeting = DetectedMeeting(pattern: main.meetingPattern, windowTitle: "Meet Call", ownerName: "Meet", windowPID: 1)

        for process in ["com.acme.meet.beta", "com.acme.meet.beta.helper"] {
            detector.reset()
            detector.processProvider = { [snapshot(process, pid: 7)] }
            let beta = try XCTUnwrap(detector.checkOnce())
            XCTAssertEqual(beta.pattern.identityKey, "custom:com.acme.meet.beta", process)
            XCTAssertFalse(detector.isMeetingActive(mainMeeting), "\(process) must not keep the first app's meeting active")
        }

        detector.reset()
        detector.processProvider = { [snapshot("com.acme.meet.helper", pid: 8)] }
        let mainHelper = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(mainHelper.pattern.identityKey, "custom:com.acme.meet", "the first app's own helper still belongs to it")
    }

    /// Each of two same-named apps is titled by its own matcher, and an added
    /// app's meeting shows its display name, never its key.
    func testEachSameNamedAppTitlesItsMeetingWithItsOwnMatcherAndName() throws {
        let detector = sameNamedWeChat()
        detector.windowListProvider = { [["kCGWindowOwnerName": "微信", "kCGWindowName": "Call with Alice"]] }

        let builtIn = try XCTUnwrap(detector.checkOnce(excluding: ["custom:com.example.wechat"]))
        XCTAssertEqual(builtIn.windowTitle, "Call with Alice", "the built-in's matcher knows its localized owner name")

        let added = try XCTUnwrap(detector.checkOnce(excluding: ["WeChat"]))
        XCTAssertEqual(added.windowTitle, "WeChat Call")
        XCTAssertEqual(added.ownerName, "WeChat")
        XCTAssertEqual(added.pattern.appName, "WeChat")
    }

    @MainActor
    func testDefaultDetectorReadsCustomWatchedApps() throws {
        func detector(customApps: [String]) throws -> MicInputDetector {
            let suite = "CustomWatchWiring-\(getpid())-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            let settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
            settings.watchCustomApps = customApps
            let mic = try XCTUnwrap(
                WatchingController.defaultDetectors(settings: settings)
                    .compactMap { $0 as? MicInputDetector }.first,
            )
            mic.windowListProvider = { [] }
            mic.processProvider = { [snapshot("com.example.callapp")] }
            return mic
        }

        let watched = try detector(customApps: ["com.example.callapp"])
        _ = watched.checkOnce()
        XCTAssertNotNil(watched.checkOnce(), "a custom watched app holding the mic must fire")

        let unwatched = try detector(customApps: [])
        _ = unwatched.checkOnce()
        XCTAssertNil(unwatched.checkOnce(), "without the entry the same app must be ignored")
    }

    func testCustomAppDoesNotInheritTheBuiltInMeetingPatternOfItsName() {
        let meetingPattern = customPattern(appName: "Zoom", bundleID: "com.example.zoom").meetingPattern
        XCTAssertEqual(meetingPattern.ownerNames, ["Zoom"])
        XCTAssertTrue(meetingPattern.meetingPatterns.isEmpty)
        XCTAssertFalse(MicInputDetector.customPattern(bundleID: "com.example.zoom").usesBuiltInMeetingPattern)
    }

    func testBuiltInPatternsDoNotMatchHelpers() {
        let detector = makeDetector()
        detector.processProvider = { [snapshot("com.tencent.xinWeChat.MiniProgram")] }
        XCTAssertNil(detector.checkOnce())
    }

    func testAppDisplayNameUsesInstalledAppNameAndFallsBackToBundleID() {
        XCTAssertEqual(MicInputDetector.appDisplayName(bundleID: "com.apple.finder"), "Finder")
        XCTAssertEqual(MicInputDetector.appDisplayName(bundleID: "com.example.not-installed"), "com.example.not-installed")
    }

    func testDefaultMainAppPIDProviderFindsNothingForAnAppThatIsNotRunning() {
        XCTAssertNil(makeDetector().mainAppPIDProvider("com.example.not-installed"))
    }
}
