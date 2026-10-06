import CoreGraphics

/// Pattern definition for detecting active meetings via window titles.
struct AppMeetingPattern: Equatable {
    let appName: String
    let ownerNames: [String]
    let meetingPatterns: [String]
    let idlePatterns: [String]
    let minWindowWidth: CGFloat
    let minWindowHeight: CGFloat
    /// When true, a detected meeting for this app is always confirmed by the
    /// user before recording starts, whatever the "record without asking"
    /// setting says. Browser meetings set this (issue #503): the WebRTC power
    /// assertion that detects them fires for any WebRTC use, not just meetings,
    /// so the prompt is the false-positive filter and must not be switched off.
    /// Native desktop clients leave it false, and then the setting decides
    /// (see `asksBeforeRecording(recordWithoutAsking:)`).
    let requiresRecordingConsent: Bool

    init(
        appName: String,
        ownerNames: [String],
        meetingPatterns: [String],
        idlePatterns: [String] = [],
        minWindowWidth: CGFloat = 200,
        minWindowHeight: CGFloat = 200,
        requiresRecordingConsent: Bool = false,
    ) {
        self.appName = appName
        self.ownerNames = ownerNames
        self.meetingPatterns = meetingPatterns
        self.idlePatterns = idlePatterns
        self.minWindowWidth = minWindowWidth
        self.minWindowHeight = minWindowHeight
        self.requiresRecordingConsent = requiresRecordingConsent
    }
}

extension AppMeetingPattern {
    static let teams = AppMeetingPattern(
        appName: "Microsoft Teams",
        ownerNames: ["Microsoft Teams", "Microsoft Teams (work or school)"],
        meetingPatterns: [
            #".+\s+\|\s+Microsoft Teams"#,
        ],
        idlePatterns: [
            #"^Microsoft Teams$"#,
            #"^Microsoft Teams \(work or school\)$"#,
            #"^Chat \|"#,
            #"^Activity \|"#,
            #"^Calendar \|"#,
            #"^Teams \|"#,
            #"^Files \|"#,
            #"^Assignments \|"#,
            #"^Settings \|"#,
            #"^Calls \|"#,
            #"^People \|"#,
            #"^Notifications \|"#,
        ],
    )

    static let zoom = AppMeetingPattern(
        appName: "Zoom",
        ownerNames: ["zoom.us"],
        meetingPatterns: [
            #"^Zoom Meeting$"#,
            #"^Zoom Webinar$"#,
            #".+\s*-\s*Zoom$"#,
        ],
        idlePatterns: [
            #"^Zoom$"#,
            #"^Zoom Workplace$"#,
            #"^Home$"#,
        ],
    )

    static let webex = AppMeetingPattern(
        appName: "Webex",
        ownerNames: ["Webex", "Cisco Webex Meetings"],
        meetingPatterns: [
            #".+\s*-\s*Webex$"#,
            #"^Meeting \|"#,
            #".+'s Personal Room"#,
        ],
        idlePatterns: [
            #"^Webex$"#,
            #"^Cisco Webex Meetings$"#,
        ],
    )

    /// Debug simulator for testing the full pipeline without a real meeting app.
    /// Run: cd tools/meeting-simulator && swift run
    static let simulator = AppMeetingPattern(
        appName: "MeetingSimulator",
        ownerNames: ["meeting-simulator"],
        meetingPatterns: [
            #"Simulator Meeting"#,
        ],
        minWindowWidth: 100,
        minWindowHeight: 100,
    )

    /// Browser-based meetings (Google Meet, Whereby, web Zoom/Teams/Webex) run
    /// inside a Chromium browser, which the native-app patterns above miss
    /// (issue #503). Detection is by the WebRTC power assertion (see
    /// `PowerAssertionDetector`), not window titles — a browser's window title
    /// only reflects the active tab.
    ///
    /// This is a *category*, not an identity: a detected call is carried under
    /// the concrete browser process ("Brave Browser"), synthesised per hit by
    /// `PowerAssertionDetector.meetingIdentity`. The category exists so the
    /// master toggle has a token to append to `watchApps`, and so the
    /// `requiresRecordingConsent` policy has one home. `appName` is therefore a
    /// token no real process can carry, and `ownerNames` is empty: a shared
    /// owner list would let any fork's window title be picked for another
    /// fork's meeting. `meetingPatterns` is empty (no title-based detection).
    static let browserMeetings = AppMeetingPattern(
        appName: "Browser Meetings",
        ownerNames: [],
        meetingPatterns: [],
        requiresRecordingConsent: true,
    )

    // Call apps detected by mic input rather than assertions or window titles
    // (see `MicInputDetector`): their in-call assertions are unnamed or absent
    // and their call-window titles are localized/unstable, so `meetingPatterns`
    // stays empty and titles fall back to the "<App> Call" placeholder.

    static let wechat = AppMeetingPattern(
        appName: "WeChat",
        ownerNames: ["WeChat", "微信"],
        meetingPatterns: [],
    )

    static let tencentMeeting = AppMeetingPattern(
        appName: "Tencent Meeting",
        ownerNames: ["TencentMeeting", "腾讯会议", "WeMeet", "wemeetapp"],
        meetingPatterns: [],
    )

    static let faceTime = AppMeetingPattern(
        appName: "FaceTime",
        ownerNames: ["FaceTime"],
        meetingPatterns: [],
    )

    static let whatsApp = AppMeetingPattern(
        appName: "WhatsApp",
        ownerNames: ["WhatsApp"],
        meetingPatterns: [],
    )

    static let all: [AppMeetingPattern] = [teams, zoom, webex, simulator, browserMeetings, wechat, tencentMeeting, faceTime, whatsApp]

    /// The apps Settings offers a "record without asking" switch for, in the
    /// order "Apps to Watch" lists them. Browser meetings are not among them
    /// (see `requiresRecordingConsent`), and neither is the simulator, which
    /// never asks.
    static let recordWithoutAskingCandidates: [AppMeetingPattern] = [
        teams, zoom, webex, wechat, tencentMeeting, faceTime, whatsApp,
    ]

    /// Whether a meeting detected under this pattern waits for the user's
    /// answer before it records. Every watched app asks unless the user listed
    /// it in `recordWithoutAsking` (`AppSettings.recordWithoutAskingApps`).
    ///
    /// A listed name counts only for the built-in pattern itself, compared
    /// whole and not by name: a stored name that matches no such app (a
    /// browser, or a typo) never turns a prompt off, and neither does an app
    /// added through "Add App…" that happens to carry a built-in's name,
    /// since its synthesised pattern differs from the built-in one. Anything this
    /// function does not recognise asks: failing towards the question is the
    /// safe side, since the cost of a needless prompt is a click and the cost of
    /// a missing one is a recording nobody agreed to.
    func asksBeforeRecording(recordWithoutAsking: [String]) -> Bool {
        if requiresRecordingConsent { return true }
        // The meeting simulator is the fixture the end-to-end lanes record with
        // (`tools/meeting-simulator`); nobody is there to answer a prompt, so it
        // records at once. It is not a watchable app and has no switch.
        if self == Self.simulator { return false }
        let isCandidate = Self.recordWithoutAskingCandidates.contains(self)
        return !(isCandidate && recordWithoutAsking.contains(appName))
    }

    static let byName: [String: AppMeetingPattern] = {
        var dict: [String: AppMeetingPattern] = [:]
        for p in all {
            dict[p.appName.lowercased()] = p
        }
        return dict
    }()

    /// Lookup pattern by app name (case-insensitive).
    static func forAppName(_ name: String) -> AppMeetingPattern? {
        byName[name.lowercased()]
    }
}
