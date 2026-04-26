/// A way to invoke an `Action`. Bindings are device-side: keyboard
/// chord, mouse click, gesture, voice prompt, accessibility rotor item.
/// One action graph, multiple binding tables — every binding fires the
/// same handler, every readout (help, menu, screen reader, voice prompt
/// list) reads the same action graph.
///
/// Bindings are `Hashable` so dispatchers can use them as dictionary
/// keys: `[InputBinding: ActionID]` is the lookup shape inside an
/// `ActionScope`. Adding a new input modality is one new case here +
/// one new dispatcher; existing actions and readout consumers don't
/// change.
public enum InputBinding: Sendable, Hashable {
    /// Keyboard chord: a key plus zero or more modifier flags.
    case keyboard(Key, KeyModifiers)

    /// Mouse click: button plus modifiers held at click time. Position
    /// is determined at hit-test time, not at binding declaration.
    case mouse(MouseButton, KeyModifiers)

    /// Touchpad / mouse-shape gesture. Identifier is opaque — a string
    /// the gesture recognizer reports when matched.
    case gesture(GestureID)

    /// Voice prompt — the spoken phrase that fires the action when the
    /// terminal-side voice recognizer matches.
    case voice(String)

    /// Accessibility label — the string a screen reader announces and
    /// the rotor uses to list the action. Distinct from the action's
    /// title because some actions need a longer announcement than
    /// fits in a menu.
    case accessibility(String)
}

/// Opaque identifier for a recognized gesture. Wraps a string so the
/// gesture recognizer's vocabulary is data-driven; future cases can
/// add typed gesture descriptors without breaking source.
public struct GestureID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: StringLiteralType) { self.raw = value }
}

/// Pairs an `Action` with one `InputBinding`. The framework's binding
/// tables hold `BoundAction` values keyed by binding so a chord lookup
/// returns the action to fire. Multiple `BoundAction`s can carry the
/// same action (one action, many bindings).
public struct BoundAction: Sendable {
    public let action: Action
    public let binding: InputBinding

    public init(action: Action, binding: InputBinding) {
        self.action = action
        self.binding = binding
    }
}

extension Action {
    /// Pair this action with a binding. Returns a `BoundAction` the
    /// framework's dispatcher can register in its binding table.
    public func bound(to binding: InputBinding) -> BoundAction {
        BoundAction(action: self, binding: binding)
    }
}
