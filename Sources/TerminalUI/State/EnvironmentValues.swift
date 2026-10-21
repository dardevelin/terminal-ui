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
///
/// One value flows down the tree per frame: `.environment(_:_:)` copies it,
/// rewrites one key path, and binds the copy for its subtree only, so an
/// override never leaks to siblings and the nearest ancestor's setting wins.
/// Every property carries a default, which makes a read with no ancestor
/// override always well-defined — including reads that happen before the
/// first render, when no environment is bound yet and ``TerminalEnvironment``
/// falls back to a default-initialized value.
///
/// Views read single values with ``TerminalEnvironment``; most properties
/// also have a named convenience modifier (`.focusIndicator(_:)`,
/// `.pasteMode(_:)`, …) that wraps the raw `.environment` call.
public struct EnvironmentValues: Sendable {
    /// Color and glyph palette the framework's components draw with.
    /// Override per subtree via `.environment(\.theme, ...)`.
    public var theme: any Theme = DefaultTheme()
    /// Terminal dimensions in cells, restamped by the runtime on resize.
    public var terminalSize: TerminalSize = .default
    /// Color depth output is encoded at. Defaults to `.trueColor`; the
    /// runtime lowers it to what the terminal reports so styles degrade
    /// instead of emitting unsupported SGR sequences.
    public var colorSupport: ColorSupport = .trueColor
    /// Whether the nearest focusable view above this one holds keyboard
    /// focus — as SwiftUI's `isFocused`. Put `.focusable()` on a view and its
    /// body reads whether it is focused:
    ///
    /// ```swift
    /// struct Field: TerminalView {
    ///     @TerminalEnvironment(\.isFocused) var isFocused
    ///     var body: some TerminalView { Text(isFocused ? "> name" : "  name") }
    /// }
    ///
    /// Field().focusable()
    /// ```
    ///
    /// Only bodies that read it run again when focus moves.
    public var isFocused: Bool = false
    /// Node currently holding keyboard focus, or nil when nothing does —
    /// the environment's read-only mirror of `FocusEngine.keyboardFocusID`,
    /// bound by the runtime for every frame.
    public var focusedID: NodeID? = nil
    /// Keyboard-focus indicator style. Default `.overlay` preserves
    /// pre-visuals (cyan `▎` bar at `rect.x - 1`). Set via
    /// `.focusIndicator(_:)` on any view to override app-wide or per subtree.
    public var focusIndicatorStyle: FocusIndicatorStyle = .overlay
    /// Whether `ScrollView` paints its edge indicator glyphs (▲▼◀▶) when more
    /// content exists off-viewport. Default `.visible` — drop-in affordance.
    public var scrollIndicators: ScrollIndicatorVisibility = .visible
    /// Glyphs `ScrollView` draws its scrollbar with. Default `.thin`. Set via
    /// `.scrollbarStyle(_:)`; colour comes from ``theme``.
    public var scrollbarStyle: ScrollbarStyle = .thin
    /// Where enclosed `ScrollView`s open, and what they keep in view as their
    /// content changes size. Default `nil` opens at the start and leaves the
    /// offset alone. Set via `.defaultScrollAnchor(_:)`.
    public var scrollAnchor: Alignment? = nil
    /// Lexers by language name, for every view that is handed a language.
    /// Extend with `.syntaxHighlighter(_:for:)`; Swift is registered as
    /// standard.
    public var syntaxHighlighters: SyntaxHighlighters = .standard
    /// How enclosed `MarkdownView`s draw each element. Default: an empty
    /// style, which draws everything from the theme. Set via
    /// `.markdownStyle(_:)`.
    public var markdownStyle: MarkdownStyle = MarkdownStyle()

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
    /// What `PromptInput` draws at the start of each row, or nil for its own
    /// `prompt` glyph. Set via `.promptPrefix(_:)`.
    public var promptPrefix: PromptPrefix? = nil

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

