import Foundation

/// Single source of truth for the accessibility identifiers used as automation
/// handles (ViewInspector `find`, the `/ui/tree` + `/ui/press` harness).
///
/// Referencing these constants from the SwiftUI `.accessibilityIdentifier`
/// modifier, the ViewInspector tests, and the `/ui/press` allowlist makes the
/// compiler catch a drifted identifier across those call sites — a raw string
/// literal duplicated per site drifts silently. Shell drivers (`test_rpc.sh`,
/// curl) use the raw string value and are not compiler-checked — keep them in
/// sync by hand when a value changes.
///
/// Add an entry on demand when a test or the harness needs to find/drive a
/// control — don't spray identifiers onto controls nothing drives. The string
/// values are the stable contract (VoiceOver + tests + allowlist read them) and
/// are heterogeneous on purpose (some kebab-case, some camelCase — they mirror
/// the pre-existing identifiers); don't "tidy" or otherwise change a value
/// without updating every site.
enum A11yID {
    // Settings — section anchors + record-only controls.
    static let recordOnlyToggle = "recordOnlyToggle"
    static let watchBrowserToggle = "watchBrowserToggle"
    static let watchAtLaunchToggle = "watchAtLaunchToggle"
    static let silencePromptToggle = "silencePromptToggle"
    static let silencePromptMinutesStepper = "silencePromptMinutesStepper"
    static let browserConsentWarning = "browserConsentWarning"
    static let consentDenyListSection = "consentDenyListSection"
    /// Per-row Remove button in the never-record list, addressed by ROW INDEX,
    /// never by app name. `GET /ui/tree` publishes identifiers unredacted
    /// precisely because they are app-set and never user input; interpolating
    /// the app name would hand a holder of the local automation token the list
    /// of apps the user refused to have recorded, through the one field that
    /// endpoint deliberately does not sanitise.
    static func consentDeniedAppRemove(_ index: Int) -> String {
        "consentDeniedAppRemove.\(index)"
    }

    /// One app's "record without asking" switch. Addressed by app name, unlike
    /// the rows above: the switches are a fixed list of apps the app ships
    /// with (`AppMeetingPattern.recordWithoutAskingCandidates`), so the name
    /// says nothing about the user, and the identifier carries no switch state.
    static func recordWithoutAskingToggle(_ appName: String) -> String {
        "recordWithoutAskingToggle.\(appName)"
    }

    /// The consent note under one app's switch, shown only while that switch
    /// is on. Its presence therefore says the switch is on, which the Settings
    /// window already shows to `/screenshot`.
    static func recordWithoutAskingConsentNote(_ appName: String) -> String {
        "recordWithoutAskingConsentNote.\(appName)"
    }

    static func watchCustomAppRemove(_ index: Int) -> String {
        "watchCustomAppRemove.\(index)"
    }

    /// Menu bar job row's Retry button, addressed by ROW INDEX like
    /// `consentDeniedAppRemove`, so every row's button has its own handle and
    /// no meeting title ends up in an identifier.
    static func jobRetryButton(_ index: Int) -> String {
        "jobRetryButton.\(index)"
    }

    /// The device picker in the menu bar's Microphone submenu. One fixed
    /// value: no device UID or name in it, for the reason the job rows give.
    static let menuMicrophonePicker = "menuMicrophonePicker"

    /// The device picker in the menu bar's Output submenu, for the same reason.
    static let menuOutputPicker = "menuOutputPicker"

    /// Menu bar job row's Remove button on a failed job, addressed by ROW
    /// INDEX for the same reason as `jobRetryButton`.
    static func jobRemoveButton(_ index: Int) -> String {
        "jobRemoveButton.\(index)"
    }

    /// Menu bar item that opens the All Recordings window, "All Recordings…".
    static let allRecordingsMenuItem = "allRecordingsMenuItem"

    /// The menu's "Name Speakers…", the first line of "Needs you". Tests find
    /// it by this value: the state line of a job waiting for names reads
    /// "Name Speakers..." too.
    static let nameSpeakersMenuItem = "nameSpeakersMenuItem"

