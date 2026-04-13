import Foundation

/// Unified diagnostic configuration for TerminalUI.
/// Read from `.terminalui/terminalui.toml` at startup, writable by the `swtui` CLI.
public struct DiagConfig: Sendable {

    // MARK: - [trace]

    public var traceEnabled: Bool
    public var captureScreenshots: Bool
    public var captureEvents: Bool
    public var frameLimit: Int?

    // MARK: - [capture]

    public var captureEnabled: Bool

    // MARK: - [output]

    public var useTmp: Bool

    // MARK: - [socket]

    public var socketEnabled: Bool

    // MARK: - Memberwise init

    public init(
        traceEnabled: Bool,
        captureScreenshots: Bool,
        captureEvents: Bool,
        frameLimit: Int?,
        captureEnabled: Bool,
        useTmp: Bool,
        socketEnabled: Bool
    ) {
        self.traceEnabled = traceEnabled
        self.captureScreenshots = captureScreenshots
        self.captureEvents = captureEvents
        self.frameLimit = frameLimit
        self.captureEnabled = captureEnabled
        self.useTmp = useTmp
        self.socketEnabled = socketEnabled
    }

    // MARK: - Defaults

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
