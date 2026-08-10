import Foundation
import Observation

// HYP-277 — @Observable wrapper around SplitNode so SplitView re-
// renders when the tree mutates. Mirrors SwiftUI's NavigationPath
// pattern: the consumer holds the state, the view binds to it,
// mutations propagate via Observation.
//
// Non-isolated to match the framework's "main thread by convention"
// rule (per `feedback_drop_mainactor_to_match_neighbor.md`).
// AttributeNode is `@unchecked Sendable`; tests run inside
// `@MainActor` suites; the runtime invokes graph code from main-
// thread render code.

/// Observable owner of a ``SplitNode`` tree — the state a ``SplitView``
/// renders.
///
/// Mirrors SwiftUI's `NavigationPath` pattern: the app holds the state, the
/// view binds to it, and any assignment to ``root`` — a whole new tree, or a
/// copy with rewritten ratios — re-lays the panes on the next frame via
/// Observation. The Storybook's resizable-pane page resizes exactly this way,
/// writing new ratios from key bindings.
///
/// ```swift
/// let panes = SplitState(root: .split(
///     axis: .horizontal,
///     children: [
///         .leaf(Text("sidebar")),
///         .leaf(Text("editor")),
///     ],
///     ratios: [0.3, 0.7]))
///
/// SplitView(state: panes)
/// ```
@Observable
public final class SplitState {
    /// The current split tree. `SplitNode` is a value type, so resizing or
    /// restructuring means assigning a new (or mutated) tree here; the
    /// panes re-lay on the next frame.
    public var root: SplitNode

    /// Creates state owning the given tree.
    public init(root: SplitNode) {
        self.root = root
    }

    /// Convenience init for callers that build the tree lazily.
    /// Defaults to a placeholder leaf wrapping the framework's
    /// `EmptyView` so app code doesn't carry an `Optional<SplitNode>`
    /// through its data flow. Replace `root` before first render.
    public convenience init() {
        self.init(root: .leaf(EmptyView()))
    }
}
