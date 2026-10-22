import Foundation
import TerminalInk
import TerminalLog
import TerminalUI

private let log = Log("swtui")

/// `swtui keys` — every text-editing command with the keys the standard
/// keymap gives it: the names a user's `keys.toml` binds. `swtui keys
/// --check <file>` reads such a file as an app would and reports what it
/// binds and what it could not read.
func keysCommand(args: [String]) {
    switch args.first {
    case nil:
        listStandardKeys()
    case "--check":
        guard args.count == 2 else {
            log.error("Usage: swtui keys --check <keys.toml>")
            exit(1)
        }
        checkKeymapFile(at: URL(fileURLWithPath: args[1]))
    default:
        log.error("Usage: swtui keys [--check <keys.toml>]")
        exit(1)
    }
}

/// Two columns, the first padded to its widest entry.
private func printColumns(_ rows: [(String, String)]) {
    let width = (rows.map(\.0.count).max() ?? 0) + 2
    for (name, value) in rows {
        ink("  " + name.padding(toLength: width, withPad: " ", startingAt: 0).styled(.named(.cyan)) + value.muted)
    }
}

private func listStandardKeys() {
    ink("Text-editing commands and their standard keys".primary.bold)
    ink("A key with several commands tries them in order; a later one shows the one before it.".muted)
    ink("")
    let bindings = TextKeymap.standard.bindings.compactMap { binding, commands in
        binding.keySpec.map { (spec: $0, commands: commands) }
    }
    printColumns(TextEditCommand.declared.map { command in
        let keys = bindings.compactMap { binding -> String? in
            guard let position = binding.commands.firstIndex(of: command) else { return nil }
            return position == 0
                ? binding.spec
                : "\(binding.spec) (after \(binding.commands[position - 1].rawValue))"
        }
        return (command.rawValue, keys.isEmpty ? "—" : keys.sorted().joined(separator: ", "))
    })
}

private func checkKeymapFile(at url: URL) {
    guard let keymap = UserKeymap(contentsOf: url) else {
        log.error("\(url.path): no such file")
        exit(1)
    }
    for problem in keymap.problems {
        log.error("\(url.path): \(problem)")
    }
    let bindings = keymap.text.compactMap { binding, commands in
        binding.keySpec.map { ($0, commands.isEmpty ? "unbound" : commands.map(\.rawValue).joined(separator: ", ")) }
    }
    printColumns(bindings.sorted { $0.0 < $1.0 })
    guard keymap.problems.isEmpty else { exit(1) }
    ink("\(url.lastPathComponent): \(keymap.text.count) bindings, no problems".success)
}
