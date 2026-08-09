import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Resolves filesystem paths for diagnostic output.
///
/// Layout:
/// ```
/// .terminalui/                              project-local config
///   terminalui.toml                         config file
///   data -> /tmp/terminalui-{hash}-{pid}/   symlink to most-recent ephemeral output
///
/// /tmp/terminalui-{hash}-{pid}/             ephemeral output, one dir per process
///   captures/
///   screenshots/
///   traces/
///   debug.sock
///   debug.jsonl
/// ```
///
/// `{hash}` is FNV-1a of the cwd — same for every instance launched
/// from this checkout. `{pid}` is the process's own PID — unique per
/// instance. Two processes from the same checkout never collide on
/// any path. The project-local `.terminalui/data` symlink points at
/// the most-recently booted instance's dir as a convenience for
/// `swtui ctl` no-arg invocations.
///
/// When `useTmp = false`, output goes directly under `.terminalui/` with no symlink.
public enum DiagPaths {

    // MARK: - Directory names

    private static let configDirName = ".terminalui"
    private static let configFileName = "terminalui.toml"
    private static let symlinkName = "data"
    private static let tmpPrefix = "terminalui-"

    // MARK: - Subdirectories inside the data root

    private static let subdirectories = ["captures", "screenshots", "traces", "remote"]

    // MARK: - Resolved paths

    /// The project-local config directory: `{cwd}/.terminalui/`
    public static var configDir: String {
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(configDirName)
    }

    /// The config file path: `{cwd}/.terminalui/terminalui.toml`
    public static var configFile: String {
        (configDir as NSString).appendingPathComponent(configFileName)
    }

    /// The symlink path: `{cwd}/.terminalui/data`
    public static var symlinkPath: String {
        (configDir as NSString).appendingPathComponent(symlinkName)
    }

    /// The ephemeral output directory in `/tmp/` for the calling process.
    /// `{hash}` is FNV-1a of the cwd (same across instances from this
    /// checkout); `{pid}` is the calling process's own PID — unique per
    /// instance. Concurrent runs from the same checkout never share a
    /// path, which is why `swtui ctl kill --pid <N>` is the only way to
    /// affect another instance.
    public static var tmpDataDir: String {
        let cwd = FileManager.default.currentDirectoryPath
        let hash = fnv1a(cwd)
        return "/tmp/\(tmpPrefix)\(hash)-\(getpid())"
    }

