import Foundation

/// Resolves filesystem paths for diagnostic output.
///
/// Layout:
/// ```
/// .terminalui/                        project-local config
///   terminalui.toml                   config file
///   data -> /tmp/terminalui-{hash}/   symlink to ephemeral output
///
/// /tmp/terminalui-{hash}/             ephemeral output (hash of cwd)
///   captures/
///   screenshots/
///   traces/
///   debug.sock
///   debug.jsonl
/// ```
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

    /// The ephemeral output directory in `/tmp/`.
    /// Hash is FNV-1a of the current working directory for per-project isolation.
    public static var tmpDataDir: String {
        let cwd = FileManager.default.currentDirectoryPath
        let hash = fnv1a(cwd)
        return "/tmp/\(tmpPrefix)\(hash)"
    }

    /// The resolved data root — either `/tmp/terminalui-{hash}/` or `.terminalui/`
    /// depending on config.
    public static func dataDir(useTmp: Bool) -> String {
        useTmp ? tmpDataDir : configDir
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

        // Set up symlink when using /tmp/
        if config.useTmp {
            let link = symlinkPath
            // Remove stale symlink or file at the link path
            if fm.fileExists(atPath: link) || (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
                try? fm.removeItem(atPath: link)
            }
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: root)
        }
    }

    /// Remove all ephemeral output for this project.
    public static func clean() {
        let fm = FileManager.default

        // Remove /tmp/ data
        try? fm.removeItem(atPath: tmpDataDir)

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
