/// How the keyboard-focus indicator is visually drawn for focusable views
///. The style is an environment value — set app-wide via
/// `.focusIndicator(_:)` on the root view, override per subtree by applying
/// the modifier closer to the leaf. Default is `.overlay` (preserves the
/// pre-look: a cyan `▎` bar adjacent to the focused view).
///
/// ## Style semantics
///
/// - `.overlay` — parent-drawn `▎` bar at `rect.x - 1` on the row(s) of the
///   focused node. Bar lives outside the focused child's rect; the top-level
///   focus pass runs with no clip. If the cell adjacent to the focused view
///   is owned by a parent (border, padding, sibling), the bar overwrites it.
///   Best-looking for forms but visually claims a cell outside the view.
///
/// - `.bar` — `▎` drawn at `rect.x` (the first cell INSIDE the focused view).
///   Costs the focused view one column of content width but survives rect
///   clipping. Best for constrained layouts.
///
/// - `.prefix` — No bar is drawn. Views that implement their own prefix
///   affordance (e.g. `List` uses `▸ ` on the selected row) handle their own
///   focus visual. Views without a built-in prefix appear unchanged under
///   keyboard focus — suitable when the app signals focus another way
///   (inverted bg, label color).
///
/// - `.none` — No focus indicator drawn by the framework. The focus engine
///   still tracks the focused node for input routing; visual feedback is
///   entirely the app's responsibility.
public enum FocusIndicatorStyle: Sendable, Equatable {
    /// Parent-drawn `▎` bar one cell to the left of the focused view's rect.
    case overlay
    /// `▎` drawn in the focused view's first column — costs one cell of
    /// content width but survives rect clipping.
    case bar
    /// No framework bar; views with a built-in prefix affordance (`List`'s
    /// `▸ ` row marker) draw their own focus visual.
    case prefix
    /// No framework-drawn indicator at all; focus is still tracked for
    /// input routing and the app signals it its own way.
    case none
}

extension TerminalView {
    /// Set the keyboard-focus indicator style for this subtree.
    ///
    /// ```swift
    /// MyApp()
    ///     .focusIndicator(.bar)     // app-wide
    ///
    /// // Or per-view:
    /// List(items).focusIndicator(.prefix)
    /// ```
    public func focusIndicator(_ style: FocusIndicatorStyle)
        -> ModifiedView<Self, EnvironmentModifier<FocusIndicatorStyle>> {
        environment(\.focusIndicatorStyle, style)
    }
}
