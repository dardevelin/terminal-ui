import Foundation
import TerminalLog
import TerminalUI
import TerminalUIConfig

private let log = Log("swtui")

private let recordUsage = "Usage: swtui record dump <log.tuirec> [--at LABEL | --frame N]"

/// `swtui record dump <log> [--at LABEL | --frame N]` — the screen a
/// `.tuirec` log shows, as text: after its last frame, as it was when the
/// mark `LABEL` was made, or after the frame the app counted as `N`.
func recordCommand(args: [String]) {
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
