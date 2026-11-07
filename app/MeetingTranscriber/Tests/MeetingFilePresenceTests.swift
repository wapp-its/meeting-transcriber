@testable import MeetingTranscriber
import XCTest

/// The one probe every part of the record and of a deletion asks: is a file
/// there, truly gone, or out of reach? Only "gone" may ever change a record, so
/// each way of being out of reach is pinned against the real file system.
final class MeetingFilePresenceTests: XCTestCase {
    private func makeFile(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("meeting_mix.wav")
        try Data("audio".utf8).write(to: url)
        return url
    }

    /// Takes `permissions` from `dir` for the rest of the test, and gives them
    /// back before the temp folder is removed.
    private func restrict(_ dir: URL, to permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: dir.path)
        let path = dir.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    func testAFileThatIsThereIsPresent() throws {
        let file = try makeFile(in: makeTempDirectory(prefix: "presence"))

        XCTAssertEqual(MeetingFilePresence.of(file.path), .present)
    }

    func testAFileRemovedFromAReadableFolderIsGone() throws {
        let file = try makeFile(in: makeTempDirectory(prefix: "presence"))
        try FileManager.default.removeItem(at: file)

        XCTAssertEqual(MeetingFilePresence.of(file.path), .gone)
    }

    /// A drive that is not connected looks exactly like this: the file system
    /// says the file does not exist, because its whole folder does not.
    func testAFileInAMissingFolderIsUnreachable() throws {
        let dir = try makeTempDirectory(prefix: "presence")
        let file = dir.appendingPathComponent("not-mounted/recordings/meeting_mix.wav")

        XCTAssertEqual(MeetingFilePresence.of(file.path), .unreachable)
    }

    func testAnExistingFileBehindAFolderWithoutSearchPermissionIsUnreachable() throws {
        let dir = try makeTempDirectory(prefix: "presence")
        let file = try makeFile(in: dir)
        try restrict(dir, to: 0o600)

        XCTAssertEqual(MeetingFilePresence.of(file.path), .unreachable)
    }

    /// The file system does answer "no such file" here, but nobody who cannot
    /// read the folder can tell that answer from one about a stale view of it.
    func testAMissingFileInAFolderThatCannotBeReadIsUnreachable() throws {
        let dir = try makeTempDirectory(prefix: "presence")
        let file = dir.appendingPathComponent("meeting_mix.wav")
        try restrict(dir, to: 0o300)

        XCTAssertEqual(MeetingFilePresence.of(file.path), .unreachable)
    }

    /// A link whose target went is still something at that path, and it is
    /// never to be counted as the file having been removed.
    func testABrokenSymbolicLinkIsPresent() throws {
        let dir = try makeTempDirectory(prefix: "presence")
        let link = dir.appendingPathComponent("meeting_mix.wav")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: dir.appendingPathComponent("target-that-is-not-there"),
        )

        XCTAssertEqual(MeetingFilePresence.of(link.path), .present)
    }

    func testAnIdentityMatchesTheFileSystemsNumberForTheFile() throws {
        let file = try makeFile(in: makeTempDirectory(prefix: "identity"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)

        let identity = try XCTUnwrap(FileIdentity.of(file.path))

        XCTAssertEqual(identity.inode, attributes[.systemFileNumber] as? UInt64)
        XCTAssertEqual(identity.device, (attributes[.systemNumber] as? Int).map(Int64.init))
    }

    /// What a deletion relies on: the identity names the file, so a rename keeps
    /// it and an atomic rewrite of the same name does not.
    func testAnIdentityFollowsTheFileAndNotItsName() throws {
        let dir = try makeTempDirectory(prefix: "identity")
        let file = try makeFile(in: dir)
        let identity = try XCTUnwrap(FileIdentity.of(file.path))
        let renamed = dir.appendingPathComponent("renamed.wav")

        try FileManager.default.moveItem(at: file, to: renamed)
        XCTAssertEqual(FileIdentity.of(renamed.path), identity)

        try Data("rewritten".utf8).write(to: renamed, options: .atomic)
        let rewritten = try XCTUnwrap(FileIdentity.of(renamed.path))
        XCTAssertNotEqual(rewritten, identity)
    }

    func testAMissingFileHasNoIdentity() throws {
        let dir = try makeTempDirectory(prefix: "identity")

        XCTAssertNil(FileIdentity.of(dir.appendingPathComponent("nothing.wav").path))
    }
}
