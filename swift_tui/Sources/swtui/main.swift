import TerminalUIConfig
import TerminalInk
import TerminalLog
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - swtui: developer CLI for managing .terminalui/ config
//
// Output style guide (TerminalInk + TerminalLog migration):
//
//   - Errors: `Log("swtui").error(...)` — auto-routes to stderr with
//     red ERROR tag.
//   - Success messages: `ink(text, .success)` — green.
//   - Section headers ([trace], [capture], etc.): `ink(text, .primary, .bold)`.
//   - Key/value status lines: built with StyledString chain so keys
//     are dim, values colored by type (booleans green/red, paths
//     dim, custom bindings yellow per ticket spec).
//   - Help/usage blocks + machine-readable ctl output (PID lists,
//     JSON responses) stay as plain `print(...)` — terminal-style
//     decoration would impede `grep` / pipes.
//
// Capability detection happens automatically per-call inside `ink()`
// and the Log sinks. `NO_COLOR=1` and `swtui status | grep` both
// strip ANSI cleanly.

private let log = Log("swtui")

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
case "bind":
    bindCommand(args: Array(args.dropFirst()))
case "config":
    configCommand()
case "clean":
    cleanCommand()
case "ctl":
    ctlCommand(args: Array(args.dropFirst()))
case "help", "--help", "-h":
    printUsage()
default:
    log.error("Unknown command: \(verb)")
    printUsage()
    exit(1)
}

// MARK: - Commands

func initCommand() {
    let fm = FileManager.default
    let configDir = DiagPaths.configDir
    let configFile = DiagPaths.configFile

    if fm.fileExists(atPath: configFile) {
        ink("Config already exists at " + configFile.muted)
        return
    }

    DiagPaths.saveConfig(.default)
    ink("Created \(configDir)/", .success)
    ink("  terminalui.toml ".muted + "(default config)")
}

func statusCommand() {
    let config = DiagPaths.loadConfig()
    let configFile = DiagPaths.configFile
    let fm = FileManager.default

    ink("TerminalUI Diagnostics", .primary, .bold)
    ink("======================".muted)
    ink("")

    if fm.fileExists(atPath: configFile) {
        ink("config:  ".muted + configFile)
    } else {
        ink("config:  ".muted + "(none — using defaults, run 'swtui init' to create)".warning)
    }

    let dataRoot = DiagPaths.dataDir(useTmp: config.useTmp)
    if fm.fileExists(atPath: dataRoot) {
        ink("data:    ".muted + dataRoot)
    } else {
        ink("data:    ".muted + dataRoot + " " + "(not yet created)".muted)
    }

    ink("")
    ink("[trace]", .primary, .bold)
    statusRow("enabled",      bool: config.traceEnabled)
    statusRow("screenshots",  bool: config.captureScreenshots)
    statusRow("events",       bool: config.captureEvents)
    if let limit = config.frameLimit {
        statusRow("frame_limit", value: "\(limit)", color: .named(.cyan))
    } else {
        statusRow("frame_limit", value: "(unlimited)", color: .muted)
    }

    ink("")
    ink("[capture]", .primary, .bold)
    statusRow("enabled", bool: config.captureEnabled)

    ink("")
    ink("[output]", .primary, .bold)
    statusRow("use_tmp", bool: config.useTmp)

    ink("")
    ink("[socket]", .primary, .bold)
    statusRow("enabled", bool: config.socketEnabled)

    ink("")
    ink("[keybindings]", .primary, .bold)
    for action in DiagConfig.keybindingActions {
        if let key = config.keybindings[action] {
            let isDefault = DiagConfig.defaultKeybindings[action] == key
            // Custom bindings get yellow (ticket spec); defaults stay
            // muted so the eye lands on the customizations.
            let valueStyle: InkColor = isDefault ? .secondary : .warning
            var line = "  " + action.muted + " = " + key.styled(valueStyle)
            if !isDefault { line = line + " " + "(custom)".warning }
            ink(line)
        } else {
            ink("  " + action.muted + " = " + "(unbound)".muted)
        }
    }

    // Probe for running app via socket
    let sockPath = DiagPaths.socketPath(useTmp: config.useTmp)
    if fm.fileExists(atPath: sockPath) {
        ink("")
        ink("socket:  ".muted + sockPath + " " + "(exists — app may be running)".success)
    }
}

