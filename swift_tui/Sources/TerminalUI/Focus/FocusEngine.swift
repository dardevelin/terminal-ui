/// Centralized focus state manager.
/// Tracks keyboard focus and mouse hover independently.
///
/// Keyboard focus: moved by Tab/Shift+Tab, arrow keys, or mouse click.
/// Mouse hover: tracked independently, follows mouse position.
///
/// Owned by the TerminalRuntime. One per app instance.
/// Always accessed from @MainActor (TerminalRuntime).
public final class FocusEngine {

    /// Keyboard focus — the node that receives key events.
    /// Moved by Tab/Shift+Tab, arrow keys, or clicking a focusable node.
    public var keyboardFocusID: NodeID?

    /// Mouse hover — the focusable node under the mouse cursor.
    /// Updated on every mouse move. Independent of keyboard focus.
    public var mouseHoverID: NodeID?

    /// Last known mouse position (cell coordinates).
    public var mousePosition: (x: Int, y: Int) = (0, 0)

    /// Registered key handlers — keyed by NodeID.
    var keyHandlers: [NodeID: (KeyEvent) -> KeyEventResult] = [:]

    /// Registered click handlers — keyed by NodeID.
    var clickHandlers: [NodeID: (_ relativeX: Int, _ relativeY: Int) -> Void] = [:]

    // MARK: - Cached Indices (rebuilt when graph changes)

    /// O(1) node lookup by ID — replaces recursive tree walk.
    private var nodeIndex: [NodeID: AttributeNode] = [:]

    /// Pre-computed ordered list of focusable nodes (depth-first, pre-order).
    private var focusableList: [AttributeNode] = []

    /// The root against which `rebuildIndex` last ran. Exposed so tooling
    /// built on top of FocusEngine (`.scrollable()` modifier's key handler,
    /// inspector probes, remote-control tree queries) can walk subtrees
    /// without threading `root` through every call site.
    public private(set) var lastIndexedRoot: AttributeNode?

    public init() {}

    // MARK: - Index Rebuilding

    /// Rebuild both indices with a single depth-first walk.
    /// Called after graph.update() when the graph structure changed.
    public func rebuildIndex(root: AttributeNode) {
        nodeIndex.removeAll(keepingCapacity: true)
        focusableList.removeAll(keepingCapacity: true)
        lastIndexedRoot = root
        buildIndexRecursive(root)
    }

    private func buildIndexRecursive(_ node: AttributeNode) {
        nodeIndex[node.id] = node
        if node.isFocusable {
            focusableList.append(node)
        }
        for child in node.children {
            buildIndexRecursive(child)
        }
    }

    // MARK: - Keyboard Focus Traversal

    /// Move keyboard focus to the next focusable node (Tab order).
    /// Tab order = depth-first pre-order of the view tree, matching visual reading order.
    /// Wraps around: last node → first node.
    public func focusNext() {
        guard !focusableList.isEmpty else { return }

        if let current = keyboardFocusID,
           let idx = focusableList.firstIndex(where: { $0.id == current }) {
            let next = (idx + 1) % focusableList.count
            keyboardFocusID = focusableList[next].id
        } else {
            keyboardFocusID = focusableList.first?.id
        }
    }

    /// Move keyboard focus to the previous focusable node (Shift+Tab).
    public func focusPrevious() {
        guard !focusableList.isEmpty else { return }

        if let current = keyboardFocusID,
           let idx = focusableList.firstIndex(where: { $0.id == current }) {
            let prev = idx == 0 ? focusableList.count - 1 : idx - 1
            keyboardFocusID = focusableList[prev].id
        } else {
            keyboardFocusID = focusableList.last?.id
        }
    }

