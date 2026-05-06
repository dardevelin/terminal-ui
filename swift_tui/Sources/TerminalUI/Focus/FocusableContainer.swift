// HYP-326 Slice 0a — engine-level focus protocol for the i3 family.
//
// Container types (split, tab, stack, floating) declare themselves
// focus-eligible by conforming to FocusableContainer. The FocusEngine
// dispatches arrow-key directional navigation through this protocol —
// never `as?`-casting to concrete container types — so adding a new
// container kind doesn't require engine changes.
//
// Why a separate protocol instead of extending the existing layout
// machinery: the engine's prior arrow path keys off LayoutKind ==
// .vstack / .hstack hard-coded. That works for the legacy stacks but
// each new i3 primitive (split, stacked, tabbed, floating) would need
// its own engine arm, and arrow handling for nested splits is not
// expressible as "match LayoutKind." Protocol-based dispatch keeps the
// engine generic and gives every i3 child a single integration point.

/// Container types that participate in directional focus navigation.
///
/// Conformers expose the AttributeNodes that should be reachable via
/// arrow keys (`focusableChildren()`) and a geometry hint for which
/// directions make sense within the container (`traversalGeometry`).
///
/// The `FocusEngine.move(_:root:)` API consults this protocol via the
/// `AttributeNode` existential, so any node whose `kind` matches a
/// known container shape participates without engine-side casts.
public protocol FocusableContainer {
    /// AttributeNodes that can receive focus when navigation lands
    /// inside this container, in declaration order. Each child should
    /// itself be either `isFocusable == true` or another
    /// `FocusableContainer` whose subtree contains a focusable.
    func focusableChildren() -> [AttributeNode]

    /// Axis hint for arrow-key handling. The engine uses this to
    /// decide whether an arrow direction belongs to this container
    /// or should bubble up. `.both` means the container accepts all
    /// four directions (e.g. floating layout, ZStack-shaped overlays).
    var traversalGeometry: TraversalGeometry { get }
}

/// Per-container traversal geometry: which axis the container lays
/// children along, plus whether the container's own edges wrap.
///
/// `wrapsAtEdge` is a hint — the runtime-level `focusBoundaryPolicy`
/// env value still wins. The geometry's wrap flag is what conformers
/// declare when their layout is *intrinsically* wrap-friendly (a
/// circular pager, for example), not a user preference.
public struct TraversalGeometry: Sendable, Equatable {
    /// Direction(s) the container handles. Arrow events whose axis
    /// doesn't match are bubbled to the parent container.
    public enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
        case both
    }

    public var axis: Axis
    public var wrapsAtEdge: Bool

    public init(axis: Axis, wrapsAtEdge: Bool = false) {
        self.axis = axis
        self.wrapsAtEdge = wrapsAtEdge
    }
}

/// What the engine does when arrow navigation hits a container's
/// edge with no neighbor in the requested direction.
///
/// Default is `.escapeToParent` — the i3 convention. Override per
/// subtree via `.focusBoundaryPolicy(_:)`. Stack-based env override
/// composes through ancestor chains the SwiftUI way.
public enum FocusBoundaryPolicy: Sendable, Equatable {
    /// Bubble up the container chain — try the parent's neighbors.
    /// Matches i3's `tree_next_sibling` walk.
    case escapeToParent

    /// Wrap to the opposite end of the current container.
    case wrap

    /// No movement — focus stays put. Apps wire `.onBoundaryHit`
    /// to react (visual feedback, sound, modal dialog, etc.).
    case stay
}

/// How thoroughly a container's panes participate in focus when
/// they have no focusable descendants.
///
/// Default is `.container` — the SwiftUI list-row convention where
/// rows are themselves focusable units even if their content isn't.
/// Lets i3-style "focus this pane" semantics work for free without
/// requiring users to wrap each pane in `.focusable()`.
public enum FocusGranularity: Sendable, Equatable {
    /// A pane with no focusable descendants is itself focusable.
    /// SwiftUI list-row pattern; i3 default behaviour.
    case container

    /// Only descendants explicitly marked `.focusable()` participate.
    /// Tab order skips empty panes; arrow nav steps over them.
    case leaf
}

// MARK: - AttributeNode conformance

// AttributeNode acts as the runtime existential for FocusableContainer.
// Today only `LayoutKind.split` reports children + axis; other layouts
// continue to route through the legacy axis-matching path in
// `FocusEngine.focusInDirection`. Future slices migrate VStack / HStack
// / Tab / Stack / Floating one at a time, eliminating the LayoutKind
// hard-coding from the engine.
extension AttributeNode: FocusableContainer {
    public func focusableChildren() -> [AttributeNode] {
        guard case .layout(let info) = kind, case .split = info.kind else {
            return []
        }
        return children
    }

    public var traversalGeometry: TraversalGeometry {
        guard case .layout(let info) = kind, case .split(let axis) = info.kind else {
            return TraversalGeometry(axis: .both, wrapsAtEdge: false)
        }
        return TraversalGeometry(
            axis: axis == .horizontal ? .horizontal : .vertical,
            wrapsAtEdge: false
        )
    }
}
