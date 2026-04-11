/// Centralized focus state manager.
/// Tracks keyboard focus and mouse hover independently.
///
/// Keyboard focus: moved by Tab/Shift+Tab, arrow keys, or mouse click.
/// Mouse hover: tracked independently, follows mouse position.
///
/// Owned by the TerminalRuntime. One per app instance.
public final class FocusEngine: @unchecked Sendable {

    /// Keyboard focus — the node that receives key events.
    /// Moved by Tab/Shift+Tab, arrow keys, or clicking a focusable node.
    public var keyboardFocusID: NodeID?

    /// Mouse hover — the focusable node under the mouse cursor.
    /// Updated on every mouse move. Independent of keyboard focus.
    public var mouseHoverID: NodeID?

    /// Last known mouse position (cell coordinates).
    public var mousePosition: (x: Int, y: Int) = (0, 0)

    /// Registered key handlers — keyed by NodeID.
    /// Populated during graph construction/update from `.onKeyPress` modifiers.
    /// Cleared and rebuilt each frame to stay in sync with the graph.
    var keyHandlers: [NodeID: (KeyEvent) -> KeyEventResult] = [:]

    /// Registered click handlers — keyed by NodeID.
    /// Called when a mouse click lands inside a focusable node's rect.
    /// Receives the click position relative to the node's rect origin.
    var clickHandlers: [NodeID: (_ relativeX: Int, _ relativeY: Int) -> Void] = [:]

    public init() {}

    // MARK: - Keyboard Focus Traversal

    /// Move keyboard focus to the next focusable node (Tab).
    public func focusNext(root: AttributeNode?) {
        guard let root else { return }
        let focusables = collectFocusables(root)
        guard !focusables.isEmpty else { return }

        if let current = keyboardFocusID,
           let idx = focusables.firstIndex(where: { $0.id == current }) {
            let next = (idx + 1) % focusables.count
            keyboardFocusID = focusables[next].id
        } else {
            keyboardFocusID = focusables.first?.id
        }
    }

    /// Move keyboard focus to the previous focusable node (Shift+Tab).
    public func focusPrevious(root: AttributeNode?) {
        guard let root else { return }
        let focusables = collectFocusables(root)
        guard !focusables.isEmpty else { return }

        if let current = keyboardFocusID,
           let idx = focusables.firstIndex(where: { $0.id == current }) {
            let prev = idx == 0 ? focusables.count - 1 : idx - 1
            keyboardFocusID = focusables[prev].id
        } else {
            keyboardFocusID = focusables.last?.id
        }
    }

    /// Directional keyboard focus movement — respects layout axis.
    /// VStack: up/down moves between focusable children.
    /// HStack: left/right moves between focusable children.
    /// Cross-axis falls back to linear traversal.
    public func focusInDirection(_ direction: FocusDirection, root: AttributeNode?) {
        guard let root else { return }
        guard let current = keyboardFocusID else {
            focusNext(root: root)
            return
        }

        guard let currentNode = findNode(id: current, in: root) else { return }
        guard let parentLayout = findLayoutParent(of: currentNode) else {
            switch direction {
            case .up, .left: focusPrevious(root: root)
            case .down, .right: focusNext(root: root)
            }
            return
        }

        if case .layout(let info) = parentLayout.kind {
            let axisMatches: Bool
            switch (info.kind, direction) {
            case (.vstack, .up), (.vstack, .down): axisMatches = true
            case (.hstack, .left), (.hstack, .right): axisMatches = true
            default: axisMatches = false
            }

            if axisMatches {
                let siblings = collectFocusables(parentLayout)
                guard let idx = siblings.firstIndex(where: { $0.id == current }) else {
                    return
                }

                switch direction {
                case .down, .right:
                    if idx + 1 < siblings.count {
                        keyboardFocusID = siblings[idx + 1].id
                    }
                case .up, .left:
                    if idx > 0 {
                        keyboardFocusID = siblings[idx - 1].id
                    }
                }
            } else {
                switch direction {
                case .up, .left: focusPrevious(root: root)
                case .down, .right: focusNext(root: root)
                }
            }
        }
    }

