#if !APPSTORE

    import Foundation

    /// Finds the helper executable in the app bundle. Both places a bundle
    /// keeps a helper tool are searched: `Contents/Helpers` first, where the
    /// build scripts place it (beside the app's executable in `Contents/MacOS`
    /// the helper takes the app as its main bundle and does not find its
    /// shaders), then `Contents/MacOS`. A test passes its own executable to
    /// the generator instead.
    enum LocalModelHelperLocator {
        static let executableName = "local-llm-helper"

        static func locate(inBundleAt bundleURL: URL = Bundle.main.bundleURL) -> URL? {
            ["Helpers", "MacOS"]
                .map { bundleURL.appendingPathComponent("Contents/\($0)/\(executableName)") }
                .first(where: isExecutableFile)
        }

        /// A regular file (after following symlinks) this process may execute.
        static func isExecutableFile(_ url: URL) -> Bool {
            var status = stat()
            return stat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
                && FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

#endif
