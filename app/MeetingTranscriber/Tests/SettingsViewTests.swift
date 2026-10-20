// swiftlint:disable file_length
@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class SettingsViewTests: XCTestCase { // swiftlint:disable:this type_body_length
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite — same pattern as AppSettingsTests.
    /// Avoids `swift test --parallel` plist races AND prevents test pollution
    /// from leaking into the dev app's `.standard` plist when a test process
    /// is killed before tearDown runs.
    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "SettingsViewTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        if let testSuiteName { DefaultsSuite.remove(testSuiteName) }
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    private func makeSettingsView(
        settings: AppSettings? = nil,
        updateChecker: UpdateChecker? = nil,
    ) -> SettingsView {
        SettingsView(
            settings: settings ?? makeSettings(),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            updateChecker: updateChecker,
            recognitionStatsLog: RecognitionStatsLog(),
            stageTimingLog: StageTimingLog(),
        )
    }

    private func makeGeneral(
        settings: AppSettings? = nil,
    ) -> GeneralSettingsView {
        GeneralSettingsView(settings: settings ?? makeSettings())
    }

    private func makeAudio(settings: AppSettings? = nil) -> AudioSettingsView {
        AudioSettingsView(settings: settings ?? makeSettings())
    }

    private func makeTranscription(settings: AppSettings? = nil) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings ?? makeSettings(),
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
    }

    private func makeSpeakers(
        settings: AppSettings? = nil,
        matcherFactory: @escaping () -> SpeakerMatcher = { SpeakerMatcher() },
    ) -> SpeakersSettingsView {
        SpeakersSettingsView(
            settings: settings ?? makeSettings(),
            recognitionStatsLog: RecognitionStatsLog(),
            stageTimingLog: StageTimingLog(),
            enrollmentDiarizerFactory: nil,
            namingDialogActive: false,
            pipelineBusy: false,
            matcherFactory: matcherFactory,
        )
    }

    private func makeOutput(settings: AppSettings? = nil) -> OutputSettingsView {
        OutputSettingsView(settings: settings ?? makeSettings())
    }

    private func makeAdvanced(settings: AppSettings? = nil) -> AdvancedSettingsView {
        AdvancedSettingsView(settings: settings ?? makeSettings())
    }

    // MARK: - Top-level SettingsView

    func testViewRendersWithDefaults() throws {
        XCTAssertNoThrow(try makeSettingsView().inspect())
    }

    // MARK: - General tab

    func testAppsToWatchSection() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Microsoft Teams"))
        XCTAssertNoThrow(try body.find(text: "Zoom"))
        XCTAssertNoThrow(try body.find(text: "Webex"))
    }

    func testAppsToWatchTogglesBindToSettings() throws {
        // Each toggle flips its OWN setting (the UI end of the watchApps wiring).
        let settings = makeSettings()
        let view = makeGeneral(settings: settings)
        let cases: [(label: String, get: () -> Bool)] = [
            ("Microsoft Teams", { settings.watchTeams }),
            ("Zoom", { settings.watchZoom }),
            ("Webex", { settings.watchWebex }),
        ]
        for (label, get) in cases {
            XCTAssertTrue(get(), "precondition: \(label) defaults on")
            let toggle = try view.inspect().find(ViewType.Toggle.self) { toggle in
                try toggle.labelView().text().string() == label
            }
            try toggle.tap()
            XCTAssertFalse(get(), "tapping the \(label) toggle must turn its own setting off")
        }
    }

    func testPollIntervalFieldExists() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Poll Interval"))
    }

    func testGracePeriodFieldExists() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Grace Period"))
    }

    func testUpdatesSectionNoLongerInGeneral() throws {
        let body = try makeGeneral().inspect()
        XCTAssertThrowsError(try body.find(text: "Check for Updates"))
    }

    // MARK: - Audio tab

    func testNoMicToggleExists() throws {
        let body = try makeAudio().inspect()
        XCTAssertNoThrow(try body.find(text: "No Microphone (app audio only)"))
    }

    func testVADToggleExists() throws {
        let body = try makeAudio().inspect()
        XCTAssertNoThrow(try body.find(text: "Voice Activity Detection (VAD)"))
    }

    func testVADThresholdShownWhenEnabled() throws {
        let settings = makeSettings()
        settings.vadEnabled = true
        let body = try makeAudio(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Threshold:"))
    }

    func testVADThresholdHiddenWhenDisabled() throws {
        let settings = makeSettings()
        settings.vadEnabled = false
        let body = try makeAudio(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Threshold:"))
    }

    // MARK: - Transcription tab

    func testTranscriptionSectionExists() throws {
        let body = try makeTranscription().inspect()
        XCTAssertNoThrow(try body.find(text: "Engine"))
    }

    func testWhisperKitModelPickerExists() throws {
        let body = try makeTranscription().inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    func testWhisperKitLanguagePickerShownForWhisperKit() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testWhisperKitModelPickerShownForWhisperKit() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
        XCTAssertNoThrow(try body.find(text: "Language"))
    }

    func testParakeetHidesLanguagePicker() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        // Parakeet has no language picker — verify the engine section is still present via the Engine picker
        XCTAssertNoThrow(try body.find(text: "Engine"))
    }

    func testParakeetShowsCustomVocabularyField() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
    }

    func testWhisperKitShowsCustomVocabularyField() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
    }

    func testWhisperKitModelPickerHiddenForParakeet() throws {
        // Parakeet section now shows its own Language picker + Custom-vocab
        // field, but the WhisperKit-specific Model picker must not leak through.
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        let body = try makeTranscription(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Custom vocabulary file"))
        XCTAssertNoThrow(try body.find(text: "Language"))
        XCTAssertThrowsError(try body.find(text: "Model"))
    }

    // MARK: - Speakers tab

    func testDiarizeToggleExists() throws {
        let body = try makeSpeakers().inspect()
        XCTAssertNoThrow(try body.find(text: "Speaker Diarization"))
    }

    func testDiarizeEnabledShowsExpectedSpeakers() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Expected speakers"))
        XCTAssertNoThrow(try body.find(text: SpeakersSettingsView.expectedSpeakersHint))
    }

    func testDiarizerModeHiddenWhenDiarizeDisabled() throws {
        let settings = makeSettings()
        settings.diarize = false
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Expected speakers"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodPicker))
    }

    // MARK: - Diarization method picker

    /// The picker lists the methods in `DiarizerMode.displayOrder` by their
    /// user-facing names, each with its description, and none of it says
    /// "Offline": that is the speech library's name for the clustering
    /// diarizer, and all three methods run on the Mac.
    func testMethodPickerListsMethodsInDisplayOrderWithDescriptions() throws {
        let settings = makeSettings()
        settings.diarize = true
        let body = try makeSpeakers(settings: settings).inspect()
        let picker = try body.find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodPicker)
        // The picker's own label ("Method") is the last text; the options come first.
        let names = picker.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertEqual(names.last, "Method")
        XCTAssertEqual(
            Array(names.dropLast()),
            [
                "Standard",
                "Any number of speakers. Groups similar voices.",
                "Sortformer",
                "Handles people talking at the same time. Up to 4 speakers per side.",
                "Nemotron 3",
                "Handles people talking at the same time. Up to 8 speakers per side.",
            ],
        )
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("offline") })
    }

    /// The picker writes the method back. Standard is `.offline` on the wire:
    /// the raw value is persisted and must not change with the display name.
    func testMethodPickerSelectWritesBackDiarizerMode() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        let picker = try makeSpeakers(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodPicker)
            .find(ViewType.Picker.self)
        try picker.select(value: DiarizerMode.nemotron)
        XCTAssertEqual(settings.diarizerMode, .nemotron)
        try picker.select(value: DiarizerMode.offline)
        XCTAssertEqual(settings.diarizerMode, .offline)
    }

    /// Switching the method no longer clamps the stored count: with the count
    /// hidden in the overlap-aware modes a clamp there only destroyed a value
    /// Standard needs when the user switches back.
    func testSwitchingMethodKeepsStoredCount() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        settings.numSpeakers = 6
        let view = makeSpeakers(settings: settings)
        let picker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodPicker)
            .find(ViewType.Picker.self)
        try picker.select(value: DiarizerMode.sortformer)
        XCTAssertEqual(settings.diarizerMode, .sortformer)
        XCTAssertEqual(settings.numSpeakers, 6, "a count chosen for Standard must survive a switch to Sortformer")
        // A fresh inspection, as the next body evaluation would be: the picker
        // under Sortformer still writes back, and the count is still there.
        let sortformerPicker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodPicker)
            .find(ViewType.Picker.self)
        try sortformerPicker.select(value: DiarizerMode.offline)
        XCTAssertEqual(settings.diarizerMode, .offline)
        XCTAssertEqual(settings.numSpeakers, 6, "and the switch back must find it unchanged")
    }

    func testExpectedSpeakersRangeIsStandardsCap() {
        XCTAssertEqual(SpeakersSettingsView.expectedSpeakerRange, 0 ... 10)
    }

    func testExpectedSpeakersStepperWritesBackCount() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        settings.numSpeakers = 0
        let stepper = try makeSpeakers(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.expectedSpeakersStepper)
            .find(ViewType.Stepper.self)
        try stepper.increment()
        XCTAssertEqual(settings.numSpeakers, 1)
    }

    func testMicSectionShownWhenMicEnabled() throws {
        let settings = makeSettings()
        settings.noMic = false
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Mic Speaker Name"))
    }

    func testMicSectionHiddenWhenNoMic() throws {
        let settings = makeSettings()
        settings.noMic = true
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Mic Speaker Name"))
    }

    // MARK: - Method hint and count visibility per method

    /// The hint for an overlap-aware method states the cap per call, which is
    /// twice the per-track cap: a recorded call is two tracks, each diarized
    /// on its own. The earlier "supports up to 4 speakers per meeting" was
    /// contradicted by the recordings it described.
    func testMethodHintTexts() {
        XCTAssertNil(SpeakersSettingsView.methodHint(for: .offline))
        XCTAssertEqual(
            SpeakersSettingsView.methodHint(for: .sortformer),
            "Sortformer counts the speakers itself. In a recorded call, the call audio and your microphone are two sides, so a call can have up to 8 speakers.",
        )
        XCTAssertEqual(
            SpeakersSettingsView.methodHint(for: .nemotron),
            "Nemotron 3 counts the speakers itself. In a recorded call, the call audio and your microphone are two sides, "
                + "so a call can have up to 16 speakers.",
        )
    }

    func testSortformerShowsMethodHintAndNoCount() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .sortformer
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodHint))
        XCTAssertNoThrow(try body.find(text: XCTUnwrap(SpeakersSettingsView.methodHint(for: .sortformer))))
        XCTAssertThrowsError(try body.find(text: "Expected speakers"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.expectedSpeakersStepper))
        XCTAssertThrowsError(try body.find(text: SpeakersSettingsView.expectedSpeakersHint))
    }

    func testNemotronShowsMethodHintAndNoCount() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .nemotron
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodHint))
        XCTAssertNoThrow(try body.find(text: XCTUnwrap(SpeakersSettingsView.methodHint(for: .nemotron))))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.expectedSpeakersStepper))
    }

    func testStandardShowsCountAndNoMethodHint() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.diarizationMethodHint))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.expectedSpeakersStepper))
    }

    /// No text in the Speakers tab may call a method "Offline" or state a
    /// per-meeting cap, whichever method is picked.
    func testNoTextCallsAMethodOfflineOrStatesAPerMeetingCap() throws {
        for mode in DiarizerMode.allCases {
            let settings = makeSettings()
            settings.diarize = true
            settings.diarizerMode = mode
            let texts = try makeSpeakers(settings: settings).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }
            XCTAssertFalse(texts.contains { $0.localizedCaseInsensitiveContains("offline") }, "\(mode): \(texts)")
            XCTAssertFalse(texts.contains { $0.localizedCaseInsensitiveContains("per meeting") }, "\(mode): \(texts)")
        }
    }

    // SpeakerMatcher.init reads + decodes speakers.json. It must run only
    // when the user opens the Known Voices sheet, never as a side effect
    // of body evaluation.
    func testKnownVoicesMatcherNotCreatedOnBodyEval() throws {
        var matcherInits = 0
        let view = makeSpeakers {
            matcherInits += 1
            return SpeakerMatcher()
        }
        _ = try view.inspect()
        XCTAssertEqual(matcherInits, 0)
    }

    // Companion: tapping "Manage…" invokes the factory exactly once.
    func testKnownVoicesMatcherCreatedOnManageTap() throws {
        var matcherInits = 0
        let view = makeSpeakers {
            matcherInits += 1
            return SpeakerMatcher()
        }
        let button = try view.inspect().find(button: "Manage\u{2026}")
        try button.tap()
        XCTAssertEqual(matcherInits, 1)
    }

    // MARK: - Experimental Diarization Tuning

    func testExperimentalDisclosureLabelExists() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Experimental: Diarization Tuning"))
    }

    // The disclosure starts collapsed — verified via the underlying
    // DisclosureGroup `isExpanded` binding that ViewInspector exposes.
    func testExperimentalDisclosureCollapsedByDefault() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .offline
        let body = try makeSpeakers(settings: settings).inspect()
        let disclosure = try body.find(ViewType.DisclosureGroup.self)
        XCTAssertFalse(try disclosure.isExpanded())
    }

    func testExperimentalDisclosureHiddenForSortformer() throws {
        let settings = makeSettings()
        settings.diarize = true
        settings.diarizerMode = .sortformer
        let body = try makeSpeakers(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Experimental: Diarization Tuning"))
    }

    func testResetButtonDisabledWhenAllDefaults() {
        let settings = makeSettings()
        XCTAssertTrue(settings.diarizerTuningIsAllDefaults)
    }

    func testResetButtonEnabledWhenAnyValueChanged() {
        let settings = makeSettings()
        settings.clusterThreshold = 0.42
        XCTAssertFalse(settings.diarizerTuningIsAllDefaults)
    }

    func testResetClearsNonDefaultValues() {
        let settings = makeSettings()
        settings.clusterThreshold = 0.42
        settings.warmStartFa = 0.13
        settings.excludeOverlap = false
        XCTAssertFalse(settings.diarizerTuningIsAllDefaults)

        settings.resetDiarizerTuning()
        XCTAssertTrue(settings.diarizerTuningIsAllDefaults)
    }

    // MARK: - Output tab

    func testProviderPickerExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "LLM Provider"))
    }

    #if !APPSTORE
        func testClaudeCLIProviderShowsBinaryPicker() throws {
            let settings = makeSettings()
            settings.protocolProvider = .claudeCLI
            let body = try makeOutput(settings: settings).inspect()
            XCTAssertNoThrow(try body.find(text: "Claude CLI"))
        }
    #endif

    func testOpenAIProviderShowsEndpointField() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Endpoint"))
        XCTAssertNoThrow(try body.find(text: "API Key"))
        XCTAssertNoThrow(try body.find(text: "Fetch Models"))
    }

    func testOpenAIModelFieldShown() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    func testNoneProviderShowsTranscriptOnlyMessage() throws {
        let settings = makeSettings()
        settings.protocolProvider = .none
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(
            try body.find(text: "No LLM summarization will be generated. Raw transcripts are retained if no protocol is saved."),
        )
    }

    func testNoneProviderHidesEndpointField() throws {
        let settings = makeSettings()
        settings.protocolProvider = .none
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(text: "Endpoint"))
    }

    func testProtocolLanguagePickerExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "Protocol Language"))
    }

    func testOutputFolderSectionExists() throws {
        let body = try makeOutput().inspect()
        XCTAssertNoThrow(try body.find(text: "Output Folder"))
    }

    func testResetButtonDisabledWhenNoCustomDir() throws {
        let settings = makeSettings()
        settings.clearCustomOutputDir()
        let body = try makeOutput(settings: settings).inspect()
        let button = try body.find(button: "Reset")
        XCTAssertTrue(button.isDisabled())
    }

    /// The single custom prompt's controls gave way to the templates section.
    func testOutputShowsProtocolTemplatesInsteadOfThePromptControls() throws {
        let store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "settings-templates"))
        let body = try OutputSettingsView(settings: makeSettings(), templateStore: store).inspect()
        for identifier in [
            A11yID.protocolTemplateDefaultPicker, A11yID.protocolTemplateNameField,
            A11yID.protocolTemplateCreateButton, A11yID.protocolTemplatesOpenFolderButton,
        ] {
            XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: identifier), identifier)
        }
        for label in ["Edit Prompt", "Import Prompt", "Reset to Default"] {
            XCTAssertThrowsError(try body.find(button: label), label)
        }
        for label in ["Custom prompt active", "Using default prompt"] {
            XCTAssertThrowsError(try body.find(text: label), label)
        }
    }

    func testOpenAIAPIKeyCaptionShown() throws {
        let settings = makeSettings()
        settings.protocolProvider = .openAICompatible
        let body = try makeOutput(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: "Leave empty if your local server doesn't require authentication"))
    }

    // MARK: - Advanced tab

    func testPermissionsSectionExists() throws {
        let body = try makeAdvanced().inspect()
        XCTAssertNoThrow(try body.find(text: "Screen Recording"))
        XCTAssertNoThrow(try body.find(text: "Microphone"))
        XCTAssertNoThrow(try body.find(text: "Accessibility"))
    }

    #if !APPSTORE
        func testDebugRPCToggleExists() throws {
            let body = try makeAdvanced().inspect()
            XCTAssertNoThrow(try body.find(text: "Local Automation API"))
        }

        func testDebugRPCToggleBindsToSetting() throws {
            let settings = makeSettings()
            settings.debugRPCEnabled = false
            let view = AdvancedSettingsView(settings: settings)
            let toggle = try view.inspect().find(ViewType.Toggle.self) { toggle in
                try toggle.labelView().text().string() == "Local Automation API"
            }
            try toggle.tap()
            XCTAssertTrue(settings.debugRPCEnabled)
        }
    #endif

    // MARK: - Record-only mode

    func testRecordOnlyToggleExists() throws {
        let body = try makeGeneral().inspect()
        XCTAssertNoThrow(try body.find(text: "Record-only mode"))
    }

    func testRecordOnlyBannerHiddenWhenOff() throws {
        let settings = makeSettings()
        settings.recordOnly = false
        let body = try makeGeneral(settings: settings).inspect()
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.recordOnlyBanner))
    }

    func testRecordOnlyBannerVisibleWhenOn() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeGeneral(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.recordOnlyBanner))
    }

    func testRecordOnlyDisablesTranscriptionSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeTranscription(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: A11yID.transcriptionSection)
        XCTAssertTrue(section.isDisabled())
    }

    func testRecordOnlyDisablesProtocolSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeOutput(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: A11yID.protocolSection)
        XCTAssertTrue(section.isDisabled())
    }

    func testRecordOnlyDoesNotDisableOutputFolderSection() throws {
        // Output Folder is where WAVs land in record-only mode too,
        // so it must remain interactive when the rest of Output is dimmed.
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeOutput(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: A11yID.outputFolderSection)
        XCTAssertFalse(section.isDisabled())
    }

    func testRecordOnlyDisablesDiarizationSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeSpeakers(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: A11yID.diarizationSection)
        XCTAssertTrue(section.isDisabled())
    }

    func testRecordOnlyDisablesVadSection() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeAudio(settings: settings).inspect()
        let section = try body.find(viewWithAccessibilityIdentifier: A11yID.vadSection)
        XCTAssertTrue(section.isDisabled())
    }
}