    /// Directional focus movement — arrow keys respect layout axis.
    ///
    /// Finds the focused node's nearest layout parent (VStack or HStack) and
    /// checks if the arrow direction matches the layout axis:
    ///
    ///   VStack + up/down       → move to sibling above/below (always)
    ///   HStack + left/right    → move to sibling left/right  (always)
    ///   Axis mismatch or no stack → fall back to Tab order, but ONLY when
    ///                            `crossStack` is true (gate consumed by
    ///                            TerminalApp from `EnvironmentValues.
    ///                            allowArrowFocusNavigation`).
    ///
    /// User directive 2026-04-18: "arrow down on an element that has the
    /// focus shouldn't move focus out of it, tab is the focus changer,
    /// unless marked as allow". In-stack sibling navigation DOES count as
    /// "inside" the element's container — pressing right on Button "OK"
    /// moving to "Cancel" next to it is an expected UX, not a Tab-style
    /// escape. Cross-stack escape is the only behavior the gate controls.
    public func focusInDirection(_ direction: FocusDirection, root: AttributeNode?, crossStack: Bool = false) {
        guard let root else { return }
        guard let current = keyboardFocusID else {
            focusNext()
            return
        }

        guard let currentNode = findNode(id: current, in: root) else { return }

        let axisKind: LayoutKind
        switch direction {
        case .up, .down: axisKind = .vstack
        case .left, .right: axisKind = .hstack
        }

        // Walk up to find the innermost non-structural layout parent. If it
        // matches the arrow axis but holds only the current focusable (which
        // happens when a composite view's body introduces its own wrapping
        // VStack — TextInput, Button, etc.), keep climbing through
        // axis-matching layouts until we find one with a sibling. Stop as
        // soon as we hit a MISMATCHED axis layout: arrows must not tunnel
        // past a perpendicular stack (that's how the scope tests survive —
        // pressing down inside an HStack shouldn't jump to a VStack above).
        var search: AttributeNode? = currentNode.parent
        while let candidate = search {
            if case .layout(let info) = candidate.kind, !info.isStructural {
                if info.kind != axisKind {
                    // Hit a perpendicular-axis layout. `focusable` at the
                    // edge of its scope/stack should stay put. Do not
                    // continue upward — jumping past a perpendicular layout
                    // is exactly the "leaks out" behavior the policy
                    // forbids. Fall through to the Tab-order fallback,
                    // which is itself gated by `crossStack` + scopeID.
                    break
                }
                let allSiblings = collectFocusables(candidate)
                let siblings: [AttributeNode]
                if let scope = currentNode.scopeID {
                    siblings = allSiblings.filter { $0.scopeID == scope }
                } else {
                    siblings = allSiblings
                }
                if let idx = siblings.firstIndex(where: { $0.id == current }),
                   siblings.count > 1 {
                    switch direction {
                    case .down, .right:
                        if idx + 1 < siblings.count {
                            keyboardFocusID = siblings[idx + 1].id
                            return
                        }
                    case .up, .left:
                        if idx > 0 {
                            keyboardFocusID = siblings[idx - 1].id
                            return
                        }
                    }
                    // At the edge of this layout — "stay inside" per rule.
                    return
                }
                // Same-axis layout but no sibling at this level: keep
                // climbing so composite views whose bodies introduce a
                // same-axis VStack don't kill arrow nav.
            }
            search = candidate.parent
        }

        // No axis match anywhere, OR axis was perpendicular at some level.
        // Fall back to Tab order only when the host app opted in; arrows
        // inside a scope always no-op so they can't leak out.
        if currentNode.scopeID != nil { return }
        guard crossStack else { return }
        switch direction {
        case .up, .left: focusPrevious()
        case .down, .right: focusNext()
        }
    }

    // MARK: - Mouse Handling

    /// Update hover state from mouse position.
    public func updateMouseHover(x: Int, y: Int, root: AttributeNode?) {
        mousePosition = (x, y)
        guard let root else {
            mouseHoverID = nil
            return
        }
        mouseHoverID = findFocusableAt(x: x, y: y, in: root)?.id
    }

