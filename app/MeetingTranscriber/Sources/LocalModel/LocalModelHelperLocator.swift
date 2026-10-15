#if !APPSTORE

    import Foundation

    /// Finds the helper executable in the app bundle. The build scripts decide
    /// where they place it, so both places a bundle keeps a helper tool are
    /// searched, in this order: `Contents/MacOS` (beside the app's executable),
    /// then `Contents/Helpers`. A test passes its own executable to the
    /// generator instead.
    enum LocalModelHelperLocator {
        static let executableName = "local-llm-helper"

        static func locate(inBundleAt bundleURL: URL = Bundle.main.bundleURL) -> URL? {
            ["MacOS", "Helpers"]
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