    // MARK: - Mouse Handling

    /// Update hover state from mouse position. Finds the deepest focusable
    /// node at the given position using the resolved rects from the graph.
    public func updateMouseHover(x: Int, y: Int, root: AttributeNode?) {
        mousePosition = (x, y)
        guard let root else {
            mouseHoverID = nil
            return
        }
        mouseHoverID = findFocusableAt(x: x, y: y, in: root)?.id
    }

    /// Handle mouse click — transfer keyboard focus to the clicked focusable node.
    /// If the node has a click handler (e.g., List row selection), call it with
    /// coordinates relative to the node's rect. Otherwise send synthetic enter
    /// to activate buttons/toggles.
    public func handleMouseClick(x: Int, y: Int, root: AttributeNode?) {
        guard let root else { return }
        if let target = findFocusableAt(x: x, y: y, in: root) {
            keyboardFocusID = target.id

            // Check for click handler first (List row selection)
            if let handler = findClickHandler(for: target, root: root) {
                let relX = x - target.rect.x
                let relY = y - target.rect.y
                handler(relX, relY)
            } else {
                // No click handler — activate with synthetic enter (buttons/toggles)
                let syntheticEnter = KeyEvent(key: .enter)
                _ = routeKeyEvent(syntheticEnter, root: root)
            }
        }
    }

    /// Find a click handler for a node — check self and ancestors.
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

    /// Route a key event to the keyboard-focused node's handler.
    /// Walks ancestors (handlers wrap focusable nodes from outside)
    /// and subtree (handlers inside focusable content).
    /// Returns true if the event was consumed.
    public func routeKeyEvent(_ event: KeyEvent, root: AttributeNode?) -> Bool {
        guard let focused = keyboardFocusID, let root else { return false }
        guard let focusedNode = findNode(id: focused, in: root) else { return false }

        // Check the focused node itself
        if let handler = keyHandlers[focused] {
            if handler(event) == .handled { return true }
        }

        // Walk UP — onKeyPress wraps focusable, so handler is on an ancestor
        var ancestor = focusedNode.parent
        while let node = ancestor {
            if let handler = keyHandlers[node.id] {
                if handler(event) == .handled { return true }
            }
            ancestor = node.parent
        }

        // Walk DOWN — handlers inside the focusable subtree
        return routeToSubtree(event, node: focusedNode)
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

    /// Is this node the keyboard-focused node?
    public func isKeyboardFocused(_ nodeID: NodeID) -> Bool {
        keyboardFocusID == nodeID
    }

    /// Is this node under the mouse cursor?
    public func isMouseHovered(_ nodeID: NodeID) -> Bool {
        mouseHoverID == nodeID
    }

    // MARK: - Internal Helpers

    /// Collect all focusable nodes in tree order (depth-first, pre-order).
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

    /// Find the deepest focusable node whose rect contains the point.
    func findFocusableAt(x: Int, y: Int, in node: AttributeNode) -> AttributeNode? {
        // Check children in reverse order (highest z-order first)
        for child in node.children.reversed() {
            if let found = findFocusableAt(x: x, y: y, in: child) {
                return found
            }
        }
        // Check self
        if node.isFocusable {
            let r = node.rect
            if x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height {
                return node
            }
        }
        return nil
    }

    /// Find a node by ID in the tree.
    func findNode(id: NodeID, in root: AttributeNode) -> AttributeNode? {
        if root.id == id { return root }
        for child in root.children {
            if let found = findNode(id: id, in: child) { return found }
        }
        return nil
    }

    /// Walk up from a node to find the nearest layout container parent.
    private func findLayoutParent(of node: AttributeNode) -> AttributeNode? {
        var current = node.parent
        while let p = current {
            if case .layout = p.kind { return p }
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
