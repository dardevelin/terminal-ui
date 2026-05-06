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
    /// Keyboard-focus indicator style. Default `.overlay` preserves
    /// pre-visuals (cyan `▎` bar at `rect.x - 1`). Set via
    /// `.focusIndicator(_:)` on any view to override app-wide or per subtree.
    public var focusIndicatorStyle: FocusIndicatorStyle = .overlay
    /// Whether `ScrollView` paints its edge indicator glyphs (▲▼◀▶) when more
    /// content exists off-viewport. Default `.visible` — drop-in affordance.
    public var scrollIndicators: ScrollIndicatorVisibility = .visible

    /// Explicit scroll target for the nearest enclosing `ScrollView`.
    /// Set via `.scrollPosition(id:)`; the renderer locates the descendant
    /// tagged with `.id(matching)` and adjusts the ScrollView's offset to
    /// keep that node visible — independent of keyboard focus. Default
    /// `nil` keeps the existing focus-driven behaviour.
    /// SwiftUI parity: `View.scrollPosition(id:)` (iOS 17+).
    public var scrollTargetID: ScrollTargetID? = nil

    /// How `PromptInput` presents pasted content. Default
    /// `.placeholder(lines: 2, chars: 200)` mirrors Claude Code:
    /// pastes with a newline OR over 200 chars collapse to a marker.
    /// Override via `.pasteMode(.inline)` or `.pasteMode(.alwaysPlaceholder)`.
    public var pasteMode: PasteMode = .claudeCode

    /// Whether the "paste again to expand" auto-hint row is visible
    /// beneath the prompt when the cursor is adjacent to a collapsed
    /// reference. Override via `.pasteHint(.hidden)`.
    public var pasteHint: PasteHintVisibility = .visible

    /// Translation seam for `PromptInput`'s marker + hint strings.
    /// Default ships English; override per subtree via
    /// `.promptInputLocalizer(_:)` for other languages or custom
    /// marker shapes. Stored as `any PromptInputLocalizer` so
    /// callers can plug in their own conforming type.
    public var promptInputLocalizer: any PromptInputLocalizer = DefaultPromptInputLocalizer()
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
    /// Whether arrow keys are allowed to move keyboard focus between views
    /// when the focused view didn't handle them. Default `false` — only
    /// Tab / Shift+Tab move focus, arrows stay within the focused view.
    /// Set `.true` on a subtree that wants SwiftUI-style 2D navigation.
    public var allowArrowFocusNavigation: Bool = false

    /// How TextInput-class views handle text that exceeds the field's
    /// width. Default `.byClipping` matches Apple HIG's prescription
    /// for single-line text fields: "System clips text extending
    /// beyond field bounds." Apps wanting non-default break behaviour
    /// (`.byCharWrapping`, `.byWordWrapping`, truncation) override
    /// via `.lineBreakMode(_:)` on any ancestor. See `LineBreakMode`.
    public var lineBreakMode: LineBreakMode = .byClipping

    /// How mouse events interact with keyboard focus and routing.
    /// Default `.clickToLock`: hover does not move keyboard focus,
    /// click promotes, wheel routes to the hover-target focusable.
    /// See `MouseFocusPolicy`.
    public var mouseFocusPolicy: MouseFocusPolicy = .clickToLock

    /// Whether the framework SHOULD allow this subtree to write cells
    /// outside its assigned rect without emitting a `componentOverflow`
    /// framework warning. Default `false` — overflow warns. Subtrees
    /// where escape is intentional (shadows, popovers, edge-to-edge
    /// banners) opt in via `.overflowOK()`. Reads inherit through the
    /// env chain so a parent's opt-in covers its descendants.
    public var overflowAllowed: Bool = false

    /// Callback registered via `.onBoundaryHit { reason in ... }`.
    /// Invoked by `BoundaryFeedbackEmitter` when the active
    /// `boundaryFeedback` mode is `.modal` and an input component
    /// hits a wall. Nil = no callback registered (modal mode is
    /// silent in that case, same as `.none`).
    public var onBoundaryHit: BoundaryHitCallback? = nil

    /// Whether interactive subtrees are live. Default `true`.
    /// `.disabled(_)` writes `false`, which gates handler registration
    /// (`onKeyPress` / `onClick` / `onHover`) and removes focusables
    /// from Tab order. SwiftUI parity: most-restrictive wins —
    /// a descendant cannot re-enable a subtree disabled higher up,
    /// see `DisabledModifier.apply`.
    public var isEnabled: Bool = true

    /// What the directional focus engine does when arrow navigation
    /// hits a container's edge with no neighbor on the requested
    /// axis. Default `.escapeToParent` — i3 convention.
    /// HYP-326. Override via `.focusBoundaryPolicy(_:)`.
    public var focusBoundaryPolicy: FocusBoundaryPolicy = .escapeToParent

    /// How thoroughly a container's panes participate in focus when
    /// they have no focusable descendants. Default `.container` —
    /// SwiftUI list-row pattern (rows focusable as units).
    /// HYP-326. Override via `.focusGranularity(_:)`.
    public var focusGranularity: FocusGranularity = .container

    /// Currently-active mode stack for context-scoped key bindings.
    /// Bindings carrying a `whenContext:` / `whenContextContains:`
    /// requirement only fire when this stack satisfies the predicate.
    /// Empty stack = the "default" context (no requirements).
    /// HYP-327. Mutate via `actionContext.push(...)` from inside an
    /// action's `perform` closure or via `.environment(\.actionContext, ...)`
    /// at the view level.
    public var actionContext: ActionContext = ActionContext()

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
