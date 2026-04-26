/// Base class for all nodes in the attribute graph.
/// Persistent across frames — created once, updated in place.
public class AttributeNode {
    public let id: NodeID
    public var kind: NodeKind
    public weak var parent: AttributeNode?
    public var children: [AttributeNode] = []
    public var isDirty: Bool = true

    /// Cached layout result — the rectangle this node occupies
    public var rect: Rect = Rect(x: 0, y: 0, width: 0, height: 0)

    /// Style inherited from parent + modifiers
    public var resolvedStyle: Style = .plain

    /// State storage slots — persisted across body re-evaluations.
    /// @TerminalState creates slots here during first body evaluation.
    /// Dictionary keyed by source location for O(1) lookup.
    public var stateSlots: [String: any AnyStateStorage] = [:]

    /// Cached intrinsic width — nil means needs recomputation.
    /// Invalidated when markDirty() is called (content changed).
    public var cachedWidth: Int?

    /// Cached intrinsic height — nil means needs recomputation.
    public var cachedHeight: Int?
    /// Proposed width the `cachedHeight` was computed at. Height is
    /// width-dependent whenever wrapping is involved, so the measurer must
    /// recompute when the width changes.
    public var cachedHeightWidth: Int?

    /// Whether this node can receive focus (set by .focusable() modifier).
    public var isFocusable: Bool = false

    /// Identifier of the nearest enclosing focus scope, or nil if not in one.
    /// Set during reconciliation by .focusScope(id) — the modifier propagates its id
    /// to every focusable descendant. FocusEngine uses it to clamp directional
    /// navigation: arrows stay within a scope, Tab still crosses scopes.
    public var scopeID: String?

    /// Whether onAppear has already fired for this node.
    public var didAppear: Bool = false

    /// Last observed value seen by an `.onChange(of:)` modifier on this node.
    /// Stored as `Any` because the `ModifierEffect` enum is generic-free; the
    /// modifier carries its own `Equatable` comparator that decides whether a
    /// stored-vs-current pair represents a change. Nil before the first probe.
    public var lastObservedValue: Any?

    /// Closure to invoke when this node is detached from the tree. Set by
    /// `_RemovalLifecycleModifier.captureDisappear` during construct/update;
    /// invoked from `AttributeGraph` whenever a node leaves the tree (layout
    /// rebuild, conditional flip, etc.). Nil for nodes without onDisappear.
    public var onDisappearAction: (() -> Void)?

    /// Last `EquatableTerminalView` value cached for the user-Equatable
    /// fast path in `updateNode`. Stored as `Any` so the type-erased
    /// reconciler can compare new vs cached without naming the generic
    /// content type. Nil before the first build of a composite.
    public var lastEquatableInput: Any?

    /// Last raw view value cached for the Mirror-based reflective
    /// compare in `updateNode`. Stored for every composite — when a
    /// fresh value arrives and `Mirror`-walking it field-by-field shows
    /// equality with this cache, `evaluateBody` can be skipped exactly
    /// like the Equatable wrapper path. Closures and incomparable
    /// reference types defeat the compare (the documented parity
    /// ceiling — see `AttributeGraph.reflectiveEqual`). Nil before the
    /// first `updateNode` for this composite.
    public var lastInputView: Any?

    /// Closure that re-runs this node's body with the cached view value.
    /// Captured by `evaluateBody` / `constructComposite` where the
    /// generic view type `V` is still in scope; invoked by
    /// `AttributeGraph.drain()` to re-evaluate dirty nodes in place
    /// without reflecting over `V`. Nil for non-composite nodes.
    public var bodyReplay: ((AttributeGraph, AttributeNode) -> Void)?

