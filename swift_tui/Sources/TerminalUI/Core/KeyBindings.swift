/// Semantic actions that key events can trigger.
/// Framework-level and developer-level actions share the same system.
public enum KeyAction: Hashable, Sendable {
    // Framework debug actions
    case toggleDebugOverlay
    case toggleDebugPanel
    case toggleInspector
    case inspectorUp
    case inspectorDown
    case inspectorLeft
    case inspectorRight

    // Developer actions
    case custom(String)
}

/// Maps key events to semantic actions.
/// Framework registers default bindings. Developer can override or add.
public final class KeyBindings {
    private var bindings: [(key: Key, modifiers: KeyModifiers, action: KeyAction)] = []

    public init() {
        registerDefaults()
    }

    func registerDefaults() {
        // Debug tools — using ctrl+letter combos that don't collide with common terminal keys
        bind(.character("d"), modifiers: .ctrl, to: .toggleDebugOverlay)
        bind(.character("f"), modifiers: .ctrl, to: .toggleDebugPanel)
        // ctrl+g for inspector (ctrl+i = tab, can't use)
        bind(.character("g"), modifiers: .ctrl, to: .toggleInspector)
    }

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
