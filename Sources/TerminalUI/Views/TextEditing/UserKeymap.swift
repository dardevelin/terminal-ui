import Foundation
import Synchronization
import TerminalUIConfig

/// A user's own key bindings, read from a TOML file the app lets them keep —
/// what `DefaultKeyBinding.dict` is to Cocoa, or `.inputrc` to readline. See
/// <doc:EditingKeys> for the file and how an app opts in.
///
/// Read once, before the app takes the terminal, and laid over the app's
/// keymap in every input. An app reads it back as
/// `@TerminalEnvironment(\.userKeymap)` — to show ``problems`` in a banner,
/// say, as stderr is hidden once the app has the screen.
public final class UserKeymap: Sendable, Equatable {
    /// The text-editing bindings the file states, from its `[text]` section:
    /// each key with the commands it tries, an empty list unbinding it.
    public let text: [InputBinding: [TextEditCommand]]
    /// What could not be read, each with its line; the rest still applies.
    public let problems: [TOMLDocument.Problem]

    /// The last keymap the bindings were laid over, and the result: an input
    /// reads it every time its body runs, and the same result — the same
    /// storage — is what lets the environment see nothing changed.
    private let lastApplied = Mutex<(base: TextKeymap, applied: TextKeymap)?>(nil)

    /// No bindings: the app reads no file, or the user has made none.
    public static let none = UserKeymap(text: [:], problems: [])

    private static let sections = ["text"]

    private init(text: [InputBinding: [TextEditCommand]], problems: [TOMLDocument.Problem]) {
        self.text = text
        self.problems = problems
    }

    /// Reads `toml`. A user file binds the framework's commands
    /// (``TextEditCommand/declared``); a name outside them is a problem.
    public convenience init(toml: String) {
        let document = TOMLParser.document(toml)
        var text: [InputBinding: [TextEditCommand]] = [:]
        var problems = document.problems
        var reportedSections: Set<String> = []
        let known = Set(TextEditCommand.declared)
        for entry in document.entries {
            guard Self.sections.contains(entry.section) else {
                if reportedSections.insert(entry.section).inserted {
                    let sections = Self.sections.map { "[\($0)]" }.joined(separator: ", ")
                    problems.append(.init(line: entry.line, message: "`[\(entry.section)]` is not a "
                        + "section of this file; the sections are \(sections)"))
                }
                continue
            }
            let names: [String]
            switch entry.value {
            case .string(let name):
                names = [name]
            case .strings(let list):
                names = list
            default:
                problems.append(.init(line: entry.line, message: "a key binds a command's name, "
                    + "a list of them, or [] to unbind it"))
                continue
            }
            let binding: InputBinding
            do {
                binding = try InputBinding(keySpec: entry.key)
            } catch {
                problems.append(.init(line: entry.line, message: error.description))
                continue
            }
            let commands = names.map(TextEditCommand.init(rawValue:))
            if let unknown = commands.first(where: { !known.contains($0) }) {
                let list = TextEditCommand.declared.map(\.rawValue).joined(separator: ", ")
                problems.append(.init(line: entry.line, message: "`\(unknown.rawValue)` is not a command; "
                    + "the commands are \(list)"))
                continue
            }
            text[binding] = commands
        }
        self.init(text: text, problems: problems)
    }

    /// Reads the file at `url`; nil when there is none — the user has not
    /// made one, which is not a mistake. Bytes that are not UTF-8 read as
    /// U+FFFD, and the lines they spoil are problems like any other.
    public convenience init?(contentsOf url: URL) {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        self.init(toml: String(decoding: data, as: UTF8.self))
    }

    /// `keymap` with these bindings laid over it.
    func applied(to keymap: TextKeymap) -> TextKeymap {
        guard !text.isEmpty else { return keymap }
        return lastApplied.withLock { last in
            if let last, last.base == keymap { return last.applied }
            let applied = keymap.merging(text)
            last = (keymap, applied)
            return applied
        }
    }

    /// The same keymap read once: what one input applies, all apply.
    public static func == (lhs: UserKeymap, rhs: UserKeymap) -> Bool {
        lhs === rhs
    }
}

/// Where an app's users keep their own key bindings, if anywhere — the app
/// decides: see ``TerminalAppProtocol/userKeymap``.
public enum UserKeymapSource: Sendable, Equatable {
    /// The standard keymap and the app's own only; no file is read.
    case none
    /// `keys.toml` in a directory named for the app in the user's config
    /// directory: `$XDG_CONFIG_HOME/<name>/keys.toml`, or
    /// `~/.config/<name>/keys.toml` (XDG Base Directory Specification).
    case configFile(named: String)
    /// The file at `url`.
    case file(at: URL)

    /// The file to read, under `environment`.
    public func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        switch self {
        case .none:
            return nil
        case .file(at: let url):
            return url
        case .configFile(named: let name):
            let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? environment["HOME"].map { "\($0)/.config" }
            return configHome.map { URL(fileURLWithPath: "\($0)/\(name)/keys.toml") }
        }
    }
}

extension TerminalView {
    /// Whether a user's own key bindings apply in this subtree. An input
    /// whose keys the app must own — a game, a field with modes of its own —
    /// turns them off.
    public func allowsUserKeymap(_ allowed: Bool) -> ModifiedView<Self, EnvironmentModifier<Bool>> {
        environment(\.allowsUserKeymap, allowed)
    }
}
