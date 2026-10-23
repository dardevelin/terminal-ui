/// Modifier that marks a view as focusable.
/// When focused, it renders with a focus ring and receives key events.
public struct FocusableModifier: ViewModifier {
    public typealias ModifierType = Bool
}

/// Payload of `.prefersDefaultFocus(_:)`: whether the subtree asks for focus
/// when nothing holds it.
public struct PrefersDefaultFocusModifier: ViewModifier {
    public typealias ModifierType = Bool
    /// Whether the subtree asks.
    public let prefers: Bool
}

/// Modifier that groups focusable descendants into a named scope.
///
/// Arrow keys navigate within the scope — they won't move focus out of it.
/// Tab/Shift+Tab ignore scopes and traverse all focusables in document order,
/// which matches the SwiftUI convention (Tab = major sections, arrows = local).
public struct FocusScopeModifier: ViewModifier {
    public typealias ModifierType = String
    /// The scope's name; arrow navigation stays inside members sharing
    /// it.
    public let id: String
}

/// Modifier that attaches a key event handler to a view.
/// The handler is invoked when this view (or its focusable ancestor) is focused
/// and a key event is received.
public struct OnKeyPressModifier: ViewModifier {
    public typealias ModifierType = KeyEventResult
    /// Receives key events first while focused; return `.handled` to
    /// consume, `.ignored` to let the event bubble.
    public let handler: (KeyEvent) -> KeyEventResult
}

/// Modifier that attaches a click handler to a view.
/// Receives coordinates relative to the view's rect origin.
public struct OnClickModifier: ViewModifier {
    public typealias ModifierType = Void
    /// Receives the click position in cells, relative to the view's own
    /// top-left corner.
    public let handler: (_ relativeX: Int, _ relativeY: Int) -> Void
}

/// Modifier that attaches a hover state callback to a view. The
/// closure fires with `true` when the cursor enters the view's rect
/// and `false` when it leaves. Movement that stays inside the rect
/// does not re-fire — only state transitions are reported, matching
/// SwiftUI's `.onHover { isHovering in … }` contract.
///
/// Fires under all `MouseFocusPolicy` cases including `.disabled`,
/// since the closure is the user-driven path that policy turns
/// framework auto-routing OFF for.
public struct OnHoverModifier: ViewModifier {
    public typealias ModifierType = Void
    /// Fires with `true` on cursor entry and `false` on exit — state
    /// transitions only, never per-move.
    public let handler: (_ isHovering: Bool) -> Void
}

/// Modifier that attaches a bracketed-paste handler to a view.
/// Fires when the keyboard-focused view (or an ancestor) receives a
/// paste payload — `ESC[200~ … ESC[201~` decoded by InputParser.
/// SwiftUI parity: `.onPaste { (payload: String) in ... }` — without
/// the type-filter form (`.onPaste(of:)`) since terminals only
/// transport text.
public struct OnPasteModifier: ViewModifier {
    public typealias ModifierType = Void
    /// Receives the full decoded paste payload, newlines included.
    public let handler: (_ payload: String) -> Void
}

// MARK: - View Extensions

extension TerminalView {
    /// Mark this view as focusable — it can receive focus via Tab/Shift+Tab
    /// and will show a focus ring when focused.
    public func focusable() -> ModifiedView<Self, FocusableModifier> {
        ModifiedView(content: self, modifier: FocusableModifier())
    }

    /// Attach a key event handler. When this view is focused (or its focusable
    /// ancestor is), key events are routed here first.
    public func onKeyPress(_ handler: @escaping (KeyEvent) -> KeyEventResult) -> ModifiedView<Self, OnKeyPressModifier> {
        ModifiedView(content: self, modifier: OnKeyPressModifier(handler: handler))
    }

    /// Attach a click handler. When this view is clicked, receives coordinates
    /// relative to the view's rect origin.
    public func onClick(_ handler: @escaping (_ relativeX: Int, _ relativeY: Int) -> Void) -> ModifiedView<Self, OnClickModifier> {
        ModifiedView(content: self, modifier: OnClickModifier(handler: handler))
    }

