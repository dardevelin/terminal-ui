import Foundation
import Testing
@testable import TerminalUIConfig

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// A CLIENT process (swtui ctl) must never resolve sockets through its own
// `tmpDataDir` — the PID in that path is the client's, and no app ever
// wrote there. `swtui ctl` did exactly that after per-process isolation
// landed: every invocation looked in `/tmp/terminalui-{hash}-{its own
// transient pid}/remote/latest.sock` and failed, while the Python client
// (which globs the checkout's dirs) kept working — which is why no
// automated run ever noticed. These pin the client-side resolver.

@Suite("DiagPaths — client socket resolution", .serialized)
struct DiagPathsClientResolutionTests {

    /// Build a fake `{root}/terminalui-{cwdHash}-{pid}/remote` dir,
    /// optionally containing socket files.
    private func makeAppDir(root: String, pid: Int, sockets: [String]) throws -> String {
        let remote = "\(root)/terminalui-\(DiagPaths.cwdHash)-\(pid)/remote"
        try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
        for name in sockets {
            #expect(FileManager.default.createFile(atPath: "\(remote)/\(name)", contents: Data()))
        }
        return remote
    }

    private func withTempRoot(_ body: (String) throws -> Void) throws {
        let root = NSTemporaryDirectory() + "client-resolution-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    @Test func latestSockIsFoundAcrossAppDirsNotInOwnPidDir() throws {
        try withTempRoot { root in
            // A dir named after the CLIENT's own pid, empty — the trap.
            _ = try makeAppDir(root: root, pid: Int(getpid()), sockets: [])
            // The actual app's dir, different pid, holding the sockets.
            let appDir = try makeAppDir(root: root, pid: 424242, sockets: ["424242.sock", "latest.sock"])
            let resolved = DiagPaths.clientSocketPath(pid: nil, tmpRoot: root)
            #expect(resolved == "\(appDir)/latest.sock")
        }
    }

    @Test func pidTargetingFindsTheDirThatHoldsThatSocket() throws {
        try withTempRoot { root in
            _ = try makeAppDir(root: root, pid: 111, sockets: ["111.sock", "latest.sock"])
            let wanted = try makeAppDir(root: root, pid: 222, sockets: ["222.sock"])
            let resolved = DiagPaths.clientSocketPath(pid: 222, tmpRoot: root)
            #expect(resolved == "\(wanted)/222.sock")
        }
    }

    @Test func noRunningAppResolvesToNilNotAFabricatedPath() throws {
        try withTempRoot { root in
            _ = try makeAppDir(root: root, pid: Int(getpid()), sockets: [])
            #expect(DiagPaths.clientSocketPath(pid: nil, tmpRoot: root) == nil)
        }
    }

    @Test func remoteDirsEnumeratesEveryCheckoutDirForListAndReap() throws {
        try withTempRoot { root in
            let a = try makeAppDir(root: root, pid: 111, sockets: ["111.sock"])
            let b = try makeAppDir(root: root, pid: 222, sockets: ["222.sock"])
            let dirs = Set(DiagPaths.clientRemoteDirs(tmpRoot: root))
            #expect(dirs == Set([a, b]))
        }
    }
}
