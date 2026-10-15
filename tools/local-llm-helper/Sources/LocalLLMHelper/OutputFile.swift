import Darwin
import Foundation

/// The protocol text as it is generated. Each decoded piece goes to the file
/// with its own write(2) at once, so a helper that is killed leaves everything
/// it decoded; `sync()` makes it durable at every progress step.
final class OutputFile: Sendable {
    /// An errno from creating or writing the file. The path and the text
    /// are deliberately not part of it.
    struct Failure: Error {
        let code: Int32
    }

    private let descriptor: Int32

    /// Creates or truncates the file owner-only. A symlink in place of the
    /// file is refused rather than followed.
    init(path: String) throws(Failure) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure(code: errno) }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func append(_ text: String) throws(Failure) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw Failure(code: errno)
            }
            offset += written
        }
    }

    func sync() {
        fsync(descriptor)
    }
}
