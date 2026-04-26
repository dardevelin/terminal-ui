/// Modifier that marks a view as focusable.
/// When focused, it renders with a focus ring and receives key events.
public struct FocusableModifier: ViewModifier {
    public typealias ModifierType = Bool
}

/// Modifier that groups focusable descendants into a named scope.
///
/// Arrow keys navigate within the scope — they won't move focus out of it.
/// Tab/Shift+Tab ignore scopes and traverse all focusables in document order,
/// which matches the SwiftUI convention (Tab = major sections, arrows = local).
public struct FocusScopeModifier: ViewModifier {
    public typealias ModifierType = String
    public let id: String
}

/// Modifier that attaches a key event handler to a view.
/// The handler is invoked when this view (or its focusable ancestor) is focused
/// and a key event is received.
public struct OnKeyPressModifier: ViewModifier {
    public typealias ModifierType = KeyEventResult
    public let handler: (KeyEvent) -> KeyEventResult
}

/// Modifier that attaches a click handler to a view.
/// Receives coordinates relative to the view's rect origin.
public struct OnClickModifier: ViewModifier {
    public typealias ModifierType = Void
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
    public let handler: (_ isHovering: Bool) -> Void
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
}
