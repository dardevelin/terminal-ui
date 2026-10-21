import Foundation

/// Unified diagnostic configuration for TerminalUI.
/// Read from `.terminalui/terminalui.toml` at startup, writable by the `swtui` CLI.
///
/// The single source of truth for the debug-only diagnostic system: a
/// debug-build app loads it via `DiagPaths.loadConfig()` at startup and
/// wires each feature accordingly — `traceEnabled` drives the DevTracer,
/// `socketEnabled` the remote-control socket, `useTmp` whether output
/// lands in the per-process `/tmp/terminalui-{hash}-{pid}/` dir or inline
/// under `.terminalui/`. Harness
/// authors normally edit the file with `swtui enable/disable/set` rather
/// than constructing this type; property names below map 1:1 onto the
/// TOML `[section] key` pairs noted in the MARK headers.
public struct DiagConfig: Sendable {

    // MARK: - [trace]

    /// `[trace] enabled` — master switch for per-frame trace capture (DevTracer).
    public var traceEnabled: Bool
    /// `[trace] screenshots` — write a plain-text + ANSI screenshot per traced frame.
    public var captureScreenshots: Bool
    /// `[trace] events` — record input events in the trace.
    public var captureEvents: Bool
    /// `[trace] frame_limit` — stop tracing after N frames; nil is unlimited.
    public var frameLimit: Int?

    // MARK: - [capture]

    /// `[capture] enabled` — the on-demand frame-capture feature.
    public var captureEnabled: Bool

    // MARK: - [output]

    /// `[output] use_tmp` — true routes output to the per-process
    /// `/tmp` dir, listed by `swtui status`; false writes inline under
    /// `.terminalui/`.
    public var useTmp: Bool

    // MARK: - [socket]

    /// `[socket] enabled` — expose the remote-control socket `swtui ctl` talks to.
    public var socketEnabled: Bool

    // MARK: - [keybindings]

    /// Action name → key string. E.g. "toggle_debug_overlay" → "F1", "toggle_debug_panel" → "ctrl+F2"
    public var keybindings: [String: String]

    // MARK: - Memberwise init

    /// Memberwise initializer for programmatic configs (tests, harnesses);
    /// apps normally load from disk via `DiagPaths.loadConfig()` instead.
    public init(
        traceEnabled: Bool,
        captureScreenshots: Bool,
        captureEvents: Bool,
        frameLimit: Int?,
        captureEnabled: Bool,
        useTmp: Bool,
        socketEnabled: Bool,
        keybindings: [String: String] = DiagConfig.defaultKeybindings
    ) {
        self.traceEnabled = traceEnabled
        self.captureScreenshots = captureScreenshots
        self.captureEvents = captureEvents
        self.frameLimit = frameLimit
        self.captureEnabled = captureEnabled
        self.useTmp = useTmp
        self.socketEnabled = socketEnabled
        self.keybindings = keybindings
    }

    /// F-keys don't collide with standard terminal shortcuts (Ctrl+D=EOF, Ctrl+F=search, etc.)
    public static let defaultKeybindings: [String: String] = [
        "toggle_debug_overlay": "F1",
        "toggle_debug_panel": "F2",
        "toggle_inspector": "F3",
    ]

    /// All recognized keybinding action names. capture_frame is available but unbound by default.
    public static let keybindingActions = [
        "toggle_debug_overlay", "toggle_debug_panel", "toggle_inspector", "capture_frame",
    ]

    // MARK: - Defaults

    /// Baseline when no config file exists: everything off except the
    /// remote-control socket, output routed through `/tmp`.
    public static let `default` = DiagConfig(
        traceEnabled: false,
        captureScreenshots: true,
        captureEvents: true,
        frameLimit: nil,
        captureEnabled: false,
        useTmp: true,
        socketEnabled: true
    )

    /// Default config for DEBUG builds — trace on with a frame cap.
    public static let debug = DiagConfig(
        traceEnabled: true,
        captureScreenshots: true,
        captureEvents: true,
        frameLimit: 100,
        captureEnabled: false,
        useTmp: true,
        socketEnabled: true
    )

    // MARK: - TOML round-trip

    /// Construct from parsed TOML sections.
    public init(from sections: [String: [String: String]]) {
        let trace = sections["trace"] ?? [:]
        let capture = sections["capture"] ?? [:]
        let output = sections["output"] ?? [:]
        let socket = sections["socket"] ?? [:]

        self.traceEnabled = Self.parseBool(trace["enabled"]) ?? DiagConfig.default.traceEnabled
        self.captureScreenshots = Self.parseBool(trace["screenshots"]) ?? DiagConfig.default.captureScreenshots
        self.captureEvents = Self.parseBool(trace["events"]) ?? DiagConfig.default.captureEvents
        self.frameLimit = Self.parseInt(trace["frame_limit"]) ?? DiagConfig.default.frameLimit

        self.captureEnabled = Self.parseBool(capture["enabled"]) ?? DiagConfig.default.captureEnabled

        self.useTmp = Self.parseBool(output["use_tmp"]) ?? DiagConfig.default.useTmp

        self.socketEnabled = Self.parseBool(socket["enabled"]) ?? DiagConfig.default.socketEnabled

        // Keybindings: start from defaults, override with file values
        var bindings = DiagConfig.defaultKeybindings
        if let fileBindings = sections["keybindings"] {
            for (action, key) in fileBindings {
                bindings[action] = key
            }
        }
        self.keybindings = bindings
    }

    /// Serialize to TOML sections for writing.
    public func toSections() -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]

        sections["trace"] = [
            "enabled": String(traceEnabled),
            "screenshots": String(captureScreenshots),
            "events": String(captureEvents),
        ]
        if let limit = frameLimit {
            sections["trace"]?["frame_limit"] = String(limit)
        }

        sections["capture"] = [
            "enabled": String(captureEnabled),
        ]

        sections["output"] = [
            "use_tmp": String(useTmp),
        ]

        sections["socket"] = [
            "enabled": String(socketEnabled),
        ]

        // Only write keybindings that differ from defaults
        var customBindings: [String: String] = [:]
        for (action, key) in keybindings {
            if DiagConfig.defaultKeybindings[action] != key {
                customBindings[action] = key
            }
        }
        if !customBindings.isEmpty {
            sections["keybindings"] = customBindings
        }

        return sections
    }

    /// Merge another config on top — non-nil values from `override` win.
    public func merging(override: DiagConfig) -> DiagConfig {
        // The override is fully populated, so it always wins.
        // This is used when programmatic config overrides the file.
        return override
    }

    // MARK: - Feature name mapping for CLI enable/disable

    /// Map a CLI feature name to the config key path it controls.
    /// Returns (section, key) or nil if the feature name is unknown.
    public static func featureKey(for name: String) -> (section: String, key: String)? {
        switch name {
        case "trace": return ("trace", "enabled")
        case "capture": return ("capture", "enabled")
        case "screenshots": return ("trace", "screenshots")
        case "events": return ("trace", "events")
        case "socket": return ("socket", "enabled")
        default: return nil
        }
    }

    /// All recognized feature names for help text.
    public static let featureNames = ["trace", "capture", "screenshots", "events", "socket"]

    // MARK: - Parsing helpers

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }
}