    /// Every `remote/` socket directory belonging to THIS checkout,
    /// newest first. The enumeration a client needs for `list` and `reap`.
    public static func clientRemoteDirs(tmpRoot: String = "/tmp") -> [String] {
        let prefix = "\(tmpPrefix)\(cwdHash)-"
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: tmpRoot)) ?? []
        let dirs = entries.compactMap { entry -> (path: String, modified: Date)? in
            guard entry.hasPrefix(prefix) else { return nil }
            let remote = "\(tmpRoot)/\(entry)/remote"
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: remote, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let attributes = try? fileManager.attributesOfItem(atPath: remote)
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            return (remote, modified)
        }
        return dirs.sorted { $0.modified > $1.modified }.map(\.path)
    }

    /// The socket path a CLIENT process (swtui ctl, scripts) should target.
    ///
    /// A client must never resolve through its own `tmpDataDir`: the PID in
    /// that path is the client's, and no app ever wrote there — `swtui ctl`
    /// doing exactly that is how every invocation failed while the Python
    /// harness client (which searches the checkout's dirs) kept passing.
    /// Searches every per-process dir for this checkout, newest first, and
    /// returns the first that actually holds the wanted socket file — or
    /// nil, so the caller reports "no running app" instead of a fabricated
    /// path. `TERMINALUI_DATA_DIR` still wins when set, mirroring
    /// `dataDir(useTmp:)`.
    public static func clientSocketPath(pid: Int32?, tmpRoot: String = "/tmp") -> String? {
        let filename = pid.map { "\($0).sock" } ?? "latest.sock"
        if let override = ProcessInfo.processInfo.environment[dataDirEnvVar],
           !override.isEmpty {
            return "\(override)/remote/\(filename)"
        }
        let fileManager = FileManager.default
        for dir in clientRemoteDirs(tmpRoot: tmpRoot) {
            let candidate = "\(dir)/\(filename)"
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// FNV-1a hash of the current cwd, exposed so callers can enumerate
    /// every per-process dir for THIS checkout regardless of PID.
    public static var cwdHash: String {
        fnv1a(FileManager.default.currentDirectoryPath)
    }

    /// Environment variable that, when set, overrides `dataDir(useTmp:)`
    /// to a caller-supplied path. Test-only escape hatch — the framework
    /// itself never sets this. Production processes leave it unset and
    /// fall through to the per-process `tmpDataDir`.
    public static let dataDirEnvVar = "TERMINALUI_DATA_DIR"

    /// The resolved data root — either the `TERMINALUI_DATA_DIR` env
    /// override, `/tmp/terminalui-{hash}-{pid}/`, or `.terminalui/`
    /// depending on config.
    public static func dataDir(useTmp: Bool) -> String {
        if let override = ProcessInfo.processInfo.environment[dataDirEnvVar],
           !override.isEmpty {
            return override
        }
        return useTmp ? tmpDataDir : configDir
    }

    // MARK: - Output paths

    public static func capturesDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("captures")
    }

    public static func screenshotsDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("screenshots")
    }

    public static func tracesDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("traces")
    }

    public static func socketPath(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("debug.sock")
    }

    /// Directory holding per-app remote-control sockets. Each running debug
    /// build creates `<pid>.sock` here and maintains a `latest.sock` symlink
    /// pointing to the newest one. Default resolver used by the
    /// remote-control server.
    public static func socketDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("remote")
    }

    public static func jsonlPath(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("debug.jsonl")
    }

    /// Path to the framework warnings log file. Append-only across the
    /// session — DebugStream writes here when a TerminalApp is live so
    /// stderr writes don't corrupt the rendered viewport.
    public static func warningsLogPath(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("warnings.log")
    }

    // MARK: - Directory setup

    /// Create all necessary directories and the symlink.
    public static func ensureDirectories(config: DiagConfig) {
        let fm = FileManager.default

        // Config dir always exists
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        let root = dataDir(useTmp: config.useTmp)

        // Create the data root and subdirectories
        for subdir in subdirectories {
            let path = (root as NSString).appendingPathComponent(subdir)
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        // Atomically point .terminalui/data at this process's per-PID
        // dir when using /tmp. Race-free: link/rename can't be observed
        // partially even when concurrent boots collide.
        if config.useTmp {
            try? updateDataSymlink()
        }
    }

    /// Remove every ephemeral output dir for this project — all
    /// `/tmp/terminalui-{cwd-hash}-*/` directories regardless of PID.
    /// Used by `swtui clean` for an explicit project-wide nuke.
    /// Does NOT distinguish live vs dead processes; for safe automated
    /// cleanup of stale-only state use `swtui ctl reap` instead.
    public static func clean() {
        let fm = FileManager.default

        // Remove every per-PID dir for this cwd. The prefix is stable
        // across instances; siblings are distinguished only by PID
        // suffix.
        let parent = "/tmp"
        let pidPrefix = "\(tmpPrefix)\(cwdHash)-"
        if let entries = try? fm.contentsOfDirectory(atPath: parent) {
            for entry in entries where entry.hasPrefix(pidPrefix) {
                try? fm.removeItem(atPath: (parent as NSString).appendingPathComponent(entry))
            }
        }

        // Remove symlink
        let link = symlinkPath
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
            try? fm.removeItem(atPath: link)
        }

        // Remove inline data subdirectories if they exist
        for subdir in subdirectories {
            let path = (configDir as NSString).appendingPathComponent(subdir)
            try? fm.removeItem(atPath: path)
        }
    }

    /// Remove the calling process's own `tmpDataDir` and unlink the
    /// project-local `.terminalui/data` symlink **if** it points at
    /// our dir. Called from the runtime's atexit hook so a clean exit
    /// doesn't leak per-PID state. Crashes leave the dir for the next
    /// `swtui ctl reap` to handle — orphan dirs are recoverable; live
    /// ones are not, so this method intentionally never touches a dir
    /// it doesn't own.
    public static func cleanupOwnDir() {
        let fm = FileManager.default
        let own = tmpDataDir
        try? fm.removeItem(atPath: own)
        // Only unlink the symlink if it still points at our dir — a
        // newer instance may have repointed it.
        let link = symlinkPath
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link), dest == own {
            try? fm.removeItem(atPath: link)
        }
    }

    /// Atomically point `.terminalui/data` at this process's
    /// `tmpDataDir`. Race-free across concurrent boots: writes a
    /// uniquely-named temporary symlink, then `rename(2)`s it over
    /// the canonical path. Per POSIX `rename(2)`, the swap is atomic
    /// — at no point does a reader see a missing or partially-updated
    /// link. Idempotent: repeated calls converge on the same target.
    public static func updateDataSymlink() throws {
        let fm = FileManager.default
        let target = tmpDataDir
        // Ensure the parent (.terminalui/) exists; `swtui status` may
        // call this before `ensureDirectories` has run.
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        let link = symlinkPath
        // Build a temp link name in the same dir so `rename(2)` is on
        // the same filesystem (cross-fs rename returns EXDEV).
        let tmpLink = "\(link).tmp.\(getpid()).\(arc4random())"
        // Best-effort cleanup of any prior tmp link from a crashed run.
        try? fm.removeItem(atPath: tmpLink)
        try fm.createSymbolicLink(atPath: tmpLink, withDestinationPath: target)

        // POSIX rename(2): atomic replace if dst exists. Wraps the
        // remove+create-with-the-name-already-taken race seen on the
        // old `removeItem + createSymbolicLink` path.
        let result = rename(tmpLink, link)
        if result != 0 {
            // Best-effort tmp cleanup before surfacing the error.
            try? fm.removeItem(atPath: tmpLink)
            throw SymlinkUpdateError.renameFailed(errno: errno)
        }
    }

    /// Errors thrown by `updateDataSymlink`. Currently only the
    /// rename(2) failure path; create(2) failures bubble out as
    /// `Foundation.CocoaError`.
    public enum SymlinkUpdateError: Error, Equatable {
        case renameFailed(errno: Int32)
    }

    // MARK: - Config file I/O

    /// Load the config from `.terminalui/terminalui.toml`, or return defaults.
    public static func loadConfig() -> DiagConfig {
        let path = configFile
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .default
        }
        let sections = TOMLParser.parse(contents)
        return DiagConfig(from: sections)
    }

    /// Write config to `.terminalui/terminalui.toml`.
    /// Creates the config directory if needed.
    public static func saveConfig(_ config: DiagConfig) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        let sections = config.toSections()
        let toml = TOMLParser.write(sections)
        try? toml.write(toFile: configFile, atomically: true, encoding: .utf8)
    }

    /// Read raw TOML sections, update a single key, write back.
    /// Preserves existing values that aren't being changed.
    public static func updateConfigValue(section: String, key: String, value: String) {
        let path = configFile
        var sections: [String: [String: String]]

        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            sections = TOMLParser.parse(contents)
        } else {
            // Start from default config sections
            sections = DiagConfig.default.toSections()
        }

        if sections[section] == nil {
            sections[section] = [:]
        }
        sections[section]?[key] = value

        let fm = FileManager.default
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        let toml = TOMLParser.write(sections)
        try? toml.write(toFile: configFile, atomically: true, encoding: .utf8)
    }

    // MARK: - FNV-1a hash

    /// FNV-1a 32-bit hash — simple, deterministic, no dependencies.
    private static func fnv1a(_ string: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return String(hash, radix: 16)
    }
}
