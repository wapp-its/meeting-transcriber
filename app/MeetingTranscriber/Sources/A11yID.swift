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

    static let recordOnlyBanner = "recordOnlyBanner"
    static let transcriptionSection = "transcriptionSection"
    static let protocolSection = "protocolSection"
    static let protocolProviderPicker = "protocolProviderPicker"
    static let codexProviderNote = "codexProviderNote"
    static let customCommandEditor = "customCommandEditor"
    static let customCommandModelField = "customCommandModelField"
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
    static let speakerCapHint = "speaker-cap-hint"

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
    static let whisperKitVocabularyPromptToggle = "whisperKitVocabularyPromptToggle"
    static let whisperKitModelPicker = "whisperKitModelPicker"
    static let whisperKitCustomRepoField = "whisperKitCustomRepoField"
    static let whisperKitCustomVariantField = "whisperKitCustomVariantField"
    static let whisperKitCustomModelFolderField = "whisperKitCustomModelFolderField"
    static let huggingFaceTokenField = "huggingFaceTokenField"
    static let huggingFaceTokenSaveButton = "huggingFaceTokenSaveButton"
    static let huggingFaceTokenRemoveButton = "huggingFaceTokenRemoveButton"
    static let huggingFaceTokenProblem = "huggingFaceTokenProblem"
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

    // Speaker-naming dialog.
    static let confirmButton = "confirm-button"
    static let skipButton = "skip-button"
    static let rerunButton = "rerun-button"
    static let rerunStepper = "rerun-stepper"
    static let rerunModePicker = "rerun-mode-picker"

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
