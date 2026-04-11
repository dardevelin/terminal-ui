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
    public var stateSlots: [String: AnyStateStorage] = [:]

    /// Cached intrinsic width — nil means needs recomputation.
    /// Invalidated when markDirty() is called (content changed).
    public var cachedWidth: Int?

    /// Cached intrinsic height — nil means needs recomputation.
    public var cachedHeight: Int?

    /// Whether this node can receive focus (set by .focusable() modifier).
    public var isFocusable: Bool = false

    /// Whether onAppear has already fired for this node.
    public var didAppear: Bool = false

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
        parent?.markLayoutDirty()
    }

    /// Mark layout dirty up the tree and invalidate measurement caches.
    func markLayoutDirty() {
        cachedWidth = nil
        cachedHeight = nil
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

// MARK: - Primitive

public enum PrimitiveContent {
    case text([TextSpan])
    case spacer
    case divider
    case progressBar(value: Double, label: String?, filled: Character, empty: Character)
    case spinner(frame: Int, style: SpinnerStyle)
    case empty
}

// MARK: - Layout

public struct LayoutInfo {
    public var kind: LayoutKind
    public var childSizes: [Size] = []

    public init(kind: LayoutKind) {
        self.kind = kind
    }
}

public enum LayoutKind {
    case vstack
    case hstack
    case zstack
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
    case onKeyPress  // attaches a key handler (handler stored on FocusEngine, not here)
    case onAppear    // fires action on first graph construction (tracked on node)
    case onClick     // attaches click handler (handler stored on FocusEngine)
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
