// Equatable fast-path for view comparison.
//
// Mirrors SwiftUI's `EquatableView` / `View.equatable()`. Wraps a view
// whose type is `Equatable` so the graph reconciler can short-circuit
// `body` re-evaluation when the new value equals the cached one.
//
// Apple's WWDC21 guidance applies verbatim: "SwiftUI will keep around
// a copy of the value to perform a comparison and know if the view
// has changed." The default reconciler walks Mirror-based field
// comparison; the `.equatable()` opt-in gives it a user-supplied `==`
// instead — faster and exact.
//
// The wrapper itself stores the content and forwards `==` to it. The
// reconciler detects the wrapper via `_EquatableTerminalView` (a
// type-erased protocol that hides the generic content parameter) and
// uses it to compare new vs cached input before deciding whether to
// re-evaluate.

/// Type-erasure for the wrapper so the reconciler can detect it and
/// invoke `compare(against:)` without naming the generic content type.
public protocol _EquatableTerminalView {
    /// True iff `other` is an `EquatableTerminalView<C>` of the same
    /// content type AND the wrapped values compare equal. False on
    /// type mismatch or inequality.
    func _equatableContentEqual(to other: any _EquatableTerminalView) -> Bool
}

/// Wrapper that opts a view's subtree into value-equality
/// short-circuiting during graph reconciliation.
///
/// Usage:
/// ```
/// struct MyRow: TerminalView, Equatable {
///     let label: String
///     var body: some TerminalView { Text(label) }
/// }
///
/// // Inside a list:
/// MyRow(label: row.title).equatable()
/// ```
///
/// `MyRow.equatable()` returns an `EquatableTerminalView<MyRow>`. The
/// reconciler caches the previous wrapped value on the node and
/// compares with `==` on next update — equal values skip body
/// re-evaluation entirely.
public struct EquatableTerminalView<Content: TerminalView & Equatable>: TerminalView, _EquatableTerminalView {
    public let content: Content
    public init(_ content: Content) { self.content = content }

    public var body: Content { content }

    public func _equatableContentEqual(to other: any _EquatableTerminalView) -> Bool {
        guard let typed = other as? EquatableTerminalView<Content> else {
            return false
        }
        return content == typed.content
    }
}

extension TerminalView where Self: Equatable {
    /// Opt this view's subtree into Equatable-based short-circuit
    /// reconciliation. When a parent re-evaluates and emits a new
    /// value of this view, the reconciler compares against the cached
    /// value via `==`; equal → skip body re-evaluation, unequal →
    /// fall through to normal reconciliation. Faster than the default
    /// Mirror-based field walk and exact about which fields matter.
    ///
    /// Apply at points where view inputs are stable across many parent
    /// re-evaluations: list rows, deep nested cells, anything whose
    /// inputs don't change in lockstep with their ancestors.
    public func equatable() -> EquatableTerminalView<Self> {
        EquatableTerminalView(self)
    }
}
