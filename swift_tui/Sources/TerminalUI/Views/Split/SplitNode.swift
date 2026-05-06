import Foundation

// HYP-277 (i3 epic Slice 1) — tree-as-state model for resizable
// split layouts. Recursive enum mirrors i3's Con tree (data.h:643)
// adapted to a SwiftUI-shaped value type.
//
// Slice 1 ships fixed ratios at construction time. Slice 2 adds
// the mutation API (append/remove/splitNode); Slice 4 adds the
// .onDrag-driven divider resize that mutates ratios at runtime.

/// Recursive tree of either a single view (leaf) or a sibling list
/// laid out along an axis with explicit per-child ratios.
///
/// Not `Sendable`: the leaf payload is `any TerminalView`, which
/// is not constrained to `Sendable` (view bodies often capture
/// `@Observable` state classes that aren't Sendable). SplitNodes
/// live on the main thread by convention — same rule as the rest
/// of the graph layer.
public indirect enum SplitNode {
    case leaf(any TerminalView)
    case split(axis: SplitAxis, children: [SplitNode], ratios: [Double])
}

/// Axis for a split container. Mirrors i3's `orientation_t` (HORIZ /
/// VERT) — `.horizontal` = children laid side-by-side, `.vertical`
/// = stacked top-to-bottom.
public enum SplitAxis: Sendable, Equatable {
    case horizontal
    case vertical
}