    /// The menu's items under "Record & Import" and "Open Last Protocol".
    /// Tests find them by these values: the open recording prompt has a
    /// "Record with Options…" button of its own.
    static let recordMicrophoneMenuItem = "recordMicrophoneMenuItem"
    static let recordWithOptionsMenuItem = "recordWithOptionsMenuItem"
    static let importFilesMenuItem = "importFilesMenuItem"
    static let openLastProtocolMenuItem = "openLastProtocolMenuItem"

    /// The menu's Pause Recording / Resume Recording item: one identifier for
    /// both labels, since it is one item whose label follows the state.
    static let pauseResumeRecording = "pauseResumeRecording"

    /// The menu's "Install Update: <summary>" item (mt-update mode). No
    /// summary in it, so the value stays fixed; kept off the `/ui/press`
    /// allowlist like `updateInstallButton`.
    static let menuInstallUpdateButton = "menuInstallUpdateButton"

    // All Recordings window. Its rows show meeting titles and participants,
    // so the per-row controls are addressed by ROW INDEX in the filtered list,
    // like `jobRetryButton`, and no identifier carries a title, participant or
    // path.
    static let transcriptionsSearchField = "transcriptionsSearchField"

    /// The toolbar's "Open Protocols Folder" and "Regenerate from File…".
    static let recordingsOpenFolderButton = "recordingsOpenFolderButton"
    static let recordingsRegenerateFromFileButton = "recordingsRegenerateFromFileButton"

    /// A row's one main button, whose label follows the row's state.
    static func recordingMainButton(_ index: Int) -> String {
        "recordingMainButton.\(index)"
    }

    /// A row's "…" menu, whose items its right-click menu repeats.
    static func recordingMoreButton(_ index: Int) -> String {
        "recordingMoreButton.\(index)"
    }

    static func recordingMenuOpenProtocol(_ index: Int) -> String {
        "recordingMenuOpenProtocol.\(index)"
    }

    static func recordingMenuOpenTranscript(_ index: Int) -> String {
        "recordingMenuOpenTranscript.\(index)"
    }

    static func recordingMenuShowInFinder(_ index: Int) -> String {
        "recordingMenuShowInFinder.\(index)"
    }

    static func recordingMenuRegenerate(_ index: Int) -> String {
        "recordingMenuRegenerate.\(index)"
    }

    static func recordingMenuRetry(_ index: Int) -> String {
        "recordingMenuRetry.\(index)"
    }

    static func recordingMenuRemove(_ index: Int) -> String {
        "recordingMenuRemove.\(index)"
    }

    static func recordingMenuDismiss(_ index: Int) -> String {
        "recordingMenuDismiss.\(index)"
    }

    /// The menu's answers to the open recording prompt. No app name, for the
    /// reason on `consentDeniedAppRemove`.
    static let consentPromptRecord = "consentPromptRecord"
    static let consentPromptRecordWithOptions = "consentPromptRecordWithOptions"
    static let consentPromptIgnore = "consentPromptIgnore"

    /// The Record Meeting window's buttons. The window shows background text
    /// and stays off every RPC allowlist.
    static let consentOptionsRecordButton = "consentOptionsRecordButton"
    static let consentOptionsCancelButton = "consentOptionsCancelButton"

    static let recordOnlyBanner = "recordOnlyBanner"
    static let transcriptionSection = "transcriptionSection"
    static let protocolSection = "protocolSection"
    static let protocolProviderPicker = "protocolProviderPicker"
    static let codexProviderNote = "codexProviderNote"
    static let customCommandEditor = "customCommandEditor"
    static let customCommandModelField = "customCommandModelField"
    /// The local model's Choose… opens a folder panel, so it stays off the
    /// `/ui/press` allowlist. The status line's identifier carries no path or
    /// model name.
    static let localModelChooseFolderButton = "localModelChooseFolderButton"
    static let localModelCheckButton = "localModelCheckButton"
    static let localModelStatus = "localModelStatus"
    static let protocolTemplateDefaultPicker = "protocolTemplateDefaultPicker"
    static let protocolTemplateNameField = "protocolTemplateNameField"
    static let protocolTemplateCreateButton = "protocolTemplateCreateButton"
    static let protocolTemplatesOpenFolderButton = "protocolTemplatesOpenFolderButton"

