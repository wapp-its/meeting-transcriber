import Foundation

/// Opens or reveals a job's protocol or transcript for the Transcriptions
/// window and the menu, and says when the file is no longer there.
enum TranscriptionFileOpener {
    /// Runs `action` on `url` inside the security scope of `scopeRoot`, the
    /// output folder the user picked, as `openProtocolsFolder` does: a history
    /// entry can be opened right after launch, before any queue holds that
    /// folder's scope, and in the sandboxed build the file is out of reach
    /// without it. The existence check runs inside the scope for the same
    /// reason.
    ///
    /// Returns false, without calling `action`, when the file does not exist,
    /// so the caller can say it was moved or deleted instead of nothing
    /// happening.
    static func perform(
        _ url: URL,
        scopeRoot: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        action: (URL) -> Void,
    ) -> Bool {
        let accessing = scopeRoot.startAccessingSecurityScopedResource()
        defer { if accessing { scopeRoot.stopAccessingSecurityScopedResource() } }
        guard fileExists(url) else { return false }
        action(url)
        return true
    }
}
