import Foundation
import TerminalLog
import TerminalUIConfig
import TerminalUIRecording

private let log = Log("swtui")

private let renderUsage = """
    Usage: swtui record render <log.tuirec> --format cast -o OUT
             [--at LABEL | --from LABEL --to LABEL] [--clock script|draw]
             [--quantum 40ms] [--palette \(RecordingPalette.all.map(\.name).joined(separator: "|"))]
    """

/// The formats `render` writes. SVG, PNG and GIF follow the same reader,
/// clock and palette.
private enum RenderFormat: String {
    case cast
}

/// `swtui record render <log> --format cast -o OUT …` — a picture of a
/// `.tuirec` recording. `--at` renders the frame showing at a mark, and
/// `--from`/`--to` the part between two. The clock is `script` — marks and
/// their holds make the timeline — when the log has marks, else `draw`, its
/// real times with long gaps cut; `--clock` chooses.
func renderCommand(args: [String]) {
    var options: [String: String] = [:]
    var operands: [String] = []
    let valued: Set = ["--format", "-o", "--at", "--from", "--to", "--clock", "--quantum", "--palette"]
    var index = 0
    while index < args.count {
        let argument = args[index]
        if valued.contains(argument) {
            guard index + 1 < args.count else { fail("\(argument) takes a value\n\(renderUsage)") }
            options[argument] = args[index + 1]
            index += 2
        } else if argument.hasPrefix("-") {
            fail("unknown option \(argument)\n\(renderUsage)")
        } else {
            operands.append(argument)
            index += 1
        }
    }
    guard operands.count == 1, let path = operands.first, let output = options["-o"],
          let formatName = options["--format"] else {
        fail(renderUsage)
    }
    guard RenderFormat(rawValue: formatName) != nil else {
        fail("--format \(formatName) is not one swtui renders yet; it renders cast")
    }
    let paletteName = options["--palette"] ?? RecordingPalette.catppuccinMocha.name
    guard let palette = RecordingPalette.named(paletteName) else {
        fail("no palette \(paletteName); there are \(RecordingPalette.all.map(\.name).joined(separator: ", "))")
    }
    let range: PresentationClock.Range
    switch (options["--at"], options["--from"], options["--to"]) {
    case (nil, nil, nil): range = .whole
    case (let label?, nil, nil): range = .at(label)
    case (nil, let from?, let to?): range = .between(from: from, to: to)
    default: fail("--at takes no --from or --to, and --from and --to go together\n\(renderUsage)")
    }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }

    do throws(RecordingLogError) {
        let reader = try RecordingReader(bytes: data)
        let mode: PresentationClock.Mode
        switch options["--clock"] {
        case nil: mode = reader.marks.isEmpty ? .draw : .script
        case "script": mode = .script
        case "draw": mode = .draw
        case let other?: fail("--clock is script or draw, not \(other)")
        }
        var quantum = PresentationClock.defaultQuantum
        if let text = options["--quantum"] {
            guard let milliseconds = PresentationClock.milliseconds(parsing: text) else {
                fail("--quantum takes a duration such as 40ms, not \(text)")
            }
            quantum = milliseconds
        }
        let timeline = try PresentationClock(mode: mode, quantum: quantum).timeline(of: reader, range: range)
        let cast = CastEncoder(palette: palette).encode(reader, timeline: timeline)
        guard FileManager.default.createFile(atPath: output, contents: Data(cast.utf8)) else {
            fail("cannot write \(output)")
        }
    } catch {
        fail("\(path): \(error)")
    }
}

private func fail(_ message: String) -> Never {
    log.error(message)
    exit(1)
}
