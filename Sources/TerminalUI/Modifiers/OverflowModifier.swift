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
// is the per-subtree opt-out — it suppresses the warning for the
// view it's applied to and every descendant.
//
// Suppression is per-subtree, not global. A parent that does
// `.overflowOK()` on one branch leaves siblings warning normally.
// To silence the warning code app-wide, use
// `DebugStream.shared.suppressWarning(.componentOverflow)` instead.

extension TerminalView {
    /// Suppress `componentOverflow` framework warnings for this view
    /// and its descendants. Use when escape past the assigned rect is
    /// intentional (shadows, popovers, edge-to-edge banners).
    public func overflowOK() -> ModifiedView<Self, EnvironmentModifier<Bool>> {
        environment(\.overflowAllowed, true)
    }
}
