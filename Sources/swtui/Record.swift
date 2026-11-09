import Foundation
import TerminalLog
import TerminalUI
import TerminalUIConfig
import TerminalUIRecording

private let log = Log("swtui")

private let recordUsage = """
    Usage: swtui record dump <log.tuirec> [--at LABEL | --frame N]
           swtui record start <path> [--label LABEL [--hold DURATION]]
           swtui record mark <label> [--hold DURATION]
           swtui record stop | status
           swtui record render <log.tuirec> --format cast -o OUT
    start, mark, stop and status reach a running debug build as swtui ctl does:
    --pid N, --socket PATH or --dir PATH, or the one app running from this checkout.
    """

/// `swtui record dump <log> [--at LABEL | --frame N]` — the screen a
/// `.tuirec` log shows, as text: after its last frame, as it was when the
/// mark `LABEL` was made, or after the frame the app counted as `N`.
func recordCommand(args: [String]) {
    if args.first == "render" {
        renderCommand(args: Array(args.dropFirst()))
        return
    }
    if let verb = args.first, controlVerbs.contains(verb) {
        recordControlCommand(verb: verb, args: Array(args.dropFirst()))
        return
    }
    guard args.first == "dump" else {
        log.error(recordUsage)
        exit(1)
    }
    var operands = Array(args.dropFirst())
    var position = RecordingScreen.Position.end
    if let flag = operands.firstIndex(where: { $0 == "--at" || $0 == "--frame" }) {
        guard flag + 1 < operands.count else {
            log.error(recordUsage)
            exit(1)
        }
        let value = operands[flag + 1]
        if operands[flag] == "--at" {
            position = .mark(value)
        } else if let number = Int(value) {
            position = .frame(number)
        } else {
            log.error("--frame takes a frame number, not \(value)")
            exit(1)
        }
        operands.removeSubrange(flag...(flag + 1))
    }
    guard operands.count == 1, let path = operands.first else {
        log.error(recordUsage)
        exit(1)
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        log.error("cannot read \(path)")
        exit(1)
    }
    do throws(RecordingLogError) {
        let screen = try RecordingScreen.replay(try RecordingLogReader.lines(in: data), to: position)
        for row in screen.cells {
            print(visibleText(row.map(\.character)))
        }
    } catch {
        log.error("\(path): \(error)")
        exit(1)
    }
}

/// A row as a terminal shows it: a wide character covers the cell after
/// it, which holds the space the framework writes there, so that space is
/// not printed a second time.
private func visibleText(_ cells: [Character]) -> String {
    var text = ""
    var covered = false
    for character in cells {
        if covered, character == " " {
            covered = false
            continue
        }
        text.append(character)
        covered = character.displayWidth == 2
    }
    return text
}

// MARK: - Recording a running app

/// The verbs that reach a running debug build's recorder over its socket.
private let controlVerbs: Set<String> = ["start", "mark", "stop", "status"]

/// `swtui record start <path> [--label L [--hold D]] | mark <label> [--hold D]
/// | stop | status`, against the app `--pid`, `--socket` or `--dir` names,
/// or the one running from this checkout, resolved as `swtui ctl` resolves
/// it. Prints how the recording stands as `key=value` pairs, the path last
/// so that one with spaces stays whole; exits 1 with the app's reason when
/// it refuses.
private func recordControlCommand(verb: String, args: [String]) {
    let (target, rest) = AppTarget.peel(from: args)
    var operands = rest
    let label = takeOption("--label", from: &operands)
    let hold = takeOption("--hold", from: &operands)
    var payload: [String: Any] = ["id": 1, "cmd": "record_\(verb)"]
    let wellFormed: Bool
    switch verb {
    case "start":
        // A hold belongs to a mark, which a start makes only when labelled.
        wellFormed = operands.count == 1 && (hold == nil || label != nil)
        if let path = operands.first {
            // The app opens the path from its own working directory, which
            // need not be this one.
            payload["path"] = (path as NSString).isAbsolutePath
                ? path
                : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        }
        payload["label"] = label
    case "mark":
        wellFormed = operands.count == 1 && label == nil
        payload["label"] = operands.first
    default:
        wellFormed = operands.isEmpty && label == nil && hold == nil
    }
    guard wellFormed else {
        log.error(recordUsage)
        exit(1)
    }
    if let hold {
        guard let milliseconds = PresentationClock.milliseconds(parsing: hold) else {
            log.error("--hold takes a duration such as 400ms or 1.5s, not \(hold)")
            exit(1)
        }
        payload["hold_ms"] = milliseconds
    }

    let reply = ctlSend(socketPath: target.socketPath(command: "swtui record"), payload: payload)
    guard let response = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
        log.error("the app's reply is not JSON: \(reply)")
        exit(1)
    }
    guard response["ok"] as? Bool == true else {
        log.error("record \(verb): \(response["error"] as? String ?? "the app refused")")
        exit(1)
    }
    let result = response["result"] as? [String: Any] ?? [:]
    let recording = result["recording"] as? [String: Any] ?? [:]
    var fields = ["active=\(recording["active"] as? Bool ?? false)"]
    for key in ["frames", "marks", "duration_ms"] {
        fields.append("\(key)=\(recording[key] as? Int ?? 0)")
    }
    if let frame = result["frame"] as? Int { fields.append("frame=\(frame)") }
    if let path = recording["path"] as? String { fields.append("path=\(path)") }
    print(fields.joined(separator: " "))
}

/// Removes `--name VALUE` from `operands` and returns the value; nil when
/// it is not there. A name with nothing after it is a usage error.
private func takeOption(_ name: String, from operands: inout [String]) -> String? {
    guard let index = operands.firstIndex(of: name) else { return nil }
    guard index + 1 < operands.count else {
        log.error(recordUsage)
        exit(1)
    }
    let value = operands[index + 1]
    operands.removeSubrange(index...(index + 1))
    return value
}
