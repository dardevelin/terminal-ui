// HYP-333 — Mac-native modifier symbol rendering.
//
// `KeyChord` pairs a `Key` with a `KeyModifiers` set and renders both
// in either Apple's symbol convention (`⌥R`, `⌃⇧⇥`) or the Linux/Windows
// spelled-out style (`Alt+R`, `Ctrl+Shift+Tab`). Default behaviour is
// platform-native: macOS apps render symbolic, others render named.
//
// Apple uses `⌥` (Option) for the same physical key Linux calls Alt;
// our `KeyModifiers.alt` covers both. The label rendering is purely a
// display concern — the underlying parser always produces `.alt`
// regardless of platform.
//
// Compile-time platform branch (`#if os(macOS)`) per the framework's
// "no runtime platform checks" rule (memory: feedback_conditional_compilation.md).

/// User-visible representation of a keyboard chord — the key plus any
/// modifiers held with it. Used by every place the framework needs to
/// display a chord: storybook code snippets, future help overlay,
/// command palette listings, action cheat-sheets.
public struct KeyChord: Sendable, Hashable {
    public let key: Key
    public let modifiers: KeyModifiers

    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Render this chord using `style`. Pass `.automatic` (or omit
    /// the argument) to follow the platform convention.
    public func formatted(_ style: ModifierLabelStyle = .automatic) -> String {
        let resolved = ModifierLabelStyle.resolve(style)
        return Self.render(key: key, modifiers: modifiers, style: resolved)
    }

    /// Render this chord, reading `EnvironmentValues.modifierLabelStyle`
    /// from `env`. Convenience for views that already hold an env;
    /// equivalent to `formatted(env.modifierLabelStyle)`.
    public func formatted(in env: EnvironmentValues) -> String {
        formatted(env.modifierLabelStyle)
    }

    // MARK: - Rendering

    private static func render(
        key: Key,
        modifiers: KeyModifiers,
        style: ModifierLabelStyle
    ) -> String {
        // `.automatic` should have been resolved by callers; if the
        // raw value reaches here treat it as named (safe default).
        let renderStyle: ModifierLabelStyle = (style == .automatic) ? .named : style

        let modifierString = renderModifiers(modifiers, style: renderStyle)
        let keyString = renderKey(key, style: renderStyle)
        let separator = (renderStyle == .symbolic) ? "" : (modifierString.isEmpty ? "" : "+")

        if modifierString.isEmpty {
            return keyString
        }
        return modifierString + separator + keyString
    }

    private static func renderModifiers(_ modifiers: KeyModifiers, style: ModifierLabelStyle) -> String {
        // Order matters for visual consistency. Apple's convention:
        // ctrl, option, shift, command (left to right). Without command
        // today, the order is ctrl, alt(option), shift.
        var parts: [String] = []
        if modifiers.contains(.ctrl) {
            parts.append(style == .symbolic ? "⌃" : "Ctrl")
        }
        if modifiers.contains(.alt) {
            parts.append(style == .symbolic ? "⌥" : "Alt")
        }
        if modifiers.contains(.shift) {
            parts.append(style == .symbolic ? "⇧" : "Shift")
        }
        return parts.joined(separator: style == .symbolic ? "" : "+")
    }

    private static func renderKey(_ key: Key, style: ModifierLabelStyle) -> String {
        switch key {
        case .character(let c):
            return String(c).uppercased()
        case .enter:
            return style == .symbolic ? "↵" : "Enter"
        case .tab:
            return style == .symbolic ? "⇥" : "Tab"
        case .escape:
            return style == .symbolic ? "⎋" : "Esc"
        case .backspace:
            return style == .symbolic ? "⌫" : "Backspace"
        case .delete:
            return style == .symbolic ? "⌦" : "Delete"
        case .up:    return "↑"
        case .down:  return "↓"
        case .left:  return "←"
        case .right: return "→"
        case .home:
            return style == .symbolic ? "↖" : "Home"
        case .end:
            return style == .symbolic ? "↘" : "End"
        case .pageUp:
            return style == .symbolic ? "⇞" : "PageUp"
        case .pageDown:
            return style == .symbolic ? "⇟" : "PageDown"
        case .f(let n):
            return "F\(n)"
        case .activate:
            // Synthesized key — not a physical chord; render as
            // "Activate" in both styles since there is no Apple-symbol
            // convention for it.
            return "Activate"
        case .unknown:
            return "?"
        }
    }
}

/// How `KeyChord.formatted(_:)` renders modifier names. Default is
/// `.automatic` which picks platform-native: `.symbolic` on macOS
/// (`⌥R`), `.named` everywhere else (`Alt+R`).
public enum ModifierLabelStyle: Sendable, Equatable {
    /// Platform-native default. macOS → `.symbolic`, others → `.named`.
    case automatic
    /// Apple-style symbols, no separator: `⌥R`, `⌃⇧⇥`, `⌘P`.
    case symbolic
    /// Spelled-out names, `+` separator: `Alt+R`, `Ctrl+Shift+Tab`.
    case named

    /// Resolve `.automatic` to a concrete style by reading the
    /// platform at compile time. `.symbolic` and `.named` pass through.
    static func resolve(_ style: ModifierLabelStyle) -> ModifierLabelStyle {
        switch style {
        case .automatic:
            #if os(macOS)
            return .symbolic
            #else
            return .named
            #endif
        case .symbolic, .named:
            return style
        }
    }
}

extension TerminalView {
    /// Override the modifier-label style for this subtree. Descendants
    /// rendering chord labels via `KeyChord.formatted(in:)` will read
    /// the new value from the environment. HYP-333.
    public func modifierLabelStyle(_ style: ModifierLabelStyle)
        -> ModifiedView<Self, EnvironmentModifier<ModifierLabelStyle>> {
        environment(\.modifierLabelStyle, style)
    }
}
