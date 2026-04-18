/// Environment values propagated down the view tree.
/// Views read values with @TerminalEnvironment, parents set them with .environment().
///
/// Usage:
/// ```
/// struct MyView: TerminalView {
///     @TerminalEnvironment(\.theme) var theme
///     var body: some TerminalView {
///         Text("hello").foreground(theme.accent)
///     }
/// }
///
/// // Set from parent:
/// MyView().environment(\.theme, CustomTheme())
/// ```

/// Storage for all environment values — passed down during rendering.
public struct EnvironmentValues: Sendable {
    public var theme: any Theme = DefaultTheme()
    public var terminalSize: TerminalSize = .default
    public var colorSupport: ColorSupport = .trueColor
    public var isFocused: Bool = false
    public var focusedID: NodeID? = nil
    /// Keyboard-focus indicator style (HYP-91). Default `.overlay` preserves
    /// pre-HYP-91 visuals (cyan `▎` bar at `rect.x - 1`). Set via
    /// `.focusIndicator(_:)` on any view to override app-wide or per subtree.
    public var focusIndicatorStyle: FocusIndicatorStyle = .overlay
    /// Whether `ScrollView` paints its edge indicator glyphs (▲▼◀▶) when more
    /// content exists off-viewport. Default `.visible` — drop-in affordance.
    public var scrollIndicators: ScrollIndicatorVisibility = .visible
    /// How text-input components react to boundary hits (cursor at start/end,
    /// maxLength reached). Default `.bounce` — visible cursor animation.
    /// Scaffolding exists; per-component wiring lands incrementally.
    public var boundaryFeedback: BoundaryFeedback = .bounce
    /// Text overflow behavior for enclosed `Text` primitives. Default `.wrap`
    /// keeps long logical rows flowing to additional display rows; `.none`
    /// clips each row and counts only explicit newlines in measurement.
    /// Used by `DotMatrixText`, `MorseTicker`, and other fixed-geometry views
    /// to prevent measurement-driven height inflation at narrow widths.
    public var textWrap: TextWrapMode = .wrap

    public init() {}
}

/// Property wrapper to read environment values.
@propertyWrapper
public struct TerminalEnvironment<Value> {
    private let keyPath: KeyPath<EnvironmentValues, Value>

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value {
        let env = GraphContext.currentEnvironment ?? EnvironmentValues()
        return env[keyPath: keyPath]
    }
}

/// Marker protocol that hides `EnvironmentModifier<Value>`'s generic parameter
/// so the graph layer can pattern-match on it without knowing `Value`. The
/// `apply` method is the only thing the renderer needs — mutate an in-flight
/// `EnvironmentValues` so descendants observe the new value.
public protocol _AnyEnvironmentModifier {
    func apply(to env: inout EnvironmentValues)
}

/// Modifier that sets an environment value for a subtree.
public struct EnvironmentModifier<Value>: ViewModifier, _AnyEnvironmentModifier {
    public typealias ModifierType = Value
    public let keyPath: WritableKeyPath<EnvironmentValues, Value>
    public let value: Value

    public func apply(to env: inout EnvironmentValues) {
        env[keyPath: keyPath] = value
    }
}

extension TerminalView {
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> ModifiedView<Self, EnvironmentModifier<V>> {
        ModifiedView(content: self, modifier: EnvironmentModifier(keyPath: keyPath, value: value))
    }
}
