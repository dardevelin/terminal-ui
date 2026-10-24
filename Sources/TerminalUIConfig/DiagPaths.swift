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
/// any path. Nothing names "the" app, since several may run at once — a
/// developer's and those a test harness started: `swtui status` lists each
/// app's dir, and a client names the app it wants by pid.
///
/// When `useTmp = false`, output goes directly under `.terminalui/` with no symlink.
public enum DiagPaths {

    // MARK: - Directory names

    private static let configDirName = ".terminalui"
    private static let configFileName = "terminalui.toml"
    private static let symlinkName = "data"
    private static let remoteDirName = "remote"
    private static let appNameFileName = "app-name"
    private static let tmpPrefix = "terminalui-"

    // MARK: - Subdirectories inside the data root

    private static let subdirectories = ["captures", "screenshots", "traces", remoteDirName]

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

    /// `{cwd}/.terminalui/data`, the single link builds before 1.1 pointed
    /// at the most recently started app. `swtui clean` removes it.
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
        dataDir(forPID: getpid())
    }

    /// `{tmpRoot}/terminalui-{hash}-{pid}`: where the app with `pid`, started
    /// from this checkout, keeps its output.
    public static func dataDir(forPID pid: Int32, tmpRoot: String = "/tmp") -> String {
        "\(tmpRoot)/\(tmpPrefix)\(cwdHash)-\(pid)"
    }

    /// The pid at the end of a per-process dir's name, `terminalui-{hash}-{pid}`.
    private static func pid(ofDataDirNamed name: String) -> Int32? {
        Int32(name.split(separator: "-").last ?? "")
    }

    /// Every `remote/` socket directory belonging to THIS checkout,
    /// newest first. The enumeration a client needs for `list` and `reap`.
    public static func clientRemoteDirs(tmpRoot: String = "/tmp", inlineDataDir: String = configDir) -> [String] {
        var seen = Set<String>()
        return debugApps(tmpRoot: tmpRoot, inlineDataDir: inlineDataDir).map(\.remoteDir)
            .filter { seen.insert($0).inserted }
    }

    /// The socket path a CLIENT process (swtui ctl, scripts) should target.
    ///
    /// A client must never resolve through its own `tmpDataDir`: the PID in
    /// that path is the client's, and no app ever wrote there — `swtui ctl`
    /// doing exactly that is how every invocation failed while the Python
    /// harness client (which searches the checkout's dirs) kept passing.
    /// With a `pid`, that app's socket; without one, the socket of the one
    /// app running — nil when there is none or several, so the caller
    /// reports that instead of a fabricated path. `TERMINALUI_DATA_DIR` still
    /// wins when set, mirroring `dataDir(useTmp:)`.
    public static func clientSocketPath(pid: Int32?, tmpRoot: String = "/tmp") -> String? {
        if let override = ProcessInfo.processInfo.environment[dataDirEnvVar], !override.isEmpty {
            return socket(inRemoteDir: (override as NSString).appendingPathComponent(remoteDirName), pid: pid)
        }
        guard let pid else {
            let apps = runningApps(tmpRoot: tmpRoot)
            return apps.count == 1 ? apps[0].socketPath : nil
        }
        return debugApps(tmpRoot: tmpRoot).first { $0.pid == pid && $0.isRunning }?.socketPath
    }

    /// The control socket in an app's `remote/` dir: `{pid}.sock`, or — with
    /// no pid named — the one socket there.
    public static func socket(inRemoteDir remoteDir: String, pid: Int32?) -> String? {
        if let pid {
            let path = (remoteDir as NSString).appendingPathComponent(socketName(pid: pid))
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        let sockets = self.sockets(inRemoteDir: remoteDir)
        return sockets.count == 1 ? sockets[0].path : nil
    }

    /// Every app's control socket in a `remote/` dir, by pid. Names that carry
    /// no pid, such as the `latest.sock` link builds before 1.1 published,
    /// are not an app's.
    public static func sockets(inRemoteDir remoteDir: String) -> [(pid: Int32, path: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: remoteDir)) ?? []
        return names.sorted().compactMap { name in
            pid(ofSocketNamed: name).map { ($0, (remoteDir as NSString).appendingPathComponent(name)) }
        }
    }

    /// The pid in a control socket's name, `{pid}.sock`.
    public static func pid(ofSocketNamed name: String) -> Int32? {
        guard name.hasSuffix(".sock") else { return nil }
        return Int32(name.dropLast(".sock".count))
    }

    private static func socketName(pid: Int32) -> String {
        "\(pid).sock"
    }

    /// A debug app started from this checkout, whatever has become of its
    /// process since.
    public struct DebugApp: Equatable, Sendable {
        public let pid: Int32
        /// Where it writes its output: its own `terminalui-{hash}-{pid}` dir,
        /// or — with `useTmp = false` — `.terminalui/`, shared with the
        /// checkout's other such apps.
        public let dataDir: String

        public var remoteDir: String {
            (dataDir as NSString).appendingPathComponent(DiagPaths.remoteDirName)
        }

        public var socketPath: String {
            (remoteDir as NSString).appendingPathComponent(socketName(pid: pid))
        }

        /// Whether `dataDir` is the app's alone, to remove with it.
        public var ownsDataDir: Bool {
            (dataDir as NSString).lastPathComponent.hasPrefix(DiagPaths.tmpPrefix)
        }

        /// What the app recorded as its name — its executable — or nil for an
        /// app that predates recording it, or shares its data dir.
        public var name: String? {
            ownsDataDir ? recordedAppName(inDataDir: dataDir) : nil
        }

        /// Its process is alive and its control socket is there.
        public var isRunning: Bool {
            isAlive(pid) && FileManager.default.fileExists(atPath: socketPath)
        }
    }

    /// Every debug app started from this checkout, newest first: one per
    /// per-process dir under `tmpRoot`, and one per socket in the shared
    /// `inlineDataDir` that apps with `useTmp = false` write to.
    public static func debugApps(tmpRoot: String = "/tmp", inlineDataDir: String = configDir) -> [DebugApp] {
        let fileManager = FileManager.default
        let prefix = "\(tmpPrefix)\(cwdHash)-"
        let perProcess = ((try? fileManager.contentsOfDirectory(atPath: tmpRoot)) ?? []).compactMap { entry -> DebugApp? in
            guard entry.hasPrefix(prefix), let pid = pid(ofDataDirNamed: entry) else { return nil }
            return DebugApp(pid: pid, dataDir: (tmpRoot as NSString).appendingPathComponent(entry))
        }
        let inline = sockets(inRemoteDir: (inlineDataDir as NSString).appendingPathComponent(remoteDirName))
            .map { DebugApp(pid: $0.pid, dataDir: inlineDataDir) }
        func modified(_ app: DebugApp) -> Date {
            let attributes = try? fileManager.attributesOfItem(atPath: app.ownsDataDir ? app.remoteDir : app.socketPath)
            return attributes?[.modificationDate] as? Date ?? .distantPast
        }
        return (perProcess + inline)
            .map { (app: $0, modified: modified($0)) }
            .sorted { $0.modified > $1.modified }
            .map(\.app)
    }

    /// Every debug app running from this checkout, newest first.
    public static func runningApps(tmpRoot: String = "/tmp", inlineDataDir: String = configDir) -> [DebugApp] {
        debugApps(tmpRoot: tmpRoot, inlineDataDir: inlineDataDir).filter(\.isRunning)
    }

    /// Remove what every app from this checkout whose process has ended left
    /// behind — its own data dir, or its socket in a shared one. A crash, or
    /// SIGKILL, leaves these. Returns the apps removed.
    @discardableResult
    public static func removeDeadApps(tmpRoot: String = "/tmp", inlineDataDir: String = configDir) -> [DebugApp] {
        debugApps(tmpRoot: tmpRoot, inlineDataDir: inlineDataDir).filter { app in
            guard !isAlive(app.pid) else { return false }
            let path = app.ownsDataDir ? app.dataDir : app.socketPath
            return (try? FileManager.default.removeItem(atPath: path)) != nil
        }
    }

    /// Records the calling app's name in its data dir, for clients that list
    /// running apps.
    public static func recordAppName(_ name: String, inDataDir dataDir: String) throws {
        try name.write(toFile: appNamePath(inDataDir: dataDir), atomically: true, encoding: .utf8)
    }

    /// The name an app recorded in its data dir, if it did.
    public static func recordedAppName(inDataDir dataDir: String) -> String? {
        try? String(contentsOfFile: appNamePath(inDataDir: dataDir), encoding: .utf8)
    }

    private static func appNamePath(inDataDir dataDir: String) -> String {
        (dataDir as NSString).appendingPathComponent(appNameFileName)
    }

    /// Whether `pid` names a live process. EPERM means it exists but belongs
    /// to someone else.
    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
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

    /// Directory for on-demand frame captures: `{dataDir}/captures`.
    public static func capturesDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("captures")
    }

    /// Directory for per-frame trace screenshots: `{dataDir}/screenshots`.
    public static func screenshotsDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("screenshots")
    }

    /// Directory for per-frame trace logs: `{dataDir}/traces`.
    public static func tracesDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("traces")
    }

    /// Path of the debug event-stream socket: `{dataDir}/debug.sock`.
    /// Distinct from the remote-control sockets under `socketDir(useTmp:)`.
    public static func socketPath(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("debug.sock")
    }

    /// Directory holding the app's remote-control socket, `<pid>.sock`.
    /// Default resolver used by the remote-control server.
    public static func socketDir(useTmp: Bool) -> String {
        (dataDir(useTmp: useTmp) as NSString).appendingPathComponent("remote")
    }

    /// Path of the JSON-lines debug event log: `{dataDir}/debug.jsonl`.
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

    /// Create the data dirs and record the app's name in them.
    public static func ensureDirectories(config: DiagConfig) {
        prepareDataDirectories(config: config)
    }

    /// Create the data dirs and record the app's name in them; false when
    /// the `/tmp` data dir is not this process's owner's alone, and nothing
    /// may be written there.
    ///
    /// The dir holds the frames a debug build traces — every key typed in
    /// them — its screenshots and its control socket, under a name any
    /// local user can predict. So it is created readable by its owner
    /// alone, and one already there is used only if it is a directory that
    /// owner made private: another user's, or a link to somewhere else, is
    /// refused rather than written into.
    @discardableResult
    public static func prepareDataDirectories(config: DiagConfig) -> Bool {
        let fm = FileManager.default

        // Config dir always exists
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        let root = dataDir(useTmp: config.useTmp)
        if root == tmpDataDir, !ensurePrivateDirectory(atPath: root) {
            return false
        }

        // Create the data root and subdirectories
        for subdir in subdirectories {
            let path = (root as NSString).appendingPathComponent(subdir)
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        if root == tmpDataDir {
            try? recordAppName(ProcessInfo.processInfo.processName, inDataDir: root)
        }
        return true
    }

    /// Whether `path` is a directory only its owner can enter, owned by
    /// this process's user, creating it so when nothing is there. A link
    /// is refused, not followed.
    public static func ensurePrivateDirectory(atPath path: String) -> Bool {
        if mkdir(path, Permission.ownerOnly) == 0 { return true }
        guard errno == EEXIST else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == geteuid()
            && info.st_mode & Permission.groupAndOthers == 0
    }

    /// POSIX permission bits (`<sys/stat.h>`).
    private enum Permission {
        /// rwx for the owner, nothing for anyone else.
        static let ownerOnly: mode_t = 0o700
        /// Every bit that grants the group or others anything.
        static let groupAndOthers: mode_t = 0o077
    }

    /// Remove the output of every app from this project that is no longer
    /// running — but never that of a live process, whose socket and output a
    /// running session still uses — and the pre-1.1 `.terminalui/data` link.
    /// Used by `swtui clean`. Returns the pids it left alone.
    @discardableResult
    public static func clean(tmpRoot: String = "/tmp", inlineDataDir: String = configDir) -> [Int32] {
        let fm = FileManager.default
        removeDeadApps(tmpRoot: tmpRoot, inlineDataDir: inlineDataDir)
        if (try? fm.destinationOfSymbolicLink(atPath: symlinkPath)) != nil {
            try? fm.removeItem(atPath: symlinkPath)
        }
        let live = debugApps(tmpRoot: tmpRoot, inlineDataDir: inlineDataDir)
        // Output written inline — `useTmp = false` — is shared; it goes only
        // when no app is left to use it.
        if !live.contains(where: { !$0.ownsDataDir }) {
            for subdir in subdirectories {
                try? fm.removeItem(atPath: (inlineDataDir as NSString).appendingPathComponent(subdir))
            }
        }
        return live.map(\.pid)
    }

    /// Remove the calling process's own `tmpDataDir`. Called when the runtime
    /// exits — normally, or on a terminating signal, which it turns into a
    /// quit — so a clean exit doesn't leak per-PID state. Crashes leave the
    /// dir for the next `swtui ctl reap` — orphan dirs are recoverable; live
    /// ones are not, so this method intentionally never touches a dir it
    /// doesn't own.
    public static func cleanupOwnDir() {
        try? FileManager.default.removeItem(atPath: tmpDataDir)
    }

    /// Atomically point `.terminalui/data` at this process's
    /// `tmpDataDir`. Race-free across concurrent boots: writes a
    /// uniquely-named temporary symlink, then `rename(2)`s it over
    /// the canonical path. Per POSIX `rename(2)`, the swap is atomic
    /// — at no point does a reader see a missing or partially-updated
    /// link. Idempotent: repeated calls converge on the same target.
    @available(*, deprecated, message: "No single link names the app: several may run at once. DiagPaths.runningApps() lists them.")
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
