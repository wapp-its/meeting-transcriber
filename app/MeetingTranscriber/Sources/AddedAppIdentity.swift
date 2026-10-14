/// The identity key of an app added through "Add App…" (Settings → General →
/// Apps to Watch): the key its detection and consent state is filed under
/// (`AppMeetingPattern.identityKey`).
///
/// An added app is keyed by its bundle ID, not its display name, because the
/// display name can equal a built-in app's or another added app's. Filed under
/// the name, a "Never for this app", a cooldown or a "call still running"
/// check for one app would apply to the other as well. Built-in apps and
/// browser identities keep their names as keys.
///
/// The prefix keeps the two kinds of key apart: a bundle ID never contains a
/// colon, and a built-in or browser key is a plain name. Nothing else spells
/// the prefix; keys are built and read through this type only.
enum AddedAppIdentity {
    private static let prefix = "custom:"

    static func key(bundleID: String) -> String {
        prefix + bundleID
    }

    /// The bundle ID `key` was built from; nil for any key that is not an
    /// added app's.
    static func bundleID(fromKey key: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }
}