/// Render a `key = value` row with consistent indent + dim key + typed
/// value color. Kept as a helper so the per-section calls stay terse.
private func statusRow(_ key: String, bool: Bool) {
    let value: StyledString = bool ? "true".success : "false".muted
    ink("  " + key.muted + " = " + value)
}

private func statusRow(_ key: String, value: String, color: InkColor) {
    ink("  " + key.muted + " = " + value.styled(color))
}

func toggleCommand(args: [String], enable: Bool) {
    guard let feature = args.first else {
        log.error("Usage: swtui \(enable ? "enable" : "disable") <feature>")
        ink("Features: " + DiagConfig.featureNames.joined(separator: ", ").muted)
        exit(1)
    }

    guard let (section, key) = DiagConfig.featureKey(for: feature) else {
        log.error("Unknown feature: \(feature)")
        ink("Features: " + DiagConfig.featureNames.joined(separator: ", ").muted)
        exit(1)
    }

    DiagPaths.updateConfigValue(section: section, key: key, value: String(enable))
    let verb = enable ? "enabled" : "disabled"
    ink(feature + " " + verb.success)
}

func setCommand(args: [String]) {
    guard args.count >= 2 else {
        log.error("Usage: swtui set <key> <value>")
        ink("Examples:".muted)
        ink("  swtui set frame_limit 50".muted)
        ink("  swtui set frame_limit 0    (removes limit)".muted)
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
            ink("frame_limit removed (unlimited)", .success)
            return
        }
        DiagPaths.updateConfigValue(section: section, key: tomlKey, value: value)
        ink(key.muted + " = " + value.styled(.named(.cyan)))
    } else {
        // Try section.key format: "trace.frame_limit"
        let parts = key.split(separator: ".", maxSplits: 1)
        if parts.count == 2 {
            DiagPaths.updateConfigValue(
                section: String(parts[0]),
                key: String(parts[1]),
                value: value
            )
            ink("[\(parts[0])] ".primary + String(parts[1]).muted + " = " + value.styled(.named(.cyan)))
        } else {
            log.error("Unknown key: \(key)")
            ink("Known keys: " + "frame_limit, use_tmp".muted)
            ink("Or use section.key format: " + "trace.enabled, socket.enabled, etc.".muted)
            exit(1)
        }
    }
}

func bindCommand(args: [String]) {
    guard args.count >= 2 else {
        log.error("Usage: swtui bind <action> <key>")
        ink("")
        ink("Actions:", .primary, .bold)
        for action in DiagConfig.keybindingActions {
            if let key = DiagConfig.defaultKeybindings[action] {
                ink("  " + action + "  " + "(default: \(key))".muted)
            } else {
                ink("  " + action + "  " + "(unbound)".muted)
            }
        }
        ink("")
        ink("Key format: " + "F1, ctrl+d, alt+F2, ctrl+shift+x, etc.".muted)
        exit(1)
    }

    let action = args[0]
    let keyString = args.dropFirst().joined(separator: " ")

    guard DiagConfig.keybindingActions.contains(action) else {
        log.error("Unknown action: \(action)")
        ink("Actions: " + DiagConfig.keybindingActions.joined(separator: ", ").muted)
        exit(1)
    }

    guard KeyCombo.parse(keyString) != nil else {
        log.error("Invalid key: \(keyString)")
        ink("Examples: " + "F1, ctrl+d, alt+F2, ctrl+shift+x".muted)
        exit(1)
    }

    DiagPaths.updateConfigValue(section: "keybindings", key: action, value: keyString)
    ink(action.muted + " = " + keyString.warning)
}

func configCommand() {
    let configFile = DiagPaths.configFile

    if let contents = try? String(contentsOfFile: configFile, encoding: .utf8) {
        // Raw config dump — leave plain so `swtui config | tee out.toml`
        // and `diff <(swtui config) terminalui.toml` work without
        // ANSI noise. Capability stripping in `ink()` would also
        // handle this for piped output, but keeping the raw print
        // makes the intent explicit.
        print(contents, terminator: "")
    } else {
        ink("# (no config file — showing defaults)".muted)
        let toml = TOMLParser.write(DiagConfig.default.toSections())
        print(toml, terminator: "")
    }
}

func cleanCommand() {
    DiagPaths.clean()
    let path = FileManager.default.currentDirectoryPath
    ink("Cleaned diagnostic output for ".success + path.muted)
}

// MARK: - Output helpers

