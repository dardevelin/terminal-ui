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
// transient pid}/remote/` and failed, while the Python client
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

    @Test func pidTargetingFindsTheDirThatHoldsThatSocket() throws {
        try withTempRoot { root in
            let pid = Int(getpid())
            _ = try makeAppDir(root: root, pid: 99_999_998, sockets: ["99999998.sock"])
            let wanted = try makeAppDir(root: root, pid: pid, sockets: ["\(pid).sock"])
            let resolved = DiagPaths.clientSocketPath(pid: Int32(pid), tmpRoot: root)
            #expect(resolved == "\(wanted)/\(pid).sock")
        }
    }

    @Test func remoteDirsEnumeratesEveryCheckoutDirForListAndReap() throws {
        try withTempRoot { root in
            let a = try makeAppDir(root: root, pid: 111, sockets: ["111.sock"])
            let b = try makeAppDir(root: root, pid: 222, sockets: ["222.sock"])
            let dirs = Set(DiagPaths.clientRemoteDirs(tmpRoot: root, inlineDataDir: "\(root)/inline"))
            #expect(dirs == Set([a, b]))
        }
    }

    // Each app is addressed by its own id. A client that names none reaches
    // the one app running from this checkout — never "the most recent", so
    // an app the harness starts cannot take over the developer's session,
    // and cannot leave nothing to talk to when it exits.

    /// Live pids for tests: this process and the one that started it.
    private let selfPID = Int(getpid())
    private let parentPID = Int(getppid())
    /// Beyond any `pid_max`, so `kill(pid, 0)` reports no such process.
    private let deadPID = 99_999_999

    /// An inline data dir — what `useTmp = false` apps share — that holds
    /// nothing, so tests see only the apps they make.
    private func emptyInlineDir(_ root: String) -> String { "\(root)/inline" }

    private func setModified(_ dir: String, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)], ofItemAtPath: dir)
    }

    @Test func runningAppsAreTheLiveOnesWithASocketNewestFirst() throws {
        try withTempRoot { root in
            let olderDir = try makeAppDir(root: root, pid: selfPID, sockets: ["\(selfPID).sock"])
            let newerDir = try makeAppDir(root: root, pid: parentPID, sockets: ["\(parentPID).sock"])
            try setModified(olderDir, secondsAgo: 60)
            try setModified(newerDir, secondsAgo: 1)
            _ = try makeAppDir(root: root, pid: deadPID, sockets: ["\(deadPID).sock"])
            _ = try makeAppDir(root: root, pid: selfPID + 1_000_000, sockets: [])

            let apps = DiagPaths.runningApps(tmpRoot: root, inlineDataDir: emptyInlineDir(root))
            #expect(apps.map(\.pid) == [Int32(parentPID), Int32(selfPID)])
            #expect(apps.first?.socketPath == "\(newerDir)/\(parentPID).sock")
        }
    }

    @Test func anAppIsNamedByWhatItRecorded() throws {
        try withTempRoot { root in
            let remote = try makeAppDir(root: root, pid: selfPID, sockets: ["\(selfPID).sock"])
            try DiagPaths.recordAppName("Coder", inDataDir: (remote as NSString).deletingLastPathComponent)
            #expect(DiagPaths.runningApps(tmpRoot: root, inlineDataDir: emptyInlineDir(root)).first?.name == "Coder")
        }
    }

    @Test func anAppWritingInlineIsRunningToo() throws {
        try withTempRoot { root in
            let inline = "\(root)/project/.terminalui"
            try FileManager.default.createDirectory(atPath: "\(inline)/remote", withIntermediateDirectories: true)
            #expect(FileManager.default.createFile(atPath: "\(inline)/remote/\(selfPID).sock", contents: Data()))
            let apps = DiagPaths.runningApps(tmpRoot: root, inlineDataDir: inline)
            #expect(apps.map(\.pid) == [Int32(selfPID)])
            #expect(apps.first?.ownsDataDir == false, "the inline dir is shared")
        }
    }

    @Test func aRemoteDirIsReadForTheSocketsOfApps() throws {
        try withTempRoot { root in
            let remote = try makeAppDir(root: root, pid: selfPID, sockets: ["\(selfPID).sock", "latest.sock"])
            #expect(DiagPaths.socket(inRemoteDir: remote, pid: nil) == "\(remote)/\(selfPID).sock",
                    "a pre-1.1 latest.sock link is not a second app")
            #expect(DiagPaths.socket(inRemoteDir: remote, pid: Int32(deadPID)) == nil)
        }
    }

    // A crash, or SIGKILL, leaves an app's output behind; `reap` removes it,
    // and never a live app's.

    @Test func reapRemovesWhatDeadAppsLeft() throws {
        try withTempRoot { root in
            let fm = FileManager.default
            let live = (try makeAppDir(root: root, pid: selfPID, sockets: ["\(selfPID).sock"]) as NSString)
                .deletingLastPathComponent
            let dead = (try makeAppDir(root: root, pid: deadPID, sockets: ["\(deadPID).sock"]) as NSString)
                .deletingLastPathComponent

            let reaped = DiagPaths.removeDeadApps(tmpRoot: root, inlineDataDir: emptyInlineDir(root))
            #expect(reaped.map(\.pid) == [Int32(deadPID)])
            #expect(!fm.fileExists(atPath: dead))
            #expect(fm.fileExists(atPath: live))
        }
    }

    @Test func cleanLeavesTheDirsOfRunningApps() throws {
        try withTempRoot { root in
            let fm = FileManager.default
            let live = (try makeAppDir(root: root, pid: selfPID, sockets: []) as NSString).deletingLastPathComponent
            let dead = (try makeAppDir(root: root, pid: deadPID, sockets: []) as NSString).deletingLastPathComponent

            #expect(DiagPaths.clean(tmpRoot: root, inlineDataDir: emptyInlineDir(root)) == [Int32(selfPID)])
            #expect(fm.fileExists(atPath: live), "clean removed a running app's dir")
            #expect(!fm.fileExists(atPath: dead))
        }
    }
}
