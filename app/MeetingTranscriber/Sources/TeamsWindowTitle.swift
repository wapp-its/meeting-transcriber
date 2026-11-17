import Foundation

/// How much a Teams window title looks like the meeting window's (issue #258).
///
/// Teams ends most of its window titles with " | Microsoft Teams", its main
/// window's too ("<tab> | <organisation> | <account> | Microsoft Teams"), so a
/// title that only matches the Teams meeting pattern does not single out the
/// meeting window: whichever non-tab window came first in the system's window
/// list named the recording, another Teams window or the compact call window
/// among them. The windows are ranked instead, best first:
/// 1. the meeting window: three or more " | "-separated parts once the app's
///    suffix is removed ("Sprint Review | Contoso | user@contoso.com");
/// 2. the compact call window, "Meeting compact view | <title>", whose title is
///    what follows the prefix;
/// 3. any other title with the app's suffix (a 1:1 call: "Jane Doe | Microsoft Teams");
/// 4. any other title.
/// The compact prefix is matched before the part count, so a compact window
/// never passes for the meeting window. Within a rank the first window in list
/// order wins (`MeetingTitleMatcher.selectRankedTitle(from:)`). The prefix is
/// Teams' English one; in another interface language the compact window ranks
/// 3 or 4. Only Teams is ranked: Zoom, Webex and the apps detected by
/// microphone keep `MeetingTitleMatcher.selectWindowTitle(from:)`.
enum TeamsWindowTitle {
    /// A lower raw value is a better rank.
    enum Rank: Int, Comparable {
        case meetingWindow = 1
        case compactCallWindow = 2
        case teamsWindow = 3
        case otherWindow = 4

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    static let appSuffix = " | Microsoft Teams"
    static let compactPrefix = "Meeting compact view"
    private static let separator = " | "

    /// Whether the meetings of `pattern` are named by rank: Teams only.
    static func ranks(_ pattern: AppMeetingPattern) -> Bool {
        pattern.identityKey == AppMeetingPattern.teams.identityKey
    }

    /// The rank of a window title that passed the matcher's checks (owner,
    /// empty, app name, idle tab); nil for a compact call window with nothing
    /// after its prefix, which is skipped.
    static func rank(of title: String) -> Rank? {
        let body = withoutAppSuffix(title)
        if let rest = afterCompactPrefix(body) { return rest.isEmpty ? nil : .compactCallWindow }
        if partCount(of: title) >= 3 { return .meetingWindow }
        return title.hasSuffix(appSuffix) ? .teamsWindow : .otherWindow
    }

    /// The number of " | "-separated parts once a trailing app suffix is removed.
    static func partCount(of title: String) -> Int {
        withoutAppSuffix(title).components(separatedBy: separator).count
    }

    /// `title` without a compact call window's prefix; unchanged when it has
    /// none, or nothing follows it.
    static func withoutCompactPrefix(_ title: String) -> String {
        guard let rest = afterCompactPrefix(title), !rest.isEmpty else { return title }
        return rest
    }

    private static func withoutAppSuffix(_ title: String) -> String {
        title.hasSuffix(appSuffix) ? String(title.dropLast(appSuffix.count)) : title
    }

    /// What follows the compact prefix, trimmed, empty when nothing does; nil
    /// when `body` is not a compact call window's title.
    private static func afterCompactPrefix(_ body: String) -> String? {
        if body == compactPrefix { return "" }
        let prefix = compactPrefix + separator
        guard body.hasPrefix(prefix) else { return nil }
        return String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// A window title with its Teams rank (`TeamsWindowTitle`).
struct RankedWindowTitle: Equatable {
    let title: String
    let rank: TeamsWindowTitle.Rank
}