func printUsage() {
    // Multi-line usage block — keep mostly plain so the eye scans by
    // structure, but tint command names (the lookup target) cyan.
    ink("swtui ".primary.bold + "— TerminalUI diagnostic manager".muted)
    ink("")
    ink("Usage:", .primary, .bold)
    let rows: [(String, String)] = [
        ("init",                 "Create .terminalui/ with default config"),
        ("status",               "Show current config and app status"),
        ("enable <feature>",     "Enable a feature (trace, capture, screenshots, events, socket)"),
        ("disable <feature>",    "Disable a feature"),
        ("set <key> <value>",    "Set a config value (frame_limit, use_tmp, or section.key)"),
        ("bind <action> <key>",  "Remap a debug keybinding (e.g. swtui bind toggle_inspector F5)"),
        ("config",               "Print current config file"),
        ("clean",                "Remove all diagnostic output"),
        ("ctl <cmd> [...]",      "Drive a running debug build (see `swtui ctl`)"),
        ("help",                 "Show this help"),
    ]
    for (cmd, desc) in rows {
        // Pad cmd to 22 chars so descriptions align — same shape as
        // `man` two-column help.
        let cmdCell = cmd.padding(toLength: 22, withPad: " ", startingAt: 0)
        ink("  " + cmdCell.styled(.named(.cyan)) + desc.muted)
    }
}

// MARK: - ctl (remote control socket client)

/// `swtui ctl <cmd> [args...]` — send a single JSON command to a running
/// debug build via its AF_UNIX socket and print the response. Resolves the
/// socket via the `latest.sock` symlink (most-recently-started app) unless
/// `--pid <N>` is supplied. Prints the response JSON, exits non-zero on
/// error.
///
/// Shipped so smoke tests can be shell scripts and humans can drive a
/// running app without an MCP client.
func ctlCommand(args: [String]) {
    // Flags may appear before or after the subcommand — scan the whole arg
    // list and peel off `--pid`, `--socket`, `--dir`. The first remaining
    // token is the subcommand; the rest become positional args.
    var socketDir = DiagPaths.socketDir(useTmp: DiagPaths.loadConfig().useTmp)
    var socketPath = "\(socketDir)/latest.sock"
    var nonFlags: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--pid", i + 1 < args.count {
            socketPath = "\(socketDir)/\(args[i + 1]).sock"
            i += 2
        } else if arg == "--socket", i + 1 < args.count {
            socketPath = args[i + 1]
            i += 2
        } else if arg == "--dir", i + 1 < args.count {
            socketDir = args[i + 1]
            socketPath = "\(socketDir)/latest.sock"
            i += 2
        } else {
            nonFlags.append(arg)
            i += 1
        }
    }
    guard let subcommand = nonFlags.first else {
        printCtlUsage()
        exit(1)
    }
    let positional = Array(nonFlags.dropFirst())

    let payload: [String: Any]
    switch subcommand {
    case "ping":
        payload = ["id": 1, "cmd": "ping"]
    case "send-key", "key":
        guard let key = positional.first else {
            log.error("send-key <name> [mod ...]")
            exit(1)
        }
        let mods = Array(positional.dropFirst())
        payload = ["id": 1, "cmd": "send_key", "key": key, "modifiers": mods]
    case "send-text", "text":
        guard !positional.isEmpty else {
            log.error("send-text <text>")
            exit(1)
        }
        payload = ["id": 1, "cmd": "send_text", "text": positional.joined(separator: " ")]
    case "focus":
        payload = ["id": 1, "cmd": "focus_get"]
    case "cells":
        // swtui ctl cells [x y w h] [--grid]
        var rect: [Int] = []
        var wantGrid = false
        for s in positional {
            if s == "--grid" { wantGrid = true }
            else if let n = Int(s) { rect.append(n) }
        }
        var body: [String: Any] = ["id": 1, "cmd": "query_cells"]
        if rect.count == 4 { body["rect"] = rect }
        if wantGrid { body["grid"] = true }
        payload = body
    case "tree":
        payload = ["id": 1, "cmd": "query_tree"]
    case "probe":
        // swtui ctl probe <x> <y>
        guard positional.count == 2,
              let x = Int(positional[0]), let y = Int(positional[1]) else {
            log.error("probe <x> <y>")
            exit(1)
        }
        payload = ["id": 1, "cmd": "inspector_probe", "x": x, "y": y]
    case "inspect":
        // swtui ctl inspect — probe whatever cell the inspector cursor is on now
        payload = ["id": 1, "cmd": "inspector_probe"]
    case "inspector-move":
        guard positional.count == 2,
              let x = Int(positional[0]), let y = Int(positional[1]) else {
            log.error("inspector-move <x> <y>")
            exit(1)
        }
        payload = ["id": 1, "cmd": "inspector_move", "x": x, "y": y]
    case "inspector-toggle":
        payload = ["id": 1, "cmd": "inspector_toggle"]
    case "inspect-range":
        // swtui ctl inspect-range <x> <y> <w> <h>
        guard positional.count == 4,
              let x = Int(positional[0]), let y = Int(positional[1]),
              let w = Int(positional[2]), let h = Int(positional[3]) else {
            log.error("inspect-range <x> <y> <w> <h>")
            exit(1)
        }
        payload = ["id": 1, "cmd": "inspect_range", "rect": [x, y, w, h]]
    case "scan":
        // swtui ctl scan --kind Text --text "HELLO" --focused
        var body: [String: Any] = ["id": 1, "cmd": "scan"]
        var j = 0
        while j < positional.count {
            let arg = positional[j]
            switch arg {
            case "--kind":
                if j + 1 < positional.count { body["match_kind"] = positional[j + 1]; j += 2 } else { j += 1 }
            case "--text":
                if j + 1 < positional.count { body["match_text"] = positional[j + 1]; j += 2 } else { j += 1 }
            case "--focused":
                body["match_focused"] = true; j += 1
            default:
                j += 1
            }
        }
        payload = body
    case "frame":
        payload = ["id": 1, "cmd": "frame_number"]
    case "screenshot":
        payload = ["id": 1, "cmd": "screenshot"]
    case "quit":
        payload = ["id": 1, "cmd": "quit"]
    case "list":
        // Enumerate running debug apps by reading the socket directory.
        // No socket round-trip needed — it's a filesystem query.
        ctlList(socketDir: socketDir)
        return
    case "kill":
        // Send `quit` to every app (or a targeted one). Useful from CI /
        // smoke runners that don't want to rely on pkill.
        ctlKill(socketDir: socketDir, positional: positional, defaultPath: socketPath)
        return
    default:
        log.error("unknown ctl subcommand: \(subcommand)")
        printCtlUsage()
        exit(1)
    }

    // Response is JSON — leave plain so consumers can `jq` it without
    // stripping ANSI first.
    let response = ctlSend(socketPath: socketPath, payload: payload)
    print(response)
}

