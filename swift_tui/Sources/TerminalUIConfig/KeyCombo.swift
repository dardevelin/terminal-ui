/// Parsed key combination from a TOML string like "F1", "ctrl+d", "ctrl+shift+F2".
/// Framework-agnostic — the TerminalUI layer maps this to Key + KeyModifiers.
public struct KeyCombo: Sendable, Equatable {
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

    /// Parse a key string like "F1", "ctrl+d", "ctrl+shift+F2", "alt+enter".
    /// Returns nil if the string can't be parsed.
    public static func parse(_ string: String) -> KeyCombo? {
        let parts = string.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !parts.isEmpty else { return nil }

        var ctrl = false
        var alt = false
        var shift = false

        // All parts except the last are modifiers
        for modifier in parts.dropLast() {
            switch modifier {
            case "ctrl", "control": ctrl = true
            case "alt", "opt", "option": alt = true
            case "shift": shift = true
            default: return nil
            }
        }

        // Last part is the key
        guard let keyPart = parts.last else { return nil }

        let keyName: KeyName
        if keyPart.hasPrefix("f"), keyPart.count >= 2, keyPart.count <= 3,
           let n = Int(keyPart.dropFirst()), n >= 1, n <= 24 {
            keyName = .f(n)
        } else {
            switch keyPart {
            case "enter", "return": keyName = .enter
            case "tab": keyName = .tab
            case "esc", "escape": keyName = .escape
            case "backspace", "bs": keyName = .backspace
            case "delete", "del": keyName = .delete
            case "up": keyName = .up
            case "down": keyName = .down
            case "left": keyName = .left
            case "right": keyName = .right
            case "home": keyName = .home
            case "end": keyName = .end
            case "pageup", "pgup": keyName = .pageUp
            case "pagedown", "pgdn": keyName = .pageDown
            default:
                // Single character
                if keyPart.count == 1, let ch = keyPart.first {
                    keyName = .character(ch)
                } else {
                    return nil
                }
            }
        }

        return KeyCombo(key: keyName, ctrl: ctrl, alt: alt, shift: shift)
    }

    /// Serialize back to a string for display and TOML writing.
    public var description: String {
        var parts: [String] = []
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if shift { parts.append("shift") }

        switch key {
        case .character(let c): parts.append(String(c))
        case .f(let n): parts.append("F\(n)")
        case .enter: parts.append("enter")
        case .tab: parts.append("tab")
        case .escape: parts.append("escape")
        case .backspace: parts.append("backspace")
        case .delete: parts.append("delete")
        case .up: parts.append("up")
        case .down: parts.append("down")
        case .left: parts.append("left")
        case .right: parts.append("right")
        case .home: parts.append("home")
        case .end: parts.append("end")
        case .pageUp: parts.append("pageup")
        case .pageDown: parts.append("pagedown")
        }

        return parts.joined(separator: "+")
    }
}
