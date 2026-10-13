@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class AppPickerViewTests: XCTestCase {
    private struct MockAppsProvider: RunningAppsProvider {
        let apps: [RunningApp]

        func runningApps() -> [RunningApp] {
            apps
        }
    }

    private static let testApps = [
        RunningApp(id: 100, name: "Chrome", bundleIdentifier: "com.google.Chrome", icon: nil),
        RunningApp(id: 200, name: "Safari", bundleIdentifier: "com.apple.Safari", icon: nil),
    ]

    private static let choices = ProtocolTemplateChoices(templates: [.builtIn, .file(name: "Board")], defaultTemplate: .builtIn)
    private static let use = ProtocolOptionsUse(destination: .remote(name: "Anthropic (Claude)"), recordOnly: false)

    private func makeView(
        apps: [RunningApp] = testApps,
        startWouldBeRefused: Bool = false,
        noMic: Bool = false,
        optionsUse: @escaping () -> ProtocolOptionsUse = { use },
        draft: StartRecordingDraft = StartRecordingDraft(),
        onStartRecording: @escaping (ManualRecordingRequest, MeetingProtocolOptions) -> Void = { _, _ in },
        onCancel: @escaping () -> Void = {},
    ) -> AppPickerView {
        AppPickerView(
            appsProvider: MockAppsProvider(apps: apps),
            startWouldBeRefused: startWouldBeRefused,
            noMic: noMic,
            templateChoices: { Self.choices },
            optionsUse: optionsUse,
            draft: draft,
            onStartRecording: onStartRecording,
            onCancel: onCancel,
        )
    }

    // MARK: - Start

    func testStartButtonDisabledWithoutSelection() throws {
        let button = try makeView().inspect().find(button: "Start Recording")
        XCTAssertTrue(button.isDisabled())
    }

    /// The list's selection cannot be driven here, so the draft is preset, as
    /// the user's click would leave it.
    func testStartHandsOverTheSelectedAppTitleAndOptions() throws {
        let draft = StartRecordingDraft(
            source: .app(Self.testApps[1]),
            title: "Standup",
            protocolOptions: ProtocolOptionsDraft(template: .file(name: "Board"), background: " Alice, Bob "),
        )
        var started: [(ManualRecordingRequest, MeetingProtocolOptions)] = []
        let onStart: (ManualRecordingRequest, MeetingProtocolOptions) -> Void = { started.append(($0, $1)) }
        let sut = makeView(draft: draft, onStartRecording: onStart)

        try sut.inspect().find(button: "Start Recording").tap()

        XCTAssertEqual(started.count, 1)
        guard case let .app(pid, appName, title) = started.first?.0 else {
            XCTFail("expected an app recording, got \(String(describing: started.first?.0))")
            return
        }
        XCTAssertEqual(pid, 200)
        XCTAssertEqual(appName, "Safari")
        XCTAssertEqual(title, "Standup")
        XCTAssertEqual(started.first?.1, MeetingProtocolOptions(template: .file(name: "Board"), rawBackground: "Alice, Bob"))
    }

    func testStartWithMicrophoneOnlyHandsOverTheMicrophone() throws {
        let draft = StartRecordingDraft(source: .microphone, title: "Ignored")
        var started: [(ManualRecordingRequest, MeetingProtocolOptions)] = []
        let onStart: (ManualRecordingRequest, MeetingProtocolOptions) -> Void = { started.append(($0, $1)) }
        let sut = makeView(draft: draft, onStartRecording: onStart)

        try sut.inspect().find(button: "Start Recording").tap()

        XCTAssertEqual(started.count, 1)
        guard case .microphone = started.first?.0 else {
            XCTFail("expected a microphone recording, got \(String(describing: started.first?.0))")
            return
        }
        XCTAssertEqual(started.first?.1, MeetingProtocolOptions(template: .builtIn, rawBackground: ""))
    }

    /// An app recording without a typed title is named after the app, as before.
    func testAnAppWithoutATitleIsNamedAfterTheApp() {
        let draft = StartRecordingDraft(source: .app(Self.testApps[0]))
        guard case let .app(_, _, title) = draft.request else {
            XCTFail("expected an app recording")
            return
        }
        XCTAssertEqual(title, "Chrome")
    }

    /// Wiring only: the decision itself is covered in `AppPickerStartStateTests`.
    ///
    /// Asserts the explanation rather than `isDisabled()` on purpose. Nothing is
    /// selected here, so the button is disabled either way and that assertion
    /// would pass even with the state unwired: measured, it does. The text is the
    /// one signal that only appears when `startWouldBeRefused` actually
    /// reaches the view. `allowsStart` is covered as a value one layer down, and
    /// the loss itself is prevented by the guard in `WatchingController`, not
    /// here, so an unpinned `.disabled` costs a bad press and not a recording.
    func testStartButtonExplainsARefusedStart() throws {
        let body = try makeView(startWouldBeRefused: true).inspect()
        XCTAssertNoThrow(
            try body.find(text: "Another recording is already starting or under way. The menu bar shows it once it is running."),
        )
    }

    func testMicrophoneOnlyWithNoMicrophoneSetExplainsAndCannotStart() throws {
        let body = try makeView(noMic: true, draft: StartRecordingDraft(source: .microphone)).inspect()

        XCTAssertTrue(try body.find(button: "Start Recording").isDisabled())
        XCTAssertNoThrow(try body.find(text: MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason ?? ""))
    }

    func testCaptionSaysWhetherAppRecordingsTakeTheMicrophone() throws {
        XCTAssertNoThrow(try makeView(noMic: false).inspect().find(text: "App audio and microphone"))
        XCTAssertNoThrow(
            try makeView(noMic: true).inspect().find(text: "App audio only, because No Microphone is set in Settings → Audio"),
        )
    }

    private func notice(_ view: AppPickerView) throws -> String {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolOptionsDestinationNotice)
            .text()
            .string()
    }

    func testTheOptionsFormShowsTheContextsNotice() throws {
        XCTAssertEqual(try notice(makeView()), Self.use.destination.notice)
    }

    /// A window left open while Settings switches to a remote provider and
    /// record-only mode says so, instead of what was true when it opened.
    func testTheOptionsFormFollowsTheSettingsWhileTheWindowIsOpen() throws {
        var use = ProtocolOptionsUse(destination: .local(host: "localhost"), recordOnly: false)
        // A local, not a closure literal: as the only argument one would be
        // rewritten into a trailing closure.
        let currentUse: () -> ProtocolOptionsUse = { use }
        let sut = makeView(optionsUse: currentUse)
        try sut.inspect().vStack().callOnAppear()
        XCTAssertEqual(try notice(sut), ProtocolDestination.local(host: "localhost").notice)
        XCTAssertThrowsError(try sut.inspect().find(text: ProtocolOptionsForm.recordOnlyNote))

        use = ProtocolOptionsUse(destination: .remote(name: "api.example.com"), recordOnly: true)

        XCTAssertEqual(try notice(sut), ProtocolDestination.remote(name: "api.example.com").notice)
        XCTAssertNoThrow(try sut.inspect().find(text: ProtocolOptionsForm.recordOnlyNote))
    }

    // MARK: - Cancel

    func testCancelCallsCallback() throws {
        var called = false
        let onCancel = { called = true }
        let sut = makeView(onCancel: onCancel)
        try sut.inspect().find(button: "Cancel").tap()
        XCTAssertTrue(called)
    }

    // MARK: - Layout

    func testHeaderAndMicrophoneRowShown() throws {
        let body = try makeView().inspect()
        XCTAssertNoThrow(try body.find(text: "Start Recording"))
        XCTAssertNoThrow(try body.find(text: AppPickerView.microphoneRowLabel))
    }

    func testMeetingTitleFieldExists() throws {
        XCTAssertNoThrow(try makeView().inspect().find(ViewType.TextField.self))
    }

    func testRefreshButtonExists() throws {
        let images = try makeView().inspect().findAll(ViewType.Image.self)
        let hasRefreshIcon = images.contains { (try? $0.actualImage().name()) == "arrow.clockwise" }
        XCTAssertTrue(hasRefreshIcon, "Refresh button should exist in header")
    }

    func testEmptyAppListStillShowsButtons() throws {
        let body = try makeView(apps: []).inspect()
        XCTAssertNoThrow(try body.find(button: "Start Recording"))
        XCTAssertNoThrow(try body.find(button: "Cancel"))
    }
}