    /// Whether focus on this subtree is a reading position rather than an
    /// operable one — a version string, a gauge, any row a settings screen
    /// shows and does not let you change.
    ///
    /// Such a row is still somewhere the arrow cursor goes, because it is a
    /// row and a walk that stopped short of it would leave the user staring at
    /// content the cursor refuses to reach. It is not somewhere Tab goes: Tab
    /// moves between things you can operate, and a stop where Enter does
    /// nothing is worse than no stop. Distinct from `isEnabled`, which means
    /// "switched off" and leaves focus out of both.
    public var focusIsReadOnly: Bool = false

    /// What the directional focus engine does when arrow navigation hits a
    /// container's edge with no neighbour on the requested axis.
    ///
    /// `nil` means the user has expressed no preference, in which case the
    /// container's own `traversalGeometry` decides: splits escape to the
    /// parent, stacks hold focus. Optional rather than a concrete default so
    /// those two intrinsic behaviours stay distinguishable from someone
    /// explicitly asking for `.escapeToParent` everywhere.
    /// Override via `.focusBoundaryPolicy(_:)`.
    public var focusBoundaryPolicy: FocusBoundaryPolicy?

    /// How thoroughly a container's panes participate in focus when they have
    /// no focusable descendants.
    ///
    /// `nil` means the user has expressed no preference, in which case the
    /// container decides: pane-bearing containers treat each pane as a focus
    /// unit, ordinary stacks do not. Optional for the same reason as
    /// `focusBoundaryPolicy` above — a concrete default would be
    /// indistinguishable from someone explicitly asking for it, and the two
    /// need different answers per container.
    /// Override via `.focusGranularity(_:)`.
    public var focusGranularity: FocusGranularity?

    /// Currently-active mode stack for context-scoped key bindings.
    /// Bindings carrying a `whenContext:` / `whenContextContains:`
    /// requirement only fire when this stack satisfies the predicate.
    /// Empty stack = the "default" context (no requirements).
    /// HYP-327. Mutate via `actionContext.push(...)` from inside an
    /// action's `perform` closure or via `.environment(\.actionContext, ...)`
    /// at the view level.
    public var actionContext: ActionContext = ActionContext()

    /// How keyboard-chord labels render across the framework. Default
    /// `.automatic` picks platform-native: macOS → Apple symbols
    /// (`⌥R`), others → spelled-out names (`Alt+R`). Override per
    /// subtree with `.modifierLabelStyle(_:)`.
    public var modifierLabelStyle: ModifierLabelStyle = .automatic

    /// How `Picker` presents its options. Default `.inline` is the style that
    /// needs neither an overlay nor a width budget, so it renders correctly in
    /// any container. Override per subtree with `.pickerStyle(_:)`.
    public var pickerStyle: PickerStyle = .inline

    /// Width of the shared label column, published by an enclosing `Form`.
    /// `nil` means "not inside a Form" — controls render their label unpadded,
    /// which is both the pre-Form behaviour and the right one for a control
    /// sitting in a plain stack.
    public var formLabelWidth: Int? = nil

    /// True when a form row should stack its label above its control because
    /// the terminal is too narrow to place them side by side.
    public var formStacksRows: Bool = false

    /// Whether a rendered section already precedes this one. Sibling sections
    /// cannot otherwise tell which of them is first, so the enclosing `Form`
    /// stamps this and `_SectionSeparator` reads it to suppress the leading
    /// rule. A boolean rather than an ordinal because that is all the decision
    /// needs, and it stays correct for sections nested in a `ForEach`.
    public var formSectionIsPreceded: Bool = false

    /// How a `NavigationLink` pushes its value. Installed by the enclosing
    /// `NavigationStack`; nil when a link is used with no stack in scope, so
    /// activating it is a no-op rather than a crash.
    public var navigationPush: NavigationPushAction? = nil

