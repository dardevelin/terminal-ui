import TerminalUIConfig
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

    print()
    print("[keybindings]")
    for action in DiagConfig.keybindingActions {
        if let key = config.keybindings[action] {
            let isDefault = DiagConfig.defaultKeybindings[action] == key
            print("  \(action) = \(key)\(isDefault ? "" : " (custom)")")
        } else {
            print("  \(action) = (unbound)")
        }
    }

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

func bindCommand(args: [String]) {
    guard args.count >= 2 else {
        printError("Usage: swtui bind <action> <key>")
        print()
        print("Actions:")
        for action in DiagConfig.keybindingActions {
            if let key = DiagConfig.defaultKeybindings[action] {
                print("  \(action)  (default: \(key))")
            } else {
                print("  \(action)  (unbound)")
            }
        }
        print()
        print("Key format: F1, ctrl+d, alt+F2, ctrl+shift+x, etc.")
        exit(1)
    }

    let action = args[0]
    let keyString = args.dropFirst().joined(separator: " ")

    guard DiagConfig.keybindingActions.contains(action) else {
        printError("Unknown action: \(action)")
        print("Actions: \(DiagConfig.keybindingActions.joined(separator: ", "))")
        exit(1)
    }

    guard KeyCombo.parse(keyString) != nil else {
        printError("Invalid key: \(keyString)")
        print("Examples: F1, ctrl+d, alt+F2, ctrl+shift+x")
        exit(1)
    }

    DiagPaths.updateConfigValue(section: "keybindings", key: action, value: keyString)
    print("\(action) = \(keyString)")
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
      swtui init                  Create .terminalui/ with default config
      swtui status                Show current config and app status
      swtui enable <feature>      Enable a feature (trace, capture, screenshots, events, socket)
      swtui disable <feature>     Disable a feature
      swtui set <key> <value>     Set a config value (frame_limit, use_tmp, or section.key)
      swtui bind <action> <key>   Remap a debug keybinding (e.g. swtui bind toggle_inspector F5)
      swtui config                Print current config file
      swtui clean                 Remove all diagnostic output
      swtui ctl <cmd> [...]       Drive a running debug build (see `swtui ctl`)
      swtui help                  Show this help
    """)
}

func printError(_ message: String) {
    let stderr = FileHandle.standardError
    stderr.write(Data("error: \(message)\n".utf8))
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
            printError("send-key <name> [mod ...]")
            exit(1)
        }
        let mods = Array(positional.dropFirst())
        payload = ["id": 1, "cmd": "send_key", "key": key, "modifiers": mods]
    case "send-text", "text":
        guard !positional.isEmpty else {
            printError("send-text <text>")
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
            printError("probe <x> <y>")
            exit(1)
        }
        payload = ["id": 1, "cmd": "inspector_probe", "x": x, "y": y]
    case "inspect":
        // swtui ctl inspect — probe whatever cell the inspector cursor is on now
        payload = ["id": 1, "cmd": "inspector_probe"]
    case "inspector-move":
        guard positional.count == 2,
              let x = Int(positional[0]), let y = Int(positional[1]) else {
            printError("inspector-move <x> <y>")
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
            printError("inspect-range <x> <y> <w> <h>")
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
        printError("unknown ctl subcommand: \(subcommand)")
        printCtlUsage()
        exit(1)
    }

    let response = ctlSend(socketPath: socketPath, payload: payload)
    print(response)
}

private func ctlSend(socketPath: String, payload: [String: Any]) -> String {
    guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
        printError("failed to encode payload")
        exit(1)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        printError("socket() failed")
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
        printError("connect to \(socketPath) failed — is a debug app running?")
        exit(1)
    }
    // Write payload + newline
    var bytes = payloadData
    bytes.append(0x0A)
    _ = bytes.withUnsafeBytes { buf in
        write(fd, buf.baseAddress!, buf.count)
    }
    // Read response lines until we hit one ending in '\n'
    var response = Data()
    var scratch = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = scratch.withUnsafeMutableBufferPointer { buf in
            read(fd, buf.baseAddress!, buf.count)
        }
        if n <= 0 { break }
        response.append(scratch, count: n)
        if response.last == 0x0A { break }
    }
    return String(data: response, encoding: .utf8) ?? ""
}

/// Walk the socket directory and print each running app's PID + socket
/// path. Skips `latest.sock` (a symlink) so the output is one row per
/// live binary.
private func ctlList(socketDir: String) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: socketDir) else {
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
    print("""
    swtui ctl — drive a running debug build via its remote-control socket.

    Subcommands:
      ping                         liveness check
      send-key <name> [mods...]    inject a key event (arrows, enter, tab, a-z, f1-f12)
      send-text "..."              inject a sequence of characters
      focus                        report the currently-focused node
      cells [x y w h]              dump the rendered cell region (default: full frame)
      tree                         structured graph dump (AttributeGraph snapshot)
      probe <x> <y>                inspect the node at a given cell
      inspect                      inspect the cell currently under the inspector cursor
      inspector-move <x> <y>       move the inspector crosshair
      inspector-toggle             toggle the inspector overlay
      frame                        current frame number
      screenshot                   ask the runtime to capture the next frame to disk
      quit                         ask the app to exit cleanly (Ctrl+C via socket)
      list                         list all running debug apps (pid, status, socket)
      kill [pid|all]               send quit to one pid (or all); cleans up stale sockets

    Flags:
      --pid <N>        target a specific app by PID (default: latest.sock)
      --socket <path>  use an explicit socket path
      --dir <path>     override the socket directory
    """)
}
