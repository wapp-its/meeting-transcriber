#if !APPSTORE

    import Darwin
    import Foundation

    /// The private directory one helper run works in. It holds the request
    /// (with the prompt, so the transcript and the background info) and the
    /// protocol the helper writes, so it is owner-only (`0700`) and removed when
    /// the helper has exited. A run the app could not clean up after (a crash,
    /// a force quit) leaves one behind, and the next launch removes it.
    ///
    /// The name carries the creating process's pid, so that sweep removes only
    /// directories whose process is gone: the dev and release builds, and a test
    /// process, share the per-user temporary directory, and a sweep that took
    /// every match would pull the directory out from under another instance's
    /// running helper.
    enum LocalModelRunDirectory {
        static let namePrefix = "MeetingTranscriber-localmodel-"

        /// A new, empty run directory under `parent`. Creation fails rather than
        /// reuse a directory that already exists.
        static func make(in parent: URL) throws -> URL {
            let directory = parent.appendingPathComponent("\(namePrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700],
            )
            return directory
        }

        /// Removes the run directories in `parent` left by processes that no
        /// longer run, and returns how many it removed.
        static func removeLeftovers(in parent: URL) -> Int {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            var removed = 0
            for name in names where name.hasPrefix(namePrefix) {
                guard let pid = pid_t(name.dropFirst(namePrefix.count).prefix { $0 != "-" }),
                      pid != getpid(), !processExists(pid)
                else { continue }
                if (try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))) != nil { removed += 1 }
            }
            return removed
        }

        /// Whether a process with `pid` runs, including one of another user,
        /// which `kill` refuses with `EPERM`.
        private static func processExists(_ pid: pid_t) -> Bool {
            kill(pid, 0) == 0 || errno == EPERM
        }
    }

#endif
