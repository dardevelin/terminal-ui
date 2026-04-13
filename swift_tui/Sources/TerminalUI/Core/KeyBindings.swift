import TerminalUIConfig

/// Semantic actions that key events can trigger.
/// Framework-level and developer-level actions share the same system.
public enum KeyAction: Hashable, Sendable {
    // Framework debug actions
    case toggleDebugOverlay
    case toggleDebugPanel
    case toggleInspector
    case captureFrame
    case inspectorUp
    case inspectorDown
    case inspectorLeft
    case inspectorRight

    // Developer actions
    case custom(String)

    /// Map from TOML action name to KeyAction.
    static func fromConfigName(_ name: String) -> KeyAction? {
        switch name {
        case "toggle_debug_overlay": return .toggleDebugOverlay
        case "toggle_debug_panel": return .toggleDebugPanel
        case "toggle_inspector": return .toggleInspector
        case "capture_frame": return .captureFrame
        default: return nil
        }
    }

    /// Map from KeyAction to TOML config name.
    var configName: String? {
        switch self {
        case .toggleDebugOverlay: return "toggle_debug_overlay"
        case .toggleDebugPanel: return "toggle_debug_panel"
        case .toggleInspector: return "toggle_inspector"
        case .captureFrame: return "capture_frame"
        default: return nil
        }
    }
}

/// Maps key events to semantic actions.
/// Reads defaults from DiagConfig keybindings (F-keys), overridable via terminalui.toml.
public final class KeyBindings {
    private var bindings: [(key: Key, modifiers: KeyModifiers, action: KeyAction)] = []

    public init() {
        #if DEBUG
        let config = DiagPaths.loadConfig()
        registerFromConfig(config.keybindings)
        #endif
    }

    #if DEBUG
    /// Register bindings from config keybinding map (action name → key string).
    func registerFromConfig(_ keybindings: [String: String]) {
        for (actionName, keyString) in keybindings {
            guard let action = KeyAction.fromConfigName(actionName),
                  let combo = KeyCombo.parse(keyString) else { continue }

            let (key, mods) = comboToKeyAndModifiers(combo)
            bind(key, modifiers: mods, to: action)
        }
    }

    /// Convert a KeyCombo (from TerminalUIConfig) to the framework's Key + KeyModifiers.
    private func comboToKeyAndModifiers(_ combo: KeyCombo) -> (Key, KeyModifiers) {
        let key: Key
        switch combo.key {
        case .character(let c): key = .character(c)
        case .f(let n): key = .f(n)
        case .enter: key = .enter
        case .tab: key = .tab
        case .escape: key = .escape
        case .backspace: key = .backspace
        case .delete: key = .delete
        case .up: key = .up
        case .down: key = .down
        case .left: key = .left
        case .right: key = .right
        case .home: key = .home
        case .end: key = .end
        case .pageUp: key = .pageUp
        case .pageDown: key = .pageDown
        }

        var mods: KeyModifiers = []
        if combo.ctrl { mods.insert(.ctrl) }
        if combo.alt { mods.insert(.alt) }
        if combo.shift { mods.insert(.shift) }

        return (key, mods)
    }
    #endif

    public func bind(_ key: Key, modifiers: KeyModifiers = [], to action: KeyAction) {
        // Remove existing binding for this action
        bindings.removeAll { $0.action == action }
        bindings.append((key: key, modifiers: modifiers, action: action))
    }

    /// Look up which action a key event maps to, if any.
    public func action(for event: KeyEvent) -> KeyAction? {
        for binding in bindings {
            if binding.key == event.key && binding.modifiers == event.modifiers {
                return binding.action
            }
        }

        // Inspector arrow keys when inspector is active (handled dynamically)
        return nil
    }

    /// Check if a key event matches a specific action.
    public func matches(_ event: KeyEvent, action: KeyAction) -> Bool {
        self.action(for: event) == action
    }
}
