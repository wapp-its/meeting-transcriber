import Foundation

enum CustomVocabularyValidation: Equatable {
    case notConfigured
    case empty
    case unavailable
    case tooLarge
    case tooManyTerms
    case termTooLong
    case ready(termCount: Int)

    var message: String {
        switch self {
        case .notConfigured: "No vocabulary file selected."
        case .empty: "Vocabulary file contains no terms."
        case .unavailable: "Vocabulary file cannot be read."
        case .tooLarge: "Vocabulary file is too large."
        case .tooManyTerms: "Vocabulary file contains too many terms."
        case .termTooLong: "Vocabulary file contains a term that is too long."
        case let .ready(termCount): "Vocabulary file can be read: \(termCount) unique term\(termCount == 1 ? "" : "s")."
        }
    }

    /// Judges vocabulary contents against the limits both engines apply, for
    /// the local file and for a downloaded copy alike. The size is checked
    /// before `contents` is called, so an oversized file is never decoded.
    static func validate(byteCount: UInt64, contents: () -> String?) -> Self {
        guard byteCount <= UInt64(WhisperVocabularyPrompt.maximumFileBytes) else { return .tooLarge }
        guard let contents = contents() else { return .unavailable }
        let terms = WhisperVocabularyPrompt.terms(from: contents)
        guard !terms.isEmpty else { return .empty }
        guard terms.count <= WhisperVocabularyPrompt.maximumTermCount else { return .tooManyTerms }
        guard terms.allSatisfy({ $0.utf8.count <= WhisperVocabularyPrompt.maximumTermBytes }) else {
            return .termTooLong
        }
        return .ready(termCount: terms.count)
    }

    /// Validates downloaded bytes; bytes that are not UTF-8 are `.unavailable`.
    static func validate(data: Data) -> Self {
        validate(byteCount: UInt64(data.count)) { String(data: data, encoding: .utf8) }
    }
}

/// The vocabulary both engines read, whichever source supplies it.
extension AppSettings {
    /// The downloaded copies of the URL source, named for this build's bundle
    /// identifier because the dev and release builds share the data directory.
    var remoteVocabularyCache: RemoteVocabularyCache {
        RemoteVocabularyCache(
            directory: remoteVocabularyCacheDirectory,
            bundleID: Bundle.main.bundleIdentifier ?? "MeetingTranscriber",
        )
    }

    /// The local file for `.file`. For `.url`, the copy kept for the address
    /// configured now, or "" when that address is not fetched: the path is
    /// derived from the address, so terms downloaded for another address can
    /// never be read, and with no copy yet the engines run without vocabulary
    /// rather than falling back to the local file.
    var effectiveVocabularyPath: String {
        switch vocabularySource {
        case .file:
            customVocabularyPath

        case .url:
            if case .success = RemoteVocabulary.validateAddress(remoteVocabularyURL) {
                RemoteVocabularyCache.textFile(
                    in: remoteVocabularyCache.directory,
                    bundleID: remoteVocabularyCache.bundleID,
                    address: remoteVocabularyURL,
                ).path
            } else {
                ""
            }
        }
    }

    /// The local file's bookmark for `.file`; the cache needs none, it lives
    /// in the app's own data directory.
    var effectiveVocabularyBookmark: Data? {
        vocabularySource == .file ? customVocabularyBookmark : nil
    }
}

/// Security-scoped vocabulary-file handling. The plain path remains for UI
/// display and migration from earlier releases; reads must use the resolved URL
/// so the App Store build retains access after a relaunch.
extension AppSettings {
    var customVocabularyFile: URL? {
        var isStale = false
        guard let url = resolveCustomVocabularyFile(isStale: &isStale) else { return nil }
        if isStale,
           let refreshed = VocabularyFileAccess.withAccess(to: url, makeCustomVocabularyBookmark) {
            updateCustomVocabularySelection(path: url.path, bookmark: refreshed)
        }
        return url
    }

    func setCustomVocabularyFile(_ url: URL) {
        let bookmark = VocabularyFileAccess.withAccess(to: url) { scopedURL in
            makeCustomVocabularyBookmark(for: scopedURL)
        }
        updateCustomVocabularySelection(path: url.path, bookmark: bookmark)
        refreshCustomVocabularyValidation()
    }

    /// Handles manual path edits from the Settings text field. A bookmark is
    /// tied to its original URL, so retaining it after a different path was
    /// typed would silently read the wrong terminology file.
    func setCustomVocabularyPath(_ path: String) {
        guard path != customVocabularyPath else { return }
        updateCustomVocabularySelection(path: path, bookmark: nil)
        refreshCustomVocabularyValidation()
    }

    func clearCustomVocabularyFile() {
        updateCustomVocabularySelection(path: "", bookmark: nil)
        customVocabularyValidation = .notConfigured
    }

    func repairStaleCustomVocabularyBookmark() {
        var isStale = false
        guard let url = resolveCustomVocabularyFile(isStale: &isStale), isStale,
              let refreshed = VocabularyFileAccess.withAccess(to: url, makeCustomVocabularyBookmark)
        else { return }
        updateCustomVocabularySelection(path: url.path, bookmark: refreshed)
        refreshCustomVocabularyValidation()
    }

    func refreshCustomVocabularyValidation() {
        guard let url = customVocabularyFile else {
            customVocabularyValidation = customVocabularyPath.isEmpty ? .notConfigured : .unavailable
            return
        }
        customVocabularyValidation = VocabularyFileAccess.withAccess(to: url) { url in
            guard let revision = WhisperVocabularyPrompt.fileRevision(at: url.path) else { return .unavailable }
            return CustomVocabularyValidation.validate(byteCount: revision.fileSize) {
                try? String(contentsOf: url, encoding: .utf8)
            }
        }
    }

    private func resolveCustomVocabularyFile(isStale: inout Bool) -> URL? {
        if let bookmark = customVocabularyBookmark,
           let url = try? URL(
               resolvingBookmarkData: bookmark,
               options: .withSecurityScope,
               relativeTo: nil,
               bookmarkDataIsStale: &isStale,
           ) {
            return url
        }
        guard !customVocabularyPath.isEmpty else { return nil }
        return URL(fileURLWithPath: customVocabularyPath)
    }

    private func makeCustomVocabularyBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
    }
}
