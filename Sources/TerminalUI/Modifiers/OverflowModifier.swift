// Component boundary opt-out.
//
// The framework silently clips writes that would land outside a
// node's assigned rect (CellBuffer.clipRect enforcement) and emits
// a `componentOverflow` framework warning when this happens —
// the loud-by-default posture that makes layout bugs visible.
//
// Some escapes are intentional: shadows that fall outside their
// owner, modal overlays that punch through into siblings,
// edge-to-edge banners that span the whole terminal. `.overflowOK()`
// is the per-subtree opt-out — a cell clipped while drawing the view
// it's applied to, or any descendant, counts for no view at all:
// not the one that drew it, and not any view around it, whether the
// cell fell outside the marked view's own rect or an enclosing one's.
// Every node measures the clipped writes of its whole subtree, so
// excusing only the marked nodes would leave each enclosing view
// reporting the same cells as its own.
//
// Suppression is per-subtree, not global. A parent that does
// `.overflowOK()` on one branch leaves siblings warning normally,
// and still reports what those siblings and its own drawing clip.
// `.environment(\.overflowAllowed, false)` inside a marked view
// turns the warning back on below it, up to the marker. To silence
// the warning code app-wide, use
// `DebugStream.shared.suppressWarning(.componentOverflow)` instead.

extension TerminalView {
    /// Suppress `componentOverflow` framework warnings for this view
    /// and its descendants. Use when escape past the assigned rect is
    /// intentional (shadows, popovers, edge-to-edge banners).
    ///
    /// The cells this view's subtree has clipped count for no view: the
    /// views around it report only what their other children and their
    /// own drawing clip. Set `overflowAllowed` back to `false` with
    /// `.environment(\.overflowAllowed, false)` on a part of this view to
    /// have that part warn again.
    public func overflowOK() -> ModifiedView<Self, EnvironmentModifier<Bool>> {
        environment(\.overflowAllowed, true)
    }
}