    /// Attach a hover-state callback. The closure receives `true` when
    /// the mouse cursor enters this view's rect and `false` when it
    /// leaves. Only state transitions fire — moving the cursor within
    /// an already-hovered rect does not re-invoke the handler.
    /// SwiftUI parity: `.onHover { isHovering in … }`.
    ///
    /// Composes with all four `MouseFocusPolicy` cases. Pairing with
    /// `.mouseFocusPolicy(.hoverFollows)` triggers a runtime warning
    /// (`FrameworkWarningCode.onHoverWithHoverFollows`) in DEBUG —
    /// the framework already moves keyboard focus on hover under that
    /// policy, so duplicating it with a callback is usually a sign
    /// the user wanted `.mouseFocusPolicy(.disabled)`. See
    /// `MouseFocusPolicy` for the full composition matrix.
    public func onHover(_ handler: @escaping (_ isHovering: Bool) -> Void) -> ModifiedView<Self, OnHoverModifier> {
        ModifiedView(content: self, modifier: OnHoverModifier(handler: handler))
    }

    /// Group focusable descendants into a named scope. Arrow-key
    /// navigation is clamped within the scope; Tab still crosses scopes.
    public func focusScope(_ id: String) -> ModifiedView<Self, FocusScopeModifier> {
        ModifiedView(content: self, modifier: FocusScopeModifier(id: id))
    }

    /// Ask for keyboard focus when nothing holds it — when the app opens,
    /// most of all. Without a preference that goes to the first focusable
    /// in Tab order; a chat whose transcript comes before its composer
    /// puts this on the composer, so typing works at once. On a container,
    /// the first focusable inside it is the one. Tab order is unchanged.
    ///
    /// SwiftUI parity: `View.prefersDefaultFocus(_:in:)`, with the whole app
    /// as the namespace.
    public func prefersDefaultFocus(_ prefersDefaultFocus: Bool = true)
        -> ModifiedView<Self, PrefersDefaultFocusModifier> {
        ModifiedView(content: self, modifier: PrefersDefaultFocusModifier(prefers: prefersDefaultFocus))
    }

    /// Choose whether this subtree's panes are focusable as units when they
    /// hold nothing focusable of their own.
    ///
    /// `.container` makes each pane a focus target — i3's "container without
    /// leaf widget" rule, and the SwiftUI convention that a list row is a
    /// focusable unit regardless of its content. `.leaf` restricts focus to
    /// descendants explicitly marked `.focusable()`.
    ///
    /// Unset, the container decides: `SplitView` panes are units, ordinary
    /// stacks are not.
    public func focusGranularity(
        _ granularity: FocusGranularity
    ) -> ModifiedView<Self, EnvironmentModifier<FocusGranularity?>> {
        environment(\.focusGranularity, granularity)
    }

    /// Choose what arrow navigation does at a container's edge when there is
    /// no neighbour in the requested direction.
    ///
    /// Unset, the container decides: a split escapes to its parent so an i3
    /// tree can be traversed edge to edge, while a stack holds focus.
    public func focusBoundaryPolicy(
        _ policy: FocusBoundaryPolicy
    ) -> ModifiedView<Self, EnvironmentModifier<FocusBoundaryPolicy?>> {
        environment(\.focusBoundaryPolicy, policy)
    }

    /// Receive bracketed-paste payloads delivered to the focused view.
    /// The handler fires with the full payload as a single string —
    /// embedded newlines preserved, payload bytes uninterpreted (that's
    /// the whole point of bracketed paste). Components decide their
    /// own per-paste semantics: TextInput strips newlines, TextArea
    /// splits on `\n` into rows, PromptInput inserts logical newlines.
    public func onPaste(_ handler: @escaping (_ payload: String) -> Void) -> ModifiedView<Self, OnPasteModifier> {
        ModifiedView(content: self, modifier: OnPasteModifier(handler: handler))
    }
}
