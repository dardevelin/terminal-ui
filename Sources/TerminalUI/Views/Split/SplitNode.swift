import Foundation

// Tree-as-state model for resizable split layouts. The recursive enum mirrors
// i3's Con tree (data.h:643) adapted to a SwiftUI-shaped value type.
//
// Ratios are fixed at construction today. A runtime mutation API
// (append/remove/splitNode) and drag-driven divider resize land later.

/// Recursive tree of either a single view (leaf) or a sibling list
/// laid out along an axis with explicit per-child ratios.
///
/// Not `Sendable`: the leaf payload is `any TerminalView`, which
/// is not constrained to `Sendable` (view bodies often capture
/// `@Observable` state classes that aren't Sendable). SplitNodes
/// live on the main thread by convention — same rule as the rest
/// of the graph layer.
public indirect enum SplitNode {
    /// A pane holding one view, optionally tagged with a marker.
    ///
    /// The marker is what makes a tree serialisable: JSON describes *slots*,
    /// and a reader resolves each marker back to a view through a registry —
    /// the same arrangement as i3's swallows criteria. A view cannot be
    /// serialised directly (`any TerminalView` is not `Codable`, and a body is
    /// arbitrary Swift), so a leaf without a marker is simply not encodable.
    /// It stays legal for trees nobody serialises: demos, tests, throwaway
    /// layouts.
    case leaf(any TerminalView, id: String? = nil)
    case split(axis: SplitAxis, children: [SplitNode], ratios: [Double])
}

/// Axis for a split container. Mirrors i3's `orientation_t` (HORIZ /
/// VERT) — `.horizontal` = children laid side-by-side, `.vertical`
/// = stacked top-to-bottom.
public enum SplitAxis: Sendable, Equatable {
    case horizontal
    case vertical
}