private func ctlSend(socketPath: String, payload: [String: Any]) -> String {
    guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
        log.error("failed to encode payload")
        exit(1)
    }
    #if canImport(Glibc)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else {
        log.error("socket() failed")
        exit(1)
    }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        _ = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
            strncpy(buf, socketPath, 103)
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        log.error("connect to \(socketPath) failed — is a debug app running?")
        exit(1)
    }
    // Write payload + newline
    var bytes = payloadData
    bytes.append(0x0A)
    _ = bytes.withUnsafeBytes { buf in
        write(fd, buf.baseAddress!, buf.count)
    }
    // Read until the response's terminating newline appears anywhere in
    // the buffer — the protocol is one JSON line per response, so any
    // `\n` ends it. Earlier we checked `response.last == 0x0A`, which
    // broke for multi-chunk reads where the final chunk didn't end on a
    // newline boundary — swtui hung reading empty-socket bytes that never
    // came.
    var response = Data()
    var scratch = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = scratch.withUnsafeMutableBufferPointer { buf in
            read(fd, buf.baseAddress!, buf.count)
        }
        if n <= 0 { break }
        response.append(scratch, count: n)
        if response.contains(0x0A) { break }
    }
    return String(data: response, encoding: .utf8) ?? ""
}

/// Walk the socket directory and print each running app's PID + socket
/// path. Skips `latest.sock` (a symlink) so the output is one row per
/// live binary.
private func ctlList(socketDir: String) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: socketDir) else {
        // Machine-readable line — leave plain.
        print("(no sockets — socket dir missing)")
        return
    }
    var found = 0
    for name in entries.sorted() where name.hasSuffix(".sock") && name != "latest.sock" {
        let path = "\(socketDir)/\(name)"
        let pid = name.replacingOccurrences(of: ".sock", with: "")
        // Verify the app is alive. Stale sockets accumulate when an app
        // is killed hard; auto-reap them so subsequent runs have a clean
        // directory. (The runtime's defer cleans up on graceful exit.)
        let alive = (Int(pid).flatMap { kill(Int32($0), 0) == 0 } ?? false)
        if !alive {
            _ = unlink(path)
            continue
        }
        // Machine-readable list — keep plain so `swtui ctl list | awk`
        // works without stripping ANSI.
        print("pid=\(pid) status=alive socket=\(path)")
        found += 1
    }
    if found == 0 {
        print("(no running debug apps)")
    }
}

