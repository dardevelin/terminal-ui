import Foundation
import Testing
@testable import TerminalUIConfig

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Per-process data-dir isolation. Two `swift run Storybook` instances
// from the same checkout must never collide on socket / screenshot /
// trace paths — the canonical `/tmp/terminalui-{cwd-hash}/` shared
// directory is the bug that lets Claude's verify hook send `quit` to
// the user's live session by mistake. Embedding the calling PID in
// the path makes identity structural: two processes literally cannot
// resolve the same path.
//
// `TERMINALUI_DATA_DIR` env override still wins when set — tests use
// it for pinning, the framework leaves it unset in production.
//
// `cleanupOwnDir()` is the runtime atexit hook: it removes only the
// calling process's tmpDataDir, never a sibling. `clean()` (used by
// `swtui clean`) wipes every `terminalui-{cwd-hash}-*` dir for the
// current cwd — explicit project-wide nuke, not per-process cleanup.

// `.serialized` because every test mutates `TERMINALUI_DATA_DIR` /
// creates and removes `/tmp/terminalui-*-*` dirs. setenv / unsetenv
// is process-global, and Swift Testing runs cases in parallel by
// default — without serialization the override-priority test races
// against `withEnv(nil)` from the PID tests and observes nil instead
// of the expected override.
@Suite("DiagPaths — per-process tmpDataDir isolation", .serialized)
struct DiagPathsConcurrencyTests {

    // MARK: - Helpers

    private static func currentPID() -> Int {
        Int(getpid())
    }

