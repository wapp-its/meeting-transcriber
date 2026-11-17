import Foundation

extension DateFormatter {
    /// A `DateFormatter` with the given format, pinned to the Gregorian calendar
    /// and the POSIX locale. Filename stamps are the primary sort key for saved
    /// files, so they must not resolve `yyyy` in the user's regional calendar
    /// (e.g. a Buddhist or Japanese-era year) or localize digits. Timezone stays
    /// `.current` so the stamp reads in local time.
    static func filenameStamp(_ format: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = format
        return fmt
    }

    /// The stamp in the name of a file kept beside a meeting's current one, to the
    /// second: a re-run's own files and the earlier versions it keeps
    /// (`EarlierVersionName`), and the copies Regenerate Notes keeps.
    static let fileVersionStamp = filenameStamp("yyyyMMdd_HHmmss")
}
