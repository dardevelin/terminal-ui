import Foundation

// HYP-277 — public TerminalView consumer that renders a SplitState.
// The view's body is `Never` — it's a layout primitive recognized
// natively by the graph (LayoutKind.split) rather than composed of
// other views. Same shape as VStack/HStack/ScrollView.

/// SwiftUI-shaped split-pane layout view. Reads its tree from a
/// `SplitState` so mutations propagate via Observation. Each
/// `.split(axis:, children:, ratios:)` node distributes the parent
/// rect along `axis` according to `ratios`, drawing a 1-cell
/// divider (`│` or `─`) between siblings.
///
/// Slice 1 ships fixed ratios at construction time. Mutation API,
/// nested splits, mouse-resize, and i3 hotkeys come in slices 2-7.
public struct SplitView: TerminalView {
    let state: SplitState

    public init(state: SplitState) {
        self.state = state
    }

    public var body: Never { fatalError("SplitView is a layout primitive — graph dispatches via LayoutKind.split") }
}
