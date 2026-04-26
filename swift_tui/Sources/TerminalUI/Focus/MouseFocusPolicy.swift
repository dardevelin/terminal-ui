/// How mouse events interact with keyboard focus and routing. The
/// default `.clickToLock` matches the post-HYP-107 behaviour: hover
/// updates a separate hover-target without touching keyboard focus,
/// click promotes the hover target to keyboard focus, and the wheel
/// scrolls whatever is under the cursor.
///
/// Override per subtree (or app-wide) with `.mouseFocusPolicy(_:)`:
///
/// ```swift
/// MyEditor()
///     .mouseFocusPolicy(.disabled)   // app drives focus itself
///
/// // Or per view:
/// PreviewPane().mouseFocusPolicy(.hoverFollows)
/// ```
///
/// ## Cases
///
/// - `.clickToLock` — default. Hover does NOT move keyboard focus; the
///   user can drift the cursor away after clicking without losing the
///   active selection. Click sets keyboard focus and fires `.onClick`.
///   Wheel routes to the hover-target focusable.
///
/// - `.hoverFollows` — hover ALSO sets keyboard focus. Useful for
///   menu/list views where mouse-over should highlight the same row
///   the keyboard would activate. Aggressive: random cursor drift
///   moves focus mid-typing.
///
/// - `.clickOnly` — wheel routes to the keyboard-focused view, not the
///   hover target. Editor-style behaviour where scroll is part of the
///   "active document," not the cursor. Click and hover otherwise
///   match `.clickToLock`.
///
/// - `.disabled` — framework gets out of the way. Hover state is not
///   tracked, click does NOT auto-promote to keyboard focus, wheel
///   does NOT auto-route. View-level callbacks (`.onHover`,
///   `.onClick`, key-press handlers) still fire so the app can wire
///   focus itself, SwiftUI-style. Use this when you want full control.
///
/// ## Composing with `.onHover`
///
/// `.onHover` callbacks fire under all four cases — they are the
/// SwiftUI-style escape hatch the framework keeps honouring even when
/// auto-routing is disabled. Suspicious pairings:
///
/// - `.disabled + .onHover`: the intended combination. No warning.
/// - `.clickToLock + .onHover`: clean. Hover state and your callback
///   coexist; no auto-focus motion.
/// - `.clickOnly + .onHover`: clean. Same as `.clickToLock` for hover.
/// - `.hoverFollows + .onHover`: framework already moves keyboard
///   focus on hover AND your callback fires. Almost always means the
///   user wanted `.disabled` for full control. The framework emits a
///   `FrameworkWarningCode.onHoverWithHoverFollows` runtime warning
///   in DEBUG builds — suppress with
///   `DebugStream.shared.suppressWarning(.onHoverWithHoverFollows)`
///   if the duplication is intentional.
public enum MouseFocusPolicy: Sendable, Equatable {
    case clickToLock
    case hoverFollows
    case clickOnly
    case disabled
}

extension TerminalView {
    /// Set the mouse focus policy for this subtree. Default is
    /// `.clickToLock`. See `MouseFocusPolicy` for case semantics.
    public func mouseFocusPolicy(_ policy: MouseFocusPolicy)
        -> ModifiedView<Self, EnvironmentModifier<MouseFocusPolicy>> {
        environment(\.mouseFocusPolicy, policy)
    }
}
