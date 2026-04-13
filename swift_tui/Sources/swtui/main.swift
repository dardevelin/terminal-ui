import TerminalUIConfig
import Foundation

// MARK: - swtui: developer CLI for managing .terminalui/ config

let args = Array(CommandLine.arguments.dropFirst())

guard let verb = args.first else {
    printUsage()
    exit(0)
}

switch verb {
case "init":
    initCommand()
case "status":
    statusCommand()
case "enable":
    toggleCommand(args: Array(args.dropFirst()), enable: true)
case "disable":
    toggleCommand(args: Array(args.dropFirst()), enable: false)
case "set":
    setCommand(args: Array(args.dropFirst()))
case "config":
    configCommand()
case "clean":
    cleanCommand()
case "help", "--help", "-h":
    printUsage()
default:
    printError("Unknown command: \(verb)")
    printUsage()
    exit(1)
}

// MARK: - Commands

func initCommand() {
    let fm = FileManager.default
    let configDir = DiagPaths.configDir
    let configFile = DiagPaths.configFile

    if fm.fileExists(atPath: configFile) {
        print("Config already exists at \(configFile)")
        return
    }

    DiagPaths.saveConfig(.default)
    print("Created \(configDir)/")
    print("  terminalui.toml (default config)")
}

func statusCommand() {
    let config = DiagPaths.loadConfig()
    let configFile = DiagPaths.configFile
    let fm = FileManager.default

    print("TerminalUI Diagnostics")
    print("======================")
    print()

    if fm.fileExists(atPath: configFile) {
        print("config:  \(configFile)")
    } else {
        print("config:  (none — using defaults, run 'swtui init' to create)")
    }

    let dataRoot = DiagPaths.dataDir(useTmp: config.useTmp)
    if fm.fileExists(atPath: dataRoot) {
        print("data:    \(dataRoot)")
    } else {
        print("data:    \(dataRoot) (not yet created)")
    }

    print()
    print("[trace]")
    print("  enabled      = \(config.traceEnabled)")
    print("  screenshots  = \(config.captureScreenshots)")
    print("  events       = \(config.captureEvents)")
    if let limit = config.frameLimit {
        print("  frame_limit  = \(limit)")
    } else {
        print("  frame_limit  = (unlimited)")
    }

    print()
    print("[capture]")
    print("  enabled      = \(config.captureEnabled)")

    print()
    print("[output]")
    print("  use_tmp      = \(config.useTmp)")

    print()
    print("[socket]")
    print("  enabled      = \(config.socketEnabled)")

    // Probe for running app via socket
    let sockPath = DiagPaths.socketPath(useTmp: config.useTmp)
    if fm.fileExists(atPath: sockPath) {
        print()
        print("socket:  \(sockPath) (exists — app may be running)")
    }
}

func toggleCommand(args: [String], enable: Bool) {
    guard let feature = args.first else {
        printError("Usage: swtui \(enable ? "enable" : "disable") <feature>")
        print("Features: \(DiagConfig.featureNames.joined(separator: ", "))")
        exit(1)
    }

    guard let (section, key) = DiagConfig.featureKey(for: feature) else {
        printError("Unknown feature: \(feature)")
        print("Features: \(DiagConfig.featureNames.joined(separator: ", "))")
        exit(1)
    }

    DiagPaths.updateConfigValue(section: section, key: key, value: String(enable))
    print("\(feature) \(enable ? "enabled" : "disabled")")
}

func setCommand(args: [String]) {
    guard args.count >= 2 else {
        printError("Usage: swtui set <key> <value>")
        print("Examples:")
        print("  swtui set frame_limit 50")
        print("  swtui set frame_limit 0    (removes limit)")
        exit(1)
    }

    let key = args[0]
    let value = args[1]

    // Map known shorthand keys to section.key
    let mapping: [String: (String, String)] = [
        "frame_limit": ("trace", "frame_limit"),
        "use_tmp": ("output", "use_tmp"),
    ]

    if let (section, tomlKey) = mapping[key] {
        // Special case: frame_limit = 0 means remove the limit
        if key == "frame_limit" && value == "0" {
            // Remove the key by writing the config without it
            var config = DiagPaths.loadConfig()
            config.frameLimit = nil
            DiagPaths.saveConfig(config)
            print("frame_limit removed (unlimited)")
            return
        }
        DiagPaths.updateConfigValue(section: section, key: tomlKey, value: value)
        print("\(key) = \(value)")
    } else {
        // Try section.key format: "trace.frame_limit"
        let parts = key.split(separator: ".", maxSplits: 1)
        if parts.count == 2 {
            DiagPaths.updateConfigValue(
                section: String(parts[0]),
                key: String(parts[1]),
                value: value
            )
            print("[\(parts[0])] \(parts[1]) = \(value)")
        } else {
            printError("Unknown key: \(key)")
            print("Known keys: frame_limit, use_tmp")
            print("Or use section.key format: trace.enabled, socket.enabled, etc.")
            exit(1)
        }
    }
}

func configCommand() {
    let configFile = DiagPaths.configFile

    if let contents = try? String(contentsOfFile: configFile, encoding: .utf8) {
        print(contents, terminator: "")
    } else {
        // Show defaults
        let toml = TOMLParser.write(DiagConfig.default.toSections())
        print("# (no config file — showing defaults)")
        print(toml, terminator: "")
    }
}

func cleanCommand() {
    DiagPaths.clean()
    print("Cleaned diagnostic output for \(FileManager.default.currentDirectoryPath)")
}

// MARK: - Output helpers

func printUsage() {
    print("""
    swtui — TerminalUI diagnostic manager

    Usage:
      swtui init                Create .terminalui/ with default config
      swtui status              Show current config and app status
      swtui enable <feature>    Enable a feature (trace, capture, screenshots, events, socket)
      swtui disable <feature>   Disable a feature
      swtui set <key> <value>   Set a config value (frame_limit, use_tmp, or section.key)
      swtui config              Print current config file
      swtui clean               Remove all diagnostic output
      swtui help                Show this help
    """)
}

func printError(_ message: String) {
    let stderr = FileHandle.standardError
    stderr.write(Data("error: \(message)\n".utf8))
}
