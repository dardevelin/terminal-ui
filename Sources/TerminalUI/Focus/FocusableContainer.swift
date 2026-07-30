// Engine-level focus protocol for directional navigation.
//
// Container types (stack, split, and later tab / floating) declare
// themselves focus-eligible by conforming to FocusableContainer. The
// FocusEngine dispatches arrow-key navigation through this protocol —
// never `as?`-casting to concrete container types — so adding a new
// container kind doesn't require engine changes.
//
// Why a protocol instead of extending the existing layout machinery: the
// engine's earlier arrow path matched on LayoutKind == .vstack / .hstack
// directly. That worked for the two stacks, but each new i3 primitive
// (split, stacked, tabbed, floating) would have needed its own engine
// arm, and arrow handling for nested splits is not expressible as "match
// LayoutKind" at all. Protocol dispatch keeps the engine generic and
// gives every container a single integration point.

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

    /// Whether this container's children are *panes* — addressable regions
    /// the user navigates between — rather than incidental content.
    ///
    /// Panes are focusable as units even when they hold nothing focusable, so
    /// a tiling layout works without asking the author to wrap every pane in
    /// `.focusable()`. Ordinary stacks are the opposite case: making their
    /// children units would turn every decorative label into a Tab stop.
    ///
    /// This is the container's own default. A `.focusGranularity(_:)` in the
    /// environment overrides it.
    var childrenAreFocusUnits: Bool { get }
}

/// Per-container traversal geometry: which axis the container lays children
/// along, and whether arrows may leave it.
public struct TraversalGeometry: Sendable, Equatable {
    /// Direction(s) the container handles. Arrow events whose axis
    /// doesn't match are bubbled to the parent container.
    public enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
        case both
    }

    public var axis: Axis

    /// Whether arrow navigation may leave this container — both across its
    /// edges and past its axis. One question, because containment has no
    /// axis: a container that held focus at its last child but let arrows
    /// tunnel out sideways would be incoherent.
    ///
    /// Splits are permeable: an i3 tree is meant to be traversed edge to
    /// edge, and a `.down` inside a horizontal split has to reach the split
    /// above it. Stacks are not, per the 2026-04-18 directive that arrows
    /// stay inside the element that owns them and Tab is the focus changer.
    ///
    /// Declared by the conformer because it describes the container's own
    /// shape. A user's `.focusBoundaryPolicy(_:)` still overrides it — this
    /// is the default that applies when they have expressed no preference.
    public var isPermeable: Bool

    public init(axis: Axis, isPermeable: Bool) {
        self.axis = axis
        self.isPermeable = isPermeable
    }
}

extension Key {
    /// The navigation direction this key requests, or nil when it is not an
    /// arrow. Keeps the runtime's key handling free of a four-way branch.
    var focusDirection: FocusDirection? {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        default: return nil
        }
    }
}

/// Outcome of a directional focus move.
///
/// Three cases rather than a `Bool` because "focus did not move" has two
/// meanings that must produce different caller behaviour: a container claimed
/// the direction and deliberately held focus (`blocked`), versus no container
/// claimed it at all (`unhandled`), which is the only case where falling back
/// to Tab order is legitimate.
public enum FocusMoveResult: Sendable, Equatable {
    /// Focus moved to a new node.
    case moved
    /// A container handled the direction and kept focus where it was.
    case blocked
    /// No container claimed the direction.
    case unhandled
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

// AttributeNode is the runtime existential for FocusableContainer. Splits and
// the two stacks report children and an axis; other layout kinds stay
// transparent so arrows pass through them to a container that can act.
//
// ZStack is deliberately excluded: it has no traversal axis, and reporting
// `.both` would make it claim every direction and swallow arrows for its
// whole subtree. Scroll wraps a single child, so there is nothing to
// traverse. Tab and floating containers join when those layout kinds exist.
extension AttributeNode: FocusableContainer {
    public func focusableChildren() -> [AttributeNode] {
        guard case .layout(let info) = kind else { return [] }
        switch info.kind {
        case .split:
            // A pane is a destination when it leads somewhere focusable — via
            // its content, or as a unit in its own right when it holds nothing
            // and granularity says panes are units. Under `.leaf` only the
            // first applies, so empty panes drop out of the walk.
            //
            // Ordered so each pane's subtree is walked once: a pane with
            // content short-circuits before the unit check repeats the walk.
            let unitsAllowed = panesAreFocusUnits
            return children.filter { child in
                if child.isFocusable { return true }
                return child.containsFocusable() || unitsAllowed
            }
        case .vstack, .hstack:
            // Structural stacks are compiler-introduced grouping, not layout
            // the user wrote; staying transparent keeps them out of the walk.
            guard !info.isStructural else { return [] }
            // Children that can actually receive focus somewhere beneath
            // them. Returning every child would let navigation select a
            // decorative sibling that holds no focusable and strand focus on
            // a node that cannot take it.
            //
            // Grouping is spliced rather than counted: two rows written one
            // after the other inside a `Section` arrive as a single structural
            // stack, and treating that as one child made a section of any size
            // look like one destination — arrows stepped over every row but
            // the first. Transparent has to mean transparent from both sides.
            return children.flatMap { $0.navigableFocusables }
        default:
            return []
        }
    }