    /// Set + restore an env var around a closure so concurrent tests
    /// don't see each other's overrides bleed across.
    private static func withEnv(_ key: String, _ value: String?, _ body: () throws -> Void) rethrows {
        let prior = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let prior {
                setenv(key, prior, 1)
            } else {
                unsetenv(key)
            }
        }
        try body()
    }

    // MARK: - PID embedding

    @Test("tmpDataDir embeds the calling process's PID")
    func tmpDataDirEmbedsCurrentPID() {
        Self.withEnv(DiagPaths.dataDirEnvVar, nil) {
            let path = DiagPaths.tmpDataDir
            let pidSuffix = "-\(Self.currentPID())"
            #expect(path.hasSuffix(pidSuffix),
                    "tmpDataDir must end with '-<pid>' so concurrent processes resolve to distinct paths; got \(path)")
        }
    }

    @Test("tmpDataDir is stable across calls within the same PID")
    func tmpDataDirCwdHashStable() {
        Self.withEnv(DiagPaths.dataDirEnvVar, nil) {
            let first = DiagPaths.tmpDataDir
            let second = DiagPaths.tmpDataDir
            #expect(first == second,
                    "tmpDataDir must be deterministic within a process — got \(first) then \(second)")
        }
    }

    // MARK: - Env override priority

    @Test("TERMINALUI_DATA_DIR override wins over PID-embedded default")
    func envOverrideStillWins() {
        Self.withEnv(DiagPaths.dataDirEnvVar, "/tmp/terminalui-test-override-only") {
            let resolved = DiagPaths.dataDir(useTmp: true)
            #expect(resolved == "/tmp/terminalui-test-override-only",
                    "env override must win even when PID embedding would produce a different path; got \(resolved)")
        }
    }

    // MARK: - cleanupOwnDir

    @Test("cleanupOwnDir removes only the calling process's dir")
    func cleanupOwnDirRemovesOnlyOwnDir() throws {
        try Self.withEnv(DiagPaths.dataDirEnvVar, nil) {
            let fm = FileManager.default
            let ownDir = DiagPaths.tmpDataDir

            // Build a sibling dir that "belongs" to a hypothetical other
            // PID (PID space is large; 99999999 is essentially never live
            // in CI but we still verify it survives).
            let siblingDir = ownDir
                .replacingOccurrences(
                    of: "-\(Self.currentPID())",
                    with: "-99999999")

            #expect(siblingDir != ownDir, "synthetic sibling must differ from ownDir; got \(siblingDir)")

            try fm.createDirectory(atPath: ownDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: siblingDir, withIntermediateDirectories: true)

            // Marker file rather than the directory itself. `ownDir` is
            // process-global, so anything in the suite that touches
            // diagnostics can recreate it between the call and the assertion
            // — the directory's existence is not a fact this test controls.
            // Whether *its own contents* were removed is.
            let marker = (ownDir as NSString).appendingPathComponent("marker")
            #expect(fm.createFile(atPath: marker, contents: Data()))

            DiagPaths.cleanupOwnDir()

            #expect(!fm.fileExists(atPath: marker),
                    "cleanupOwnDir must remove the calling process's dir; \(ownDir) survived")
            #expect(fm.fileExists(atPath: siblingDir),
                    "cleanupOwnDir must NOT remove sibling dirs from other PIDs; \(siblingDir) was deleted")

            // Test cleanup
            try? fm.removeItem(atPath: siblingDir)
        }
    }

    // MARK: - clean (project-wide)

    @Test("clean removes every terminalui-{cwd-hash}-* dir for this cwd")
    func cleanForProjectRemovesAllPidDirs() throws {
        try Self.withEnv(DiagPaths.dataDirEnvVar, nil) {
            let fm = FileManager.default

            // Two synthetic sibling dirs standing in for other processes,
            // rather than this process's own `tmpDataDir`. The live dir is
            // process-global: anything else in the suite that touches
            // diagnostics between `clean()` and the assertion recreates it,
            // and the test fails for a reason that has nothing to do with
            // `clean`. Asserting on dirs this test alone owns measures the
            // same contract — every entry carrying this cwd's prefix is
            // removed — without racing the runtime for the live path.
            let ownDir = DiagPaths.tmpDataDir
            let siblings = ["-99999998", "-99999997"].map {
                ownDir.replacingOccurrences(of: "-\(Self.currentPID())", with: $0)
            }
            #expect(siblings.allSatisfy { $0 != ownDir },
                    "synthetic siblings must differ from the live dir")

            for dir in siblings {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            defer { for dir in siblings { try? fm.removeItem(atPath: dir) } }

            DiagPaths.clean()

            for dir in siblings {
                #expect(!fm.fileExists(atPath: dir),
                        "clean is project-wide: every terminalui-{hash}-* dir for this cwd must go; \(dir) survived")
            }
        }
    }

    // MARK: - updateDataSymlink

    @Test("updateDataSymlink resolves to the calling process's tmpDataDir")
    func updateDataSymlinkPointsAtOwnDir() throws {
        try Self.withEnv(DiagPaths.dataDirEnvVar, nil) {
            let fm = FileManager.default
            let ownDir = DiagPaths.tmpDataDir
            try fm.createDirectory(atPath: ownDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: ownDir) }

            // Project-local config dir — needed so the symlink can be created.
            try? fm.createDirectory(atPath: DiagPaths.configDir, withIntermediateDirectories: true)

            // Pre-poison: place a stale symlink pointing at a bogus dir.
            let link = DiagPaths.symlinkPath
            try? fm.removeItem(atPath: link)
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: "/tmp/terminalui-stale-from-prior-run")

            try DiagPaths.updateDataSymlink()

            let resolved = try fm.destinationOfSymbolicLink(atPath: link)
            #expect(resolved == ownDir,
                    "updateDataSymlink must repoint .terminalui/data at this PID's dir; resolved=\(resolved)")

            // Idempotent — call again, still points at ownDir.
            try DiagPaths.updateDataSymlink()
            let resolvedAgain = try fm.destinationOfSymbolicLink(atPath: link)
            #expect(resolvedAgain == ownDir,
                    "updateDataSymlink must be idempotent; got \(resolvedAgain) on second call")
        }
    }
}