    /// Handle mouse click — transfer keyboard focus and invoke click handler.
    ///
    /// Two-phase lookup:
    /// 1. **Focusable hit:** if the cursor is over a focusable node, that
    ///    node receives keyboard focus. If the focusable has an onClick
    ///    handler (or an ancestor does), invoke it; otherwise synthesise
    ///    an Enter key so a focused Button can be triggered by click.
    /// 2. **Non-focusable click handler:** if no focusable is under the
    ///    cursor but a node *with a registered click handler* is, invoke
    ///    that handler. Keyboard focus stays where it was. Lets a list
    ///    row be clickable (via `.onClick`) without joining the Tab
    ///    cycle as a focusable.
    ///
    /// Used by Storybook's sidebar rows: they're not focusable (the
    /// single-focusable architecture lives on the bottom hint row), but
    /// each row has `.onClick { selectedIndex = ... }` so a mouse click
    /// jumps directly to the corresponding page.
    public func handleMouseClick(x: Int, y: Int, root: AttributeNode?) {
        guard let root else { return }
        if let target = findFocusableAt(x: x, y: y, in: root) {
            keyboardFocusID = target.id
            if let handler = findClickHandler(for: target, root: root) {
                let relX = x - target.rect.x
                let relY = y - target.rect.y
                handler(relX, relY)
            } else {
                let syntheticEnter = KeyEvent(key: .enter)
                _ = routeKeyEvent(syntheticEnter, root: root)
            }
            return
        }
        // No focusable under the cursor — try a click handler on any
        // node containing the click point. Walks deepest-first so a
        // row's onClick wins over its parent VStack's.
        if let (target, handler) = findClickableAt(x: x, y: y, in: root) {
            let relX = x - target.rect.x
            let relY = y - target.rect.y
            handler(relX, relY)
        }
    }

    /// Walk the tree deepest-first looking for a node that contains
    /// (x, y) AND has a registered click handler. Used by the
    /// non-focusable click path so e.g. a sidebar row tagged with
    /// `.onClick` receives the event without needing to be focusable.
    private func findClickableAt(x: Int, y: Int, in node: AttributeNode)
        -> (AttributeNode, (_ relX: Int, _ relY: Int) -> Void)?
    {
        for child in node.children.reversed() {
            if let hit = findClickableAt(x: x, y: y, in: child) {
                return hit
            }
        }
        let r = node.rect
        if x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height,
           let handler = clickHandlers[node.id]
        {
            return (node, handler)
        }
        return nil
    }

    private func findClickHandler(for node: AttributeNode, root: AttributeNode) -> ((_ relativeX: Int, _ relativeY: Int) -> Void)? {
        if let handler = clickHandlers[node.id] { return handler }
        var ancestor = node.parent
        while let a = ancestor {
            if let handler = clickHandlers[a.id] { return handler }
            ancestor = a.parent
        }
        return nil
    }

    // MARK: - Key Event Routing

    /// Route a key event to the focused node, then bubble up ancestors.
    ///
    /// Routing order: focused node → parent → grandparent → ... → root.
    /// First handler that returns .handled stops propagation.
    /// This matches DOM event bubbling: inner handlers get first chance,
    /// outer containers can provide fallback behavior.
    ///
    /// If no ancestor handles it, tries subtree routing (focused node's
    /// children) as a last resort for composite views that register
    /// handlers on internal structure.
    public func routeKeyEvent(_ event: KeyEvent, root: AttributeNode?) -> Bool {
        guard let focused = keyboardFocusID, let root else { return false }
        return routeKeyEvent(event, root: root, startingFrom: focused)
    }

    /// Route a key event starting from a specific node (instead of
    /// `keyboardFocusID`). Used to dispatch wheel-scroll to the
    /// mouse-hover target rather than the keyboard-focused element —
    /// so scrolling over a long preview pane scrolls *that* preview
    /// even when keyboard focus is on the sidebar list.
    public func routeKeyEvent(_ event: KeyEvent, root: AttributeNode, startingFrom nodeID: NodeID) -> Bool {
        guard let startNode = findNode(id: nodeID, in: root) else { return false }

        if let handler = keyHandlers[nodeID] {
            if handler(event) == .handled { return true }
        }

        var ancestor = startNode.parent
        while let node = ancestor {
            if let handler = keyHandlers[node.id] {
                if handler(event) == .handled { return true }
            }
            ancestor = node.parent
        }

        return routeToSubtree(event, node: startNode)
    }