/// Graceful shutdown helper. Without args, sends `quit` to every .sock
/// file in the socket dir + unlinks stale ones. With a positional "all"
/// the behavior is the same — kept for explicit tests. With a PID,
/// targets that single app.
private func ctlKill(socketDir: String, positional: [String], defaultPath: String) {
    let fm = FileManager.default
    let target = positional.first
    let paths: [String]
    if let target, target != "all" {
        paths = ["\(socketDir)/\(target).sock"]
    } else {
        // Collect every .sock (excluding the latest symlink).
        let entries = (try? fm.contentsOfDirectory(atPath: socketDir)) ?? []
        paths = entries
            .filter { $0.hasSuffix(".sock") && $0 != "latest.sock" }
            .map { "\(socketDir)/\($0)" }
    }
    if paths.isEmpty {
        print("(nothing to kill)")
        return
    }
    for path in paths {
        let pid = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".sock", with: "")
        // Try clean shutdown first via the socket's quit command. If the
        // app is already dead the connect fails, in which case just unlink
        // the stale socket so the next boot doesn't collide.
        let payload: [String: Any] = ["id": 1, "cmd": "quit"]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            print("pid=\(pid) status=encode-failed")
            continue
        }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        if fd < 0 {
            print("pid=\(pid) status=socket-failed")
            continue
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            _ = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                strncpy(buf, path, 103)
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            close(fd)
            _ = unlink(path)  // stale socket → clean up
            print("pid=\(pid) status=stale-unlinked")
            continue
        }
        var bytes = payloadData
        bytes.append(0x0A)
        _ = bytes.withUnsafeBytes { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
        close(fd)
        print("pid=\(pid) status=quit-sent")
    }
}

private func printCtlUsage() {
    ink("swtui ctl ".primary.bold + "— drive a running debug build via its remote-control socket.".muted)
    ink("")
    ink("Subcommands:", .primary, .bold)
    let subs: [(String, String)] = [
        ("ping",                       "liveness check"),
        ("send-key <name> [mods...]",  "inject a key event (arrows, enter, tab, a-z, f1-f12)"),
        ("send-text \"...\"",          "inject a sequence of characters"),
        ("focus",                      "report the currently-focused node"),
        ("cells [x y w h]",            "dump the rendered cell region (default: full frame)"),
        ("tree",                       "structured graph dump (AttributeGraph snapshot)"),
        ("probe <x> <y>",              "inspect the node at a given cell"),
        ("inspect",                    "inspect the cell currently under the inspector cursor"),
        ("inspector-move <x> <y>",     "move the inspector crosshair"),
        ("inspector-toggle",           "toggle the inspector overlay"),
        ("frame",                      "current frame number"),
        ("screenshot",                 "ask the runtime to capture the next frame to disk"),
        ("quit",                       "ask the app to exit cleanly (Ctrl+C via socket)"),
        ("list",                       "list all running debug apps (pid, status, socket)"),
        ("kill [pid|all]",             "send quit to one pid (or all); cleans up stale sockets"),
    ]
    for (cmd, desc) in subs {
        let cell = cmd.padding(toLength: 30, withPad: " ", startingAt: 0)
        ink("  " + cell.styled(.named(.cyan)) + desc.muted)
    }
    ink("")
    ink("Flags:", .primary, .bold)
    let flags: [(String, String)] = [
        ("--pid <N>",        "target a specific app by PID (default: latest.sock)"),
        ("--socket <path>",  "use an explicit socket path"),
        ("--dir <path>",     "override the socket directory"),
    ]
    for (flag, desc) in flags {
        let cell = flag.padding(toLength: 18, withPad: " ", startingAt: 0)
        ink("  " + cell.styled(.named(.yellow)) + desc.muted)
    }
}