    /// EnvironmentValues snapshot captured during the render walk. The
    /// renderer writes the in-flight `GraphContext.currentEnvironment`
    /// here at every node it visits, so handlers and tooling can read
    /// per-subtree resolved env between events without a replay walk.
    /// SwiftUI's `@Environment` reads target the same kind of cache;
    /// matching the shape unlocks future preview tooling that asks
    /// "what does this node see?" without re-running the world.
    /// Underscored: framework-internal access pending a deliberate
    /// public preview API. Cleared on `markDirty` so a stale env
    /// value cannot survive an env-modifier change.
    public var _resolvedEnv: EnvironmentValues?

    /// Scroll offset for scroll layout nodes — persisted across frames.
    /// Positive values scroll content left (horizontal) or up (vertical).
    public var scrollOffset: Int = 0

    /// Memoised: true iff this node OR any descendant has `.viewBody`
    /// kind. Filled bottom-up at the end of `AttributeGraph.update(from:)`
    /// so `GraphMeasurer.containsViewBody` is O(1) on the measurement
    /// hot path. Nil before the first stamp; the helper falls back to
    /// a lazy descendant walk that fills the cache and returns the
    /// correct answer either way.
    public var _containsViewBody: Bool?

    /// GeometryReader rebuild hook. When non-nil the renderer invokes this
    /// with the node's actual rect size each frame. The closure rebuilds the
    /// `geom.content(size)` view value and *updates* the existing child
    /// subtree in place — preserving NodeIDs, `@TerminalState` storage,
    /// focus registrations, and lifecycle bookkeeping. The
    /// previous implementation replaced `node.children` wholesale on every
    /// render, which destroyed identity.
    ///
    /// The closure receives the owning node so it can locate the existing
    /// child (`node.children.first`) before deciding whether to update or
    /// rebuild (e.g. on the very first render before any seed exists).
    public var geometryRebuilder: ((Size, AttributeNode) -> Void)?

    public init(id: NodeID, kind: NodeKind) {
        self.id = id
        self.kind = kind
    }

    /// Mark this node and its layout ancestors as needing re-evaluation.
    /// Also invalidates cached measurements up the tree.
    public func markDirty() {
        isDirty = true
        cachedWidth = nil
        cachedHeight = nil
        cachedHeightWidth = nil
        _resolvedEnv = nil
        parent?.markLayoutDirty()
    }

    /// Mark layout dirty up the tree and invalidate measurement caches.
    func markLayoutDirty() {
        cachedWidth = nil
        cachedHeight = nil
        cachedHeightWidth = nil
        if case .layout = kind {
            isDirty = true
        }
        parent?.markLayoutDirty()
    }
}

/// Discriminated node kind — switch on this, never `as?` cast.
public enum NodeKind {
    case primitive(PrimitiveContent)
    case layout(LayoutInfo)
    case modifier(ModifierEffect)
    case viewBody(ViewBodyInfo)

    /// Quick kind checks for reconciliation type-safety.
    var isPrimitive: Bool {
        if case .primitive = self { return true }
        return false
    }

    func isLayout(_ kind: LayoutKind) -> Bool {
        if case .layout(let info) = self { return info.kind == kind }
        return false
    }

    var isModifier: Bool {
        if case .modifier = self { return true }
        return false
    }

    var isViewBody: Bool {
        if case .viewBody = self { return true }
        return false
    }
}

#if DEBUG
extension NodeKind {
    var debugName: String {
        switch self {
        case .primitive(let c):
            switch c {
            case .text: "Text"
            case .spacer: "Spacer"
            case .divider: "Divider"
            case .progressBar: "ProgressBar"
            case .spinner: "Spinner"
            case .empty: "Empty"
            case .cellBuffer: "BufferView"
            }
        case .layout(let info):
            switch info.kind {
            case .vstack: "VStack"
            case .hstack: "HStack"
            case .zstack: "ZStack"
            case .scroll(let axis):
                axis == .horizontal ? "ScrollView(H)" : "ScrollView(V)"
            }
        case .modifier(let effect):
            switch effect {
            case .foreground: "fg"
            case .background: "bg"
            case .bold: "bold"
            case .italic: "italic"
            case .underline: "underline"
            case .padding: "padding"
            case .border: "border"
            case .frame: "frame"
            case .explicitID: "id"
            case .overlay: "overlay"
            case .backgroundView: "bgView"
            case .modal: "modal"
            case .focusable: "focusable"
            case .focusScope: "focusScope"
            case .onKeyPress: "onKeyPress"
            case .onAppear: "onAppear"
            case .onChange: "onChange"
            case .onDisappear: "onDisappear"
            case .onClick: "onClick"
            case .onHover: "onHover"
            case .environment: "environment"
            }
        case .viewBody(let info):
            info.viewTypeName
        }
    }
}
#endif

