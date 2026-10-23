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
//     dim, custom bindings yellow).
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
case "keys":
    keysCommand(args: Array(args.dropFirst()))
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

    // The apps' dirs, not this CLI's own: the pid in `dataDir(useTmp:)`
    // would be swtui's, and no app writes there.
    let apps = DiagPaths.runningApps()
    if apps.isEmpty {
        ink("apps:    ".muted + "(none running from this checkout)".muted)
    }
    for app in apps {
        ink("app:     ".muted + "\(app.name ?? "?") pid \(app.pid)  " + app.dataDir.muted)
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
            // Custom bindings get yellow; defaults stay
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
    let kept = DiagPaths.clean()
    let path = FileManager.default.currentDirectoryPath
    ink("Cleaned diagnostic output for ".success + path.muted)
    if !kept.isEmpty {
        let pids = kept.map(String.init).joined(separator: ", ")
        ink("Left the output of running apps alone: pid \(pids)".muted)
    }
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
        ("keys [--check <file>]", "List the text-editing commands and keys, or check a keys.toml"),
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
/// debug build via its AF_UNIX socket and print the response. With no
/// `--pid`, reaches the one app running from this checkout, and refuses —
/// listing them — when several are: "the most recent" let an app a test
/// harness started take over a developer's session. Prints the response
/// JSON, exits non-zero on error.
///
/// Shipped so smoke tests can be shell scripts and humans can drive a
/// running app without an MCP client.
func ctlCommand(args: [String]) {
    // Flags may appear before or after the subcommand — scan the whole arg
    // list and peel off `--pid`, `--socket`, `--dir`. The first remaining
    // token is the subcommand; the rest become positional args.
    //
    // ctl is a CLIENT: it must resolve sockets among this checkout's apps
    // (`DiagPaths.runningApps`), never through its own `tmpDataDir` — the PID
    // in that path is ctl's, and no app ever wrote there. Resolution defers
    // until after flag parsing so `--pid` and `--dir` can choose.
    var explicitDir: String? = nil
    var explicitSocket: String? = nil
    var explicitPID: Int32? = nil
    var nonFlags: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--pid", i + 1 < args.count {
            explicitPID = Int32(args[i + 1])
            i += 2
        } else if arg == "--socket", i + 1 < args.count {
            explicitSocket = args[i + 1]
            i += 2
        } else if arg == "--dir", i + 1 < args.count {
            explicitDir = args[i + 1]
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

    let socketDirs: [String]
    if let explicitDir {
        socketDirs = [explicitDir]
    } else {
        socketDirs = DiagPaths.clientRemoteDirs()
    }
    // These act on the socket directories, not on one app, and `reap` exists
    // for when no app is alive: resolving a live socket first made all three
    // fail with "no running debug app" on a machine with none running.
    switch subcommand {
    case "list":
        // Read-only enumeration of running debug apps. No filesystem
        // mutation: dead sockets are reported as dead but NOT unlinked.
        // Use `swtui ctl reap` to clean those up.
        ctlList(socketDirs: socketDirs)
        return
    case "reap":
        // Remove what apps whose PID is dead left behind. Never sends
        // `quit`. Live processes are always preserved. This is the
        // verb automation calls; humans use `kill --pid <N>` when
        // they know exactly what they're killing.
        ctlReap(explicitDir: explicitDir)
        return
    case "kill":
        // Send `quit` to a single explicit PID. The legacy `kill all`
        // dragnet is gone — too easy to send `quit` to the user's
        // live session by accident. Bare `kill` (no --pid) is a
        // usage error that exits non-zero.
        ctlKill(socketDirs: socketDirs, explicitPID: explicitPID, positional: positional)
        return
    default:
        break
    }

    let socketPath: String
    if let explicitSocket {
        socketPath = explicitSocket
    } else if let explicitDir {
        guard let resolved = DiagPaths.socket(inRemoteDir: explicitDir, pid: explicitPID) else {
            let wanted = explicitPID.map { "pid \($0)'s socket" } ?? "exactly one app socket"
            log.error("\(explicitDir) does not hold \(wanted)")
            exit(1)
        }
        socketPath = resolved
    } else if let explicitPID {
        guard let resolved = DiagPaths.clientSocketPath(pid: explicitPID) else {
            log.error("no debug app with pid \(explicitPID) is running from this checkout (searched /tmp/terminalui-\(DiagPaths.cwdHash)-*/remote)")
            exit(1)
        }
        socketPath = resolved
    } else {
        // The one app running from this checkout. Several is a choice for
        // the caller: picking the newest let an app a test harness started
        // take over a developer's session.
        let apps = DiagPaths.runningApps()
        switch apps.count {
        case 1:
            socketPath = apps[0].socketPath
        case 0:
            log.error("no debug app is running from this checkout (searched /tmp/terminalui-\(DiagPaths.cwdHash)-*/remote)")
            exit(1)
        default:
            let rows = apps.map { "  --pid \($0.pid)  \($0.name ?? "?")" }.joined(separator: "\n")
            FileHandle.standardError.write(Data(
                "swtui ctl: \(apps.count) debug apps are running from this checkout; name one:\n\(rows)\n".utf8))
            exit(2)
        }
    }

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
    guard let fd = UnixSocket.connected(to: socketPath) else {
        log.error("connect to \(socketPath) failed — is a debug app running?")
        exit(1)
    }
    defer { close(fd) }
    guard UnixSocket.sendLine(Array(payloadData), to: fd) else {
        log.error("the app at \(socketPath) hung up")
        exit(1)
    }
    return String(decoding: UnixSocket.readLine(from: fd), as: UTF8.self)
}

/// Read-only enumeration of running debug apps. Probes each socket's
/// owning PID to label it alive or dead, but **never mutates filesystem
/// state**. Stale sockets are reported but not unlinked — that's
/// `swtui ctl reap`'s job. Splitting display from cleanup means automation
/// can `list` without fearing accidents.
private func ctlList(socketDirs: [String]) {
    var aliveCount = 0
    var deadCount = 0
    for socketDir in socketDirs {
        let appName = DiagPaths.recordedAppName(
            inDataDir: (socketDir as NSString).deletingLastPathComponent) ?? "?"
        for (pid, path) in DiagPaths.sockets(inRemoteDir: socketDir) {
            let alive = DiagPaths.isAlive(pid)
            // Machine-readable list — keep plain so `swtui ctl list | awk`
            // works without stripping ANSI.
            print("pid=\(pid) app=\(appName) status=\(alive ? "alive" : "dead") socket=\(path)")
            if alive { aliveCount += 1 } else { deadCount += 1 }
        }
    }
    if aliveCount == 0 && deadCount == 0 {
        print("(no debug apps)")
    } else if deadCount > 0 {
        // Hint at the reap path — but only when there's something to reap.
        print("# \(deadCount) dead socket\(deadCount == 1 ? "" : "s") — run `swtui ctl reap` to clean")
    }
}

/// Remove what apps whose PID is dead left behind: across this checkout,
/// their whole output — a crash or SIGKILL leaves it, and nothing else would
/// remove it — or, in an explicit `--dir`, their sockets and the `latest.sock`
/// links builds before 1.1 left beside them. Never sends `quit`. Live
/// processes are always preserved. The verb automation should call from CI /
/// Stop hooks / cron — replaces the legacy `kill all` dragnet which sent
/// `quit` indiscriminately.
private func ctlReap(explicitDir: String?) {
    guard let explicitDir else {
        let reaped = DiagPaths.removeDeadApps()
        for app in reaped {
            print("reaped pid=\(app.pid) \(app.ownsDataDir ? app.dataDir : app.socketPath)")
        }
        print("# \(reaped.count) app\(reaped.count == 1 ? "" : "s") reaped")
        return
    }
    var reaped = 0
    for (pid, path) in DiagPaths.sockets(inRemoteDir: explicitDir) where !DiagPaths.isAlive(pid) {
        if unlink(path) == 0 {
            print("reaped pid=\(pid) socket=\(path)")
            reaped += 1
        }
    }
    let legacyLink = "\(explicitDir)/latest.sock"
    if unlink(legacyLink) == 0 {
        print("reaped \(legacyLink)")
    }
    print("# \(reaped) socket\(reaped == 1 ? "" : "s") reaped")
}

/// Graceful shutdown helper for a single explicit PID. Connects to
/// `<socketDir>/<pid>.sock`, sends `quit`. If the connect fails (the
/// process is already dead), the stale socket file is unlinked so it
/// doesn't accumulate.
///
/// **Bare `kill` (no `--pid`) is a usage error.** The legacy "kill
/// every socket in this dir" dragnet was a footgun — it could send
/// `quit` to a user's live `swift run Storybook` session that
/// happened to share a directory with whatever the caller was trying
/// to clean up. Identity must be explicit.
private func ctlKill(socketDirs: [String], explicitPID: Int32?, positional: [String]) {
    // Refuse the legacy "all" alias and bare-kill invocations both —
    // surface a usage error so automation that relied on the old
    // semantics fails loudly instead of silently doing the wrong
    // thing.
    if positional.contains("all") {
        FileHandle.standardError.write(Data(
            "swtui ctl kill: `kill all` is removed (footgun — could quit your live session). Use `swtui ctl reap` to clean dead sockets, or `swtui ctl kill --pid <N>` to target one process.\n".utf8))
        exit(2)
    }
    guard let pid = explicitPID else {
        FileHandle.standardError.write(Data(
            "swtui ctl kill: --pid <N> is required. Use `swtui ctl list` to see running apps, or `swtui ctl reap` to clean stale sockets.\n".utf8))
        exit(2)
    }
    // Reject extra positional args — the verb takes nothing else.
    if !positional.isEmpty {
        FileHandle.standardError.write(Data(
            "swtui ctl kill: unexpected positional argument(s) \(positional). Usage: `swtui ctl kill --pid <N>`\n".utf8))
        exit(2)
    }

    // Find the dir that actually holds this PID's socket — a client must
    // search the checkout's per-process dirs, not assume one location.
    guard let path = socketDirs.lazy.compactMap({ DiagPaths.socket(inRemoteDir: $0, pid: pid) }).first else {
        print("pid=\(pid) status=no-socket")
        exit(1)
    }
    let payload: [String: Any] = ["id": 1, "cmd": "quit"]
    guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
        print("pid=\(pid) status=encode-failed")
        exit(1)
    }
    guard let fd = UnixSocket.connected(to: path) else {
        // Only a dead app's socket is stale. A live one that refused the
        // connection — a full backlog, say — keeps it, or every later
        // `ctl` would find nothing to reach.
        guard !DiagPaths.isAlive(pid) else {
            print("pid=\(pid) status=connect-failed")
            exit(1)
        }
        _ = unlink(path)
        print("pid=\(pid) status=stale-unlinked")
        return
    }
    _ = UnixSocket.sendLine(Array(payloadData), to: fd)
    close(fd)
    print("pid=\(pid) status=quit-sent")
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
        ("list",                       "list debug apps + their socket status (read-only)"),
        ("reap",                       "unlink stale sockets whose owning PID is dead"),
        ("kill --pid <N>",             "send quit to one explicit PID (no dragnet)"),
    ]
    for (cmd, desc) in subs {
        let cell = cmd.padding(toLength: 30, withPad: " ", startingAt: 0)
        ink("  " + cell.styled(.named(.cyan)) + desc.muted)
    }
    ink("")
    ink("Flags:", .primary, .bold)
    let flags: [(String, String)] = [
        ("--pid <N>",        "target a specific app by PID (default: the one running app)"),
        ("--socket <path>",  "use an explicit socket path"),
        ("--dir <path>",     "override the socket directory"),
    ]
    for (flag, desc) in flags {
        let cell = flag.padding(toLength: 18, withPad: " ", startingAt: 0)
        ink("  " + cell.styled(.named(.yellow)) + desc.muted)
    }
}
