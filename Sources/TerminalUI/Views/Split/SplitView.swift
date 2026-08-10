import Foundation

// Public TerminalView consumer that renders a SplitState.
// The view's body is `Never` — it's a layout primitive recognized
// natively by the graph (LayoutKind.split) rather than composed of
// other views. Same shape as VStack/HStack/ScrollView.

/// Ratio-based resizable panes — the tiling primitive for i3-style layouts.
///
/// SwiftUI-shaped split-pane layout view. Reads its tree from a
/// ``SplitState`` so mutations propagate via Observation. Each
/// `.split(axis:, children:, ratios:)` node distributes the parent
/// rect along `axis` according to `ratios`, drawing a 1-cell
/// divider (`│` or `─`) between siblings.
///
/// Where ``HStack``/``VStack`` size children by their content,
/// `SplitView` divides the container by proportion: a `[0.4, 0.6]`
/// horizontal split gives the left pane 40% of the columns regardless
/// of what it holds, and each leaf renders any `TerminalView` inside
/// its slice. Splits nest — a leaf position can hold another `.split`
/// with the opposite axis, which is how editor-plus-sidebar-plus-log
/// tilings are built. Ratios live in the tree, not the view: to resize
/// a pane at runtime, write updated ratios (or a whole new tree) into
/// `state.root` and the panes re-lay on the next frame. The Storybook's
/// resizable-pane page drives exactly that from key bindings.
///
/// ```swift
/// let panes = SplitState(root: .split(
///     axis: .horizontal,
///     children: [
///         .leaf(Text("left pane").foreground(.cyan)),
///         .split(
///             axis: .vertical,
///             children: [
///                 .leaf(Text("top right").foreground(.green)),
///                 .leaf(Text("bottom right").foreground(.yellow)),
///             ],
///             ratios: [0.5, 0.5]),
///     ],
///     ratios: [0.4, 0.6]))
///
/// SplitView(state: panes)
///     .frame(height: 6)
/// ```
public struct SplitView: TerminalView {
    let state: SplitState

    /// Creates a split container driven by its observable state.
    ///
    /// - Parameter state: the observable split tree. The view holds the
    ///   reference and re-renders when the tree mutates; the caller keeps
    ///   ownership, mirroring SwiftUI's `NavigationPath` pattern.
    public init(state: SplitState) {
        self.state = state
    }

    public var body: Never { fatalError("SplitView is a layout primitive — graph dispatches via LayoutKind.split") }
}
