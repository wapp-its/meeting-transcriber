#if !APPSTORE

    import Foundation

    /// The local model's folder as the settings name it: the plain path for
    /// display, and the security-scoped bookmark that reads go through, as for
    /// the custom WhisperKit model folder. Taken by value when a generator is
    /// made, so a later change never reaches a run that already started.
    struct LocalModelFolderSelection: Equatable, Sendable {
        let path: String
        let bookmark: Data?

        /// The folder to hand the helper, or nil when none is chosen or its
        /// bookmark no longer resolves.
        func resolve() -> URL? {
            path.isEmpty ? nil : VocabularyFileAccess.resolve(path: path, bookmark: bookmark)
        }
    }

    extension AppSettings {
        var localModelFolder: LocalModelFolderSelection {
            LocalModelFolderSelection(path: localModelFolderPath, bookmark: localModelFolderBookmark)
        }

        /// Chooses `url` as the local model folder, with a bookmark taken while
        /// its security scope is open (the folder panel's URL carries it).
        func setLocalModelFolder(_ url: URL) {
            let bookmark = VocabularyFileAccess.withAccess(to: url) { scopedURL in
                try? scopedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            updateLocalModelFolder(path: url.path, bookmark: bookmark)
        }
    }

#endif