    /// This node as its enclosing container sees it: itself when it is a
    /// destination, or the destinations inside it when it is only grouping.
    var navigableFocusables: [AttributeNode] {
        // A destination stops the descent: whatever is inside a control is the
        // control's business, not a set of places to arrow to.
        if isFocusable { return [self] }
        if isTransparentGrouping { return children.flatMap { $0.navigableFocusables } }
        return containsFocusable() ? [self] : []
    }

    /// Whether this node only holds other nodes: the stacks a result builder
    /// introduces, and the body of a composite view. Neither is something the
    /// user placed, so neither is somewhere to arrow to — and neither may
    /// stand in for the several destinations it may be holding.
    private var isTransparentGrouping: Bool {
        switch kind {
        case .viewBody:
            return true
        case .layout(let info):
            guard info.isStructural else { return false }
            switch info.kind {
            case .vstack, .hstack: return true
            default: return false
            }
        default:
            return false
        }
    }

    public var traversalGeometry: TraversalGeometry {
        guard case .layout(let info) = kind else {
            return TraversalGeometry(axis: .both, isPermeable: true)
        }
        switch info.kind {
        case .split(let axis):
            return TraversalGeometry(
                axis: axis == .horizontal ? .horizontal : .vertical,
                isPermeable: true
            )
        case .vstack:
            return TraversalGeometry(axis: .vertical, isPermeable: false)
        case .hstack:
            return TraversalGeometry(axis: .horizontal, isPermeable: false)
        default:
            return TraversalGeometry(axis: .both, isPermeable: true)
        }
    }

    public var childrenAreFocusUnits: Bool {
        guard case .layout(let info) = kind, case .split = info.kind else {
            return false
        }
        return true
    }

    /// Whether this node or anything beneath it can take keyboard focus.
    ///
    /// `scope` narrows the question to a single `.focusScope` — a child that
    /// leads only to focusables outside the scope is not a navigation
    /// candidate, because arrows stay within their scope.
    func containsFocusable(inScope scope: String? = nil) -> Bool {
        if isFocusable, scope == nil || scopeID == scope { return true }
        return children.contains { $0.containsFocusable(inScope: scope) }
    }

    /// Whether a child of this container is a focus target when it holds
    /// nothing focusable of its own.
    ///
    /// The author's `.focusGranularity(_:)` wins; absent one, the container's
    /// own shape decides. Resolved on the container because the answer is the
    /// same for every sibling.
    var panesAreFocusUnits: Bool {
        let granularity = focusGranularity
            ?? (childrenAreFocusUnits ? .container : .leaf)
        return granularity == .container
    }

    /// Whether the user can focus this node as a whole.
    ///
    /// True for anything explicitly `.focusable()`, and additionally for a
    /// pane that holds nothing focusable when its container says panes are
    /// units. The empty-subtree condition is what prevents a pane and its
    /// content both stopping Tab in the same region.
    ///
    /// The empty-subtree half is derived rather than stamped during graph
    /// construction: "holds nothing focusable" is not a construction-time
    /// fact, since a descendant can become focusable later when state flips a
    /// branch.
    var isFocusableUnit: Bool {
        if isFocusable { return true }
        guard parent?.panesAreFocusUnits == true else { return false }
        return !containsFocusable()
    }

    /// Whether this node takes part in focus traversal right now — a focus
    /// unit that a `.disabled()` ancestor has not switched off.
    ///
    /// The single predicate behind both the Tab index and focusable
    /// collection. Two spellings would let one of them report an order the
    /// user never gets; `.disabled()` dropping out of Tab order is SwiftUI
    /// parity and applies to every consumer equally.
    var participatesInFocus: Bool {
        isFocusableUnit && (_resolvedEnv?.isEnabled ?? true) && !isReadOnlyFocus
    }

    /// Whether focus here is a reading position rather than an operable one.
    ///
    /// The one place the Tab index and the arrow cursor deliberately disagree:
    /// arrows are a row cursor over a list, Tab moves between the things in it
    /// you can work. Arrows reach these nodes through `isFocusable`, which is
    /// what `containsFocusable` and the directional walk consult; Tab does not,
    /// because `participatesInFocus` above builds its index.
    var isReadOnlyFocus: Bool {
        isFocusable && (_resolvedEnv?.focusIsReadOnly ?? false)
    }
}