    /// A template row's Edit button, addressed by ROW INDEX, never by template
    /// name: the name is user input, for the reason on `consentDeniedAppRemove`.
    static func protocolTemplateEdit(_ index: Int) -> String {
        "protocolTemplateEdit.\(index)"
    }

    /// A template row's Delete button, addressed like `protocolTemplateEdit`.
    static func protocolTemplateDelete(_ index: Int) -> String {
        "protocolTemplateDelete.\(index)"
    }

    /// The per-recording options form (`ProtocolOptionsForm`). Constants only:
    /// its windows show background text and stay off every RPC allowlist.
    static let protocolOptionsTemplatePicker = "protocolOptionsTemplatePicker"
    static let protocolOptionsBackgroundEditor = "protocolOptionsBackgroundEditor"
    static let protocolOptionsDestinationNotice = "protocolOptionsDestinationNotice"

    /// "Regenerate Protocol…" in the menu, and its window's controls. The
    /// window shows background text and stays off every RPC allowlist.
    static let regenerateProtocolMenuItem = "regenerateProtocolMenuItem"
    static let regenerateChooseFileButton = "regenerateChooseFileButton"
    static let regenerateGenerateButton = "regenerateGenerateButton"

    static let includeFullTranscriptToggle = "includeFullTranscriptToggle"
    static let saveRawTranscriptToggle = "saveRawTranscriptToggle"
    static let outputFolderSection = "outputFolderSection"
    static let vadSection = "vadSection"
    static let echoCancellationToggle = "echoCancellationToggle"
    static let echoDedupToggle = "echoDedupToggle"
    static let diarizationSection = "diarizationSection"
    static let liveTranscriptionSection = "liveTranscriptionSection"
    static let liveCaptionsOverlayToggle = "liveCaptionsOverlayToggle"
    static let liveCaptionsSizePicker = "liveCaptionsSizePicker"
    static let channelIndicatorSection = "channelIndicatorSection"
    static let silentTrackWatchdogToggle = "silentTrackWatchdogToggle"
    static let levelBalanceToggle = "levelBalanceToggle"
    static let experimentalTuningDisclosure = "experimentalTuningDisclosure"
    static let diarizationMethodPicker = "diarizationMethodPicker"
    static let diarizationMethodHint = "diarizationMethodHint"
    static let expectedSpeakersStepper = "expectedSpeakersStepper"

    /// One permission row's request button in Settings → Advanced → Permissions.
    static func permissionRequestButton(_ kind: PermissionKind) -> String {
        "permissionRequestButton.\(kind.rawValue)"
    }

    /// The note under the Screen Recording row, shown only while it is not granted.
    static let screenRecordingRestartNote = "screenRecordingRestartNote"

    /// Mic speaker-name field (Settings → Speakers). The `/ui/type` allowlist's
    /// only entry: a plain, non-secret text field whose write-back is readable in
    /// `/state`, which is what makes it a usable text-entry probe.
    static let micNameField = "micNameField"
    static let customVocabularyPathField = "customVocabularyPathField"
    static let customVocabularyFileRow = "customVocabularyFileRow"
    static let vocabularySourcePicker = "vocabularySourcePicker"
    static let remoteVocabularyURLField = "remoteVocabularyURLField"
    static let remoteVocabularyTokenField = "remoteVocabularyTokenField"
    static let remoteVocabularyUpdateButton = "remoteVocabularyUpdateButton"
    static let remoteVocabularyStatus = "remoteVocabularyStatus"
    static let whisperKitVocabularyPromptToggle = "whisperKitVocabularyPromptToggle"
    static let whisperKitModelPicker = "whisperKitModelPicker"
    static let whisperKitCustomRepoField = "whisperKitCustomRepoField"
    static let whisperKitCustomVariantField = "whisperKitCustomVariantField"
    static let whisperKitCustomModelFolderField = "whisperKitCustomModelFolderField"
    static let huggingFaceTokenField = "huggingFaceTokenField"
    static let huggingFaceTokenSaveButton = "huggingFaceTokenSaveButton"
    static let huggingFaceTokenRemoveButton = "huggingFaceTokenRemoveButton"
    static let huggingFaceTokenProblem = "huggingFaceTokenProblem"

