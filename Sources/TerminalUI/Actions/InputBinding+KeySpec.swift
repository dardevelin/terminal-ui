import TerminalUIConfig

/// Why a key spec could not be read — see ``InputBinding/init(keySpec:)``.
public typealias KeySpecError = TerminalUIConfig.KeySpecError

extension Key {
    /// The key a `KeyCombo` names.
    init(_ name: KeyCombo.KeyName) {
        switch name {
        case .character(let character): self = .character(character)
        case .f(let number): self = .f(number)
        case .enter: self = .enter
        case .tab: self = .tab
        case .escape: self = .escape
        case .backspace: self = .backspace
        case .delete: self = .delete
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .home: self = .home
        case .end: self = .end
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        }
    }

    /// The `KeyCombo` name for this key; nil for a key it has no name for.
    var comboName: KeyCombo.KeyName? {
        switch self {
        case .character(let character): .character(character)
        case .f(let number): .f(number)
        case .enter: .enter
        case .tab: .tab
        case .escape: .escape
        case .backspace: .backspace
        case .delete: .delete
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        default: nil
        }
    }
}

extension KeyModifiers {
    init(_ combo: KeyCombo) {
        self = []
        if combo.ctrl { insert(.ctrl) }
        if combo.alt { insert(.alt) }
        if combo.shift { insert(.shift) }
    }

    init(_ modifier: KeyCombo.Modifier) {
        switch modifier {
        case .ctrl: self = .ctrl
        case .alt: self = .alt
        case .shift: self = .shift
        }
    }
}

extension InputBinding {
    /// The chord a `KeyCombo` describes.
    init(_ combo: KeyCombo) {
        self = .keyboard(Key(combo.key), KeyModifiers(combo))
    }

    /// A keyboard chord written as a person writes it — modifiers and a key
    /// joined by `+`, in any case and order: `ctrl+k`, `alt+backspace`,
    /// `shift+enter`, `ctrl+shift+z`, `pagedown`, `F5`, `alt+<`. The same
    /// spelling as the debug keybindings and `swtui bind`; see `KeyCombo`.
    public init(keySpec: String) throws(KeySpecError) {
        self.init(try KeyCombo(spec: keySpec))
    }

    /// The chord as ``init(keySpec:)`` reads it; nil for a binding that is
    /// not a keyboard chord.
    public var keySpec: String? {
        guard case .keyboard(let key, let modifiers) = self, let name = key.comboName else { return nil }
        return KeyCombo(key: name, ctrl: modifiers.contains(.ctrl), alt: modifiers.contains(.alt),
                        shift: modifiers.contains(.shift)).description
    }
}
