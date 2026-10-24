import Foundation
import Testing
@testable import TerminalUIConfig
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// A debug build traces its first frames — every key typed included — and
// takes screenshots into `/tmp/terminalui-{hash}-{pid}/`, a path anyone on
// the machine can predict. Created with the default mode it was readable by
// every local user, and a directory another user made there first was
// written into all the same. The data dir is made private to its owner, and
// one that is not is refused.

@Suite("A debug app's output is its owner's alone")
struct DiagPathsPrivacyTests {

    private func scratch() -> String {
        let path = NSTemporaryDirectory() + "terminalui-privacy-\(UUID().uuidString)"
        return path
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    @Test func aDirectoryItCreatesIsItsOwnersAlone() {
        let path = scratch()
        defer { rmdir(path) }
        #expect(DiagPaths.ensurePrivateDirectory(atPath: path))
        #expect(mode(path) & 0o077 == 0, "mode \(String(mode(path), radix: 8))")
    }

    @Test func aPrivateDirectoryAlreadyThereIsUsed() {
        let path = scratch()
        defer { rmdir(path) }
        mkdir(path, 0o700)
        #expect(DiagPaths.ensurePrivateDirectory(atPath: path))
    }

    @Test func aDirectoryOthersCanReadIsRefused() {
        let path = scratch()
        defer { rmdir(path) }
        mkdir(path, 0o700)
        chmod(path, 0o755)
        #expect(!DiagPaths.ensurePrivateDirectory(atPath: path))
    }

    /// A link planted at the path would send the output wherever it points.
    @Test func aSymlinkIsRefused() {
        let target = scratch()
        let path = scratch()
        defer { unlink(path); rmdir(target) }
        mkdir(target, 0o700)
        symlink(target, path)
        #expect(!DiagPaths.ensurePrivateDirectory(atPath: path))
    }

    @Test func aFileIsRefused() {
        let path = scratch()
        defer { unlink(path) }
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        #expect(!DiagPaths.ensurePrivateDirectory(atPath: path))
    }
}