    // Hugging Face model browser, a sheet over Settings. `/ui/tree` prunes
    // sheets, so the repository ids and variant names in the row identifiers
    // below never reach it; they are the names the rows already show.
    static let huggingFaceSearchField = "huggingFaceSearchField"

    /// One search result, addressed by its repository id.
    static func huggingFaceResult(_ repoID: String) -> String {
        "huggingFaceResult.\(repoID)"
    }

    static let huggingFaceBackButton = "huggingFaceBackButton"
    static let huggingFaceModelCardLink = "huggingFaceModelCardLink"

    /// One variant's "Use" button, addressed by the variant's folder name.
    static func huggingFaceUseVariant(_ name: String) -> String {
        "huggingFaceUseVariant.\(name)"
    }

    static let huggingFaceCancelButton = "huggingFaceCancelButton"
    static let whisperKitLoadFailureMessage = "whisperKitLoadFailureMessage"
    static let terminologyRulesEditor = "terminologyRulesEditor"

    /// Settings sidebar row for one tab (`settings-tab-<rawValue>`). The detail
    /// pane renders only the selected tab, so a control in another tab is absent
    /// from the accessibility tree until its row is selected — a driver switches
    /// tabs through these before driving anything outside General.
    static func settingsTab(_ rawValue: String) -> String {
        "settings-tab-\(rawValue)"
    }

    /// A tab row the `/ui/press` allowlist admits. A named constant rather
    /// than a literal at the allowlist, so the identifier has a single home.
    static let settingsTabSpeakers = settingsTab("speakers")

    /// Same single-home pattern for the About tab.
    static let settingsTabAbout = settingsTab("about")

    /// About → Updates "Install Update" (mt-update mode). Kept off the
    /// `/ui/press` allowlist (`AboutSettingsViewTests`).
    static let updateInstallButton = "updateInstallButton"

    // Speaker-naming dialog.
    static let confirmButton = "confirm-button"
    static let skipButton = "skip-button"
    static let rerunButton = "rerun-button"
    static let rerunStepper = "rerun-stepper"
    static let rerunModePicker = "rerun-mode-picker"
    /// The dialog's hint that the picked method counts the speakers itself
    /// (Sortformer, Nemotron 3); absent while Standard is picked.
    static let rerunMethodHint = "rerun-method-hint"
    /// The line under the Standard count of a two-track job saying the
    /// microphone side is counted automatically; absent for a single file.
    static let rerunMicSideNote = "rerun-mic-side-note"

    /// Per-speaker play button (`play-<label>`); the label varies at runtime.
    static func play(_ speakerLabel: String) -> String {
        "play-\(speakerLabel)"
    }

    /// Prefix for the per-participant name chips (`participant-name-<name>`);
    /// the name is appended at the call site.
    static let participantNamePrefix = "participant-name-"

    /// Prefix for the per-speaker name fields (`speaker-name-<label>`).
    /// Consumed out of band by `scripts/drive-naming-field.swift` (the
    /// `--naming-switch` e2e lane), which matches the raw `speaker-name-`
    /// string by AX identifier and is not compiler-checked. A rename here
    /// leaves the whole unit suite green and breaks only that self-hosted lane,
    /// which PRs do not run, so change both together.
    static let speakerNamePrefix = "speaker-name-"

    static func speakerName(_ speakerLabel: String) -> String {
        "\(speakerNamePrefix)\(speakerLabel)"
    }

    static func knownName(_ name: String) -> String {
        "known-name-\(name)"
    }

    static func knownMore(_ speakerLabel: String) -> String {
        "known-more-\(speakerLabel)"
    }

    static func knownLess(_ speakerLabel: String) -> String {
        "known-less-\(speakerLabel)"
    }

    // Live captions overlay.
    static let liveCaptionBackend = "liveCaptionBackend"
}
