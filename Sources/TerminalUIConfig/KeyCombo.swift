/// Why a key spec could not be read.
public struct KeySpecError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// A key and the modifiers held with it, written as a person writes it —
/// `F1`, `ctrl+d`, `ctrl+shift+F2`, `alt+backspace`, `shift+enter`, `alt+<`.
/// The one spelling for keys across the framework: the debug keybindings in
/// `terminalui.toml`, a user's `keys.toml`, `swtui bind`, `swtui keys`, and
/// the remote control's `send-key`. Framework-agnostic — TerminalUI maps it
/// to its `Key` and `KeyModifiers`.
public struct KeyCombo: Sendable, Equatable, CustomStringConvertible {
    public enum KeyName: Sendable, Equatable {
        case character(Character)
        case f(Int)
        case enter
        case tab
        case escape
        case backspace
        case delete
        case up, down, left, right
        case home, end
        case pageUp, pageDown
    }

    public enum Modifier: Sendable, Equatable, CaseIterable {
        case ctrl, alt, shift
    }

    public var key: KeyName
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool

    public init(key: KeyName, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) {
        self.key = key
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
    }

    /// Keys with a name, each name list led by the one ``description``
    /// writes.
    private static let namedKeys: [(names: [String], key: KeyName)] = [
        (["enter", "return"], .enter), (["tab"], .tab), (["escape", "esc"], .escape),
        (["backspace", "bs"], .backspace), (["delete", "del"], .delete),
        (["up"], .up), (["down"], .down), (["left"], .left), (["right"], .right),
        (["home"], .home), (["end"], .end),
        (["pageup", "pgup"], .pageUp), (["pagedown", "pgdn"], .pageDown),
        (["space"], .character(" ")),
    ]

    /// Each modifier's names, led by the one ``description`` writes. Alt is
    /// the Option key on a Mac, and Meta to Emacs and readline.
    private static let modifierNames: [(names: [String], modifier: Modifier)] = [
        (["ctrl", "control"], .ctrl),
        (["alt", "option", "opt", "meta"], .alt),
        (["shift"], .shift),
    ]

    /// The function keys a terminal reports (xterm's ctlseqs go to F24).
    public static let functionKeys = 1...24

    /// What macOS terminals send for the Command chords people reach for —
    /// their "natural text editing" presets, and Ghostty's defaults.
    private static let commandEquivalents =
        "Cmd+Left arrives as ctrl+a, Cmd+Right as ctrl+e, Cmd+Backspace as ctrl+u"

    /// Reads `spec`: modifiers and a key joined by `+`, in any case and
    /// order. A terminal never hands an app the Command key, so `cmd` is an
    /// error that says which key the terminal sends instead.
    public init(spec: String) throws(KeySpecError) {
        let lowered = spec.trimmingCharacters(in: .whitespaces).lowercased()
        // The key is what follows the last `+` but one character from the
        // end, so "ctrl++" is Ctrl and the plus key and "+" is the plus key.
        let keyStart = lowered.dropLast().lastIndex(of: "+").map(lowered.index(after:)) ?? lowered.startIndex
        let keyPart = String(lowered[keyStart...])
        let modifierPart = lowered[..<keyStart].dropLast()
        var combo = KeyCombo(key: try Self.key(named: keyPart, in: spec))
        for name in modifierPart.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        where !modifierPart.isEmpty {
            if ["cmd", "command", "super"].contains(name) {
                throw KeySpecError("`\(spec)`: a terminal never sends the Command key to an app; "
                    + "bind the key it sends instead — \(Self.commandEquivalents)")
            }
            switch Self.modifier(named: name) {
            case .ctrl: combo.ctrl = true
            case .alt: combo.alt = true
            case .shift: combo.shift = true
            case nil:
                let names = Self.modifierNames.flatMap(\.names).joined(separator: ", ")
                throw KeySpecError("`\(spec)`: `\(name)` is not a modifier; the modifiers are \(names)")
            }
        }
        self = combo
    }

    /// Reads `string` as ``init(spec:)`` does; nil where that throws.
    public static func parse(_ string: String) -> KeyCombo? {
        try? KeyCombo(spec: string)
    }

    private static func key(named name: String, in spec: String) throws(KeySpecError) -> KeyName {
        if name.count == 1, let character = name.first {
            return .character(character)
        }
        if let key = keyName(named: name) {
            return key
        }
        let names = namedKeys.map(\.names[0]).joined(separator: ", ")
        throw KeySpecError("`\(spec)`: `\(name)` is not a key; a key is one character, "
            + "F\(functionKeys.lowerBound) to F\(functionKeys.upperBound), or one of \(names)")
    }

    /// The key with `name` — a named key or a function key, not a single
    /// character — in any case.
    public static func keyName(named name: String) -> KeyName? {
        let lowered = name.lowercased()
        if let key = namedKeys.first(where: { $0.names.contains(lowered) })?.key {
            return key
        }
        if lowered.hasPrefix("f"), let number = Int(lowered.dropFirst()), functionKeys.contains(number) {
            return .f(number)
        }
        return nil
    }

    /// The modifier with `name`, in any case.
    public static func modifier(named name: String) -> Modifier? {
        let lowered = name.lowercased()
        return modifierNames.first { $0.names.contains(lowered) }?.modifier
    }

    /// The canonical spelling ``init(spec:)`` reads back: modifiers in the
    /// order ctrl, alt, shift, then the key.
    public var description: String {
        let held: [Modifier] = Modifier.allCases.filter {
            switch $0 {
            case .ctrl: ctrl
            case .alt: alt
            case .shift: shift
            }
        }
        let modifiers = held.compactMap { modifier in
            Self.modifierNames.first { $0.modifier == modifier }?.names[0]
        }
        let keyName: String
        if let named = Self.namedKeys.first(where: { $0.key == key }) {
            keyName = named.names[0]
        } else if case .f(let number) = key {
            keyName = "F\(number)"
        } else if case .character(let character) = key {
            keyName = String(character)
        } else {
            keyName = "?"
        }
        return (modifiers + [keyName]).joined(separator: "+")
    }
}