    private func routeToSubtree(_ event: KeyEvent, node: AttributeNode) -> Bool {
        for child in node.children {
            if let handler = keyHandlers[child.id] {
                if handler(event) == .handled { return true }
            }
            if routeToSubtree(event, node: child) { return true }
        }
        return false
    }

    /// Register a key handler for a node. Called during graph construction.
    public func registerKeyHandler(for nodeID: NodeID, handler: @escaping (KeyEvent) -> KeyEventResult) {
        keyHandlers[nodeID] = handler
    }

    /// Register a click handler for a node. Called during graph construction.
    public func registerClickHandler(for nodeID: NodeID, handler: @escaping (_ relativeX: Int, _ relativeY: Int) -> Void) {
        clickHandlers[nodeID] = handler
    }

    /// Clear all handlers — called at start of each frame before graph update.
    public func clearHandlers() {
        keyHandlers.removeAll(keepingCapacity: true)
        clickHandlers.removeAll(keepingCapacity: true)
    }

    // MARK: - Queries

    public func isKeyboardFocused(_ nodeID: NodeID) -> Bool {
        keyboardFocusID == nodeID
    }

    public func isMouseHovered(_ nodeID: NodeID) -> Bool {
        mouseHoverID == nodeID
    }

    // MARK: - Internal Helpers

    /// Collect focusable nodes under a subtree — used for directional navigation
    /// within a specific layout parent. Uses nodeIndex for the root-level query.
    func collectFocusables(_ node: AttributeNode) -> [AttributeNode] {
        var result: [AttributeNode] = []
        collectFocusablesRecursive(node, into: &result)
        return result
    }

    private func collectFocusablesRecursive(_ node: AttributeNode, into result: inout [AttributeNode]) {
        if node.isFocusable {
            result.append(node)
        }
        for child in node.children {
            collectFocusablesRecursive(child, into: &result)
        }
    }

    /// Public-ish entry point for hit-testing the focusable under a
    /// cursor. Returns nil when the cursor is over inert space.
    /// Used by the runtime's wheel-routing path so the event lands on
    /// (or near) what the user is looking at, instead of a sibling tree
    /// reachable through the root.
    public func findFocusableUnderCursor(x: Int, y: Int, root: AttributeNode) -> AttributeNode? {
        return findFocusableAt(x: x, y: y, in: root)
    }

    /// Find the deepest focusable node whose rect contains the point.
    func findFocusableAt(x: Int, y: Int, in node: AttributeNode) -> AttributeNode? {
        for child in node.children.reversed() {
            if let found = findFocusableAt(x: x, y: y, in: child) {
                return found
            }
        }
        if node.isFocusable {
            let r = node.rect
            if x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height {
                return node
            }
        }
        return nil
    }

    /// Find a node by ID — O(1) via cached index, falls back to tree walk.
    public func findNode(id: NodeID, in root: AttributeNode) -> AttributeNode? {
        if let node = nodeIndex[id] { return node }
        // Fallback for nodes not yet indexed (e.g., modal content added mid-frame)
        return findNodeRecursive(id: id, in: root)
    }

    private func findNodeRecursive(id: NodeID, in node: AttributeNode) -> AttributeNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNodeRecursive(id: id, in: child) { return found }
        }
        return nil
    }

    /// Find the nearest non-structural layout parent.
    /// Skips ForEach/TupleView layout nodes (structural — transparent to navigation).
    private func findLayoutParent(of node: AttributeNode) -> AttributeNode? {
        var current = node.parent
        while let p = current {
            if case .layout = p.kind, !GraphRenderer.isStructuralLayout(p) {
                return p
            }
            current = p.parent
        }
        return nil
    }
}

// MARK: - Focus Direction

public enum FocusDirection {
    case up, down, left, right
}

// MARK: - Key Event Result

public enum KeyEventResult {
    case handled
    case ignored
}