// MARK: - Primitive

public enum PrimitiveContent {
    case text([TextSpan])
    case spacer
    case divider
    case progressBar(value: Double, label: String?, filled: Character, empty: Character)
    case spinner(frame: Int, style: SpinnerStyle)
    case empty
    /// Pre-rasterized cell content. The renderer blits `source[x, y]`
    /// to `buffer[rect.x + x, rect.y + y]` for the intersection of
    /// the source's dimensions and the rect — including `.empty`
    /// source cells, which is the deliberate divergence from the
    /// ScrollView local-buffer pattern.
    case cellBuffer(CellBuffer)
}

// MARK: - Layout

public struct LayoutInfo {
    public var kind: LayoutKind
    public var childSizes: [Size] = []
    /// `true` when the layout node was synthesized by a result builder
    /// (TupleView) or by `ForEach`. Structural vstacks are transparent
    /// to focus navigation and measurement routing — they don't
    /// introduce a new axis the way a user-written `VStack` does. Set
    /// at construction time so the heuristic-based detector (which mis-
    /// classified user VStacks nested inside composite bodies) is
    /// replaced by a hard, reliable flag.
    public var isStructural: Bool = false

    public init(kind: LayoutKind, isStructural: Bool = false) {
        self.kind = kind
        self.isStructural = isStructural
    }
}

public enum LayoutKind: Equatable {
    case vstack
    case hstack
    case zstack
    case scroll(ScrollAxis)
}

public struct Size: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

// MARK: - Modifier

public enum ModifierEffect {
    case foreground(Color)
    case background(Color)
    case bold
    case italic
    case underline
    case padding(Int)
    case border(BorderStyle)
    case frame(width: Int?, height: Int?, minWidth: Int?, maxWidth: Int?, minHeight: Int?, maxHeight: Int?)
    case explicitID(AnyHashable)
    case overlay     // child[0] = base, child[1] = overlay content
    case backgroundView  // child[0] = background content, child[1] = base (render bg first)
    case modal(isPresented: Bool) // child[0] = base, child[1] = modal content (when presented)
    case focusable   // marks the child as able to receive focus
    case focusScope(String) // groups focusable descendants; arrows stay within
    case onKeyPress  // attaches a key handler (handler stored on FocusEngine, not here)
    case onAppear    // fires action on first graph construction (tracked on node)
    case onChange    // fires action when bound value changes (last value stored on node)
    case onDisappear // fires action when node is removed from the tree
    case onClick     // attaches click handler (handler stored on FocusEngine)
    case onHover     // attaches hover handler (handler stored on FocusEngine)
    /// Environment-value setter. The closure applies the modifier's keyPath
    /// and value to a mutable `EnvironmentValues` during render so descendants
    /// observe the new value via `GraphContext.currentEnvironment`. Boxing as
    /// a closure keeps the ModifierEffect enum free of generic parameters
    /// (the keypath/value pair is type-erased at construction time).
    case environment((inout EnvironmentValues) -> Void)
}

// MARK: - View Body

/// Type-erased container for a view body node.
public final class ViewBodyInfo {
    /// Name for debugging
    public var viewTypeName: String

    public init(viewTypeName: String) {
        self.viewTypeName = viewTypeName
    }
}