    /// Screens a `NavigationStack` can push, keyed by value type. Published by
    /// `.navigationDestination(for:)` and read by the enclosing stack, so a
    /// registration written on the stack itself reaches it.
    public var navigationDestinations = NavigationDestinations()

    /// Creates the default environment — every value at its documented
    /// default, as seen by a view with no `.environment` ancestors.
    public init() {}
}

/// Property wrapper to read environment values.
///
/// Resolves its key path against `GraphContext.currentEnvironment` at read
/// time, so the value reflects every `.environment(_:_:)` override between
/// the root and the view whose body is evaluating:
///
/// ```swift
/// @TerminalEnvironment(\.theme) var theme
/// ```
///
/// Outside body evaluation — event handlers, or any read before the first
/// render — no environment is bound and reads fall back to the defaults of
/// ``EnvironmentValues``. Read the wrapper in `body` and capture the result
/// into a closure when a handler needs the resolved value.
@propertyWrapper
public struct TerminalEnvironment<Value> {
    private let keyPath: KeyPath<EnvironmentValues, Value>

    /// Creates a reader for the single environment value at `keyPath`.
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.keyPath = keyPath
    }

    /// The value at the key path, resolved from the environment bound to the
    /// current body evaluation — or from a default ``EnvironmentValues`` when
    /// none is bound (handlers, pre-render reads).
    public var wrappedValue: Value {
        let env = GraphContext.currentEnvironment ?? EnvironmentValues()
        let value = env[keyPath: keyPath]
        if let node = GraphContext.currentNode {
            let keyPath = keyPath
            node.environmentReads[keyPath] = { environment in
                AttributeGraph.sameEnvironmentValue(environment[keyPath: keyPath], value)
            }
        }
        return value
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
    /// The ``EnvironmentValues`` entry this modifier writes.
    public let keyPath: WritableKeyPath<EnvironmentValues, Value>
    /// The value descendants observe; an inner modifier for the same key
    /// path shadows it.
    public let value: Value

    /// Writes ``value`` at ``keyPath`` into the in-flight environment.
    public func apply(to env: inout EnvironmentValues) {
        env[keyPath: keyPath] = value
    }
}

/// Modifier that edits an inherited environment value for a subtree.
public struct TransformEnvironmentModifier<Value>: ViewModifier, _AnyEnvironmentModifier {
    public typealias ModifierType = Value
    /// The ``EnvironmentValues`` entry this modifier edits.
    public let keyPath: WritableKeyPath<EnvironmentValues, Value>
    /// Receives the value the subtree would otherwise inherit, and edits it
    /// in place.
    public let transform: (inout Value) -> Void

    /// Runs ``transform`` on the in-flight value at ``keyPath``.
    public func apply(to env: inout EnvironmentValues) {
        transform(&env[keyPath: keyPath])
    }
}

extension TerminalView {
    /// Set an ``EnvironmentValues`` entry for this view and every
    /// descendant. Descendants read it via `@Environment(\.keyPath)`; a
    /// nested `.environment` for the same key path shadows this one for its
    /// own subtree (innermost wins), exactly like SwiftUI.
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> ModifiedView<Self, EnvironmentModifier<V>> {
        ModifiedView(content: self, modifier: EnvironmentModifier(keyPath: keyPath, value: value))
    }

    /// Edit an ``EnvironmentValues`` entry for this view and every descendant,
    /// starting from the value it would otherwise inherit. Where
    /// `.environment` replaces, this adds — registering one more lexer
    /// without discarding the ones already there. SwiftUI parity:
    /// `View.transformEnvironment(_:transform:)`.
    public func transformEnvironment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>,
                                        transform: @escaping (inout V) -> Void)
        -> ModifiedView<Self, TransformEnvironmentModifier<V>> {
        ModifiedView(content: self, modifier: TransformEnvironmentModifier(keyPath: keyPath, transform: transform))
    }
}
