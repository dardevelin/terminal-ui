/// Centralized focus state manager.
/// Tracks keyboard focus and mouse hover independently.
///
/// Keyboard focus: moved by Tab/Shift+Tab, arrow keys, or mouse click.
/// Mouse hover: tracked independently, follows mouse position.
///
/// Owned by the TerminalRuntime. One per app instance.
/// Always accessed from @MainActor (TerminalRuntime).
///
/// Marked `@unchecked Sendable` because `GraphContext.currentFocusEngine`
/// is `@TaskLocal`, which requires its bound type be `Sendable`. The
/// runtime invariant — only the MainActor touches the engine — is the
/// same one that justifies the unchecked marker.
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
    var keyHandlers: [NodeID: (KeyEvent) -> KeyEventResult] = [:]

    /// Registered click handlers — keyed by NodeID.
    var clickHandlers: [NodeID: (_ relativeX: Int, _ relativeY: Int) -> Void] = [:]

    /// Registered hover handlers — keyed by NodeID. Fired on hover
    /// state transitions only (cursor enters or leaves the rect).
    var hoverHandlers: [NodeID: (_ isHovering: Bool) -> Void] = [:]

    /// Registered paste handlers — keyed by NodeID. Fired when the
    /// runtime decodes an `ESC[200~ … ESC[201~` payload and routes
    /// it to the keyboard-focused subtree.
    var pasteHandlers: [NodeID: (_ payload: String) -> Void] = [:]

    /// IDs whose hover handler currently believes the cursor is INSIDE
    /// their rect. Updated by `applyMouseMove` so transition events
    /// (true on enter, false on leave) fire exactly once. Survives
    /// across frames: only mutated when the hover state for a given
    /// node actually changes.
    private var hoveredHandlerIDs: Set<NodeID> = []

    // MARK: - Cached Indices (rebuilt when graph changes)

    /// O(1) node lookup by ID — replaces recursive tree walk.
    private var nodeIndex: [NodeID: AttributeNode] = [:]

    /// Pre-computed ordered list of focusable nodes (depth-first, pre-order).
    private var focusableList: [AttributeNode] = []

    /// The node focused immediately before a modal took containment, so
    /// dismissal can return the user to where they left off rather than to
    /// the top of the page. Cleared once restored.
    private var focusBeforeContainment: NodeID?

    /// Depth of the innermost presented modal in the current tree, or 0 when
    /// none is presented. Folded into `buildIndexRecursive` rather than
    /// re-derived per access: Tab, Shift-Tab and every mouse click ask for it,
    /// and `rebuildIndex` already visits every node once per frame.
    private var deepestContainmentDepth: Int = 0

    /// Whether a modal presentation is currently containing focus.
    ///
    /// Apps consult this before acting on a global Escape binding: a dialog
    /// is up, so Escape belongs to the dialog and quitting out from under it
    /// would discard the user's context. The runtime enforces the same rule
    /// for its own default quit path.
    public var isContainingFocus: Bool { deepestContainmentDepth > 0 }

    /// Focusables Tab may currently reach, in traversal order. Cached
    /// alongside `focusableList` so the per-keypress path is a stored-array
    /// read rather than a fresh filter allocation.
    private var traversableList: [AttributeNode] = []

    /// The root against which `rebuildIndex` last ran. Exposed so tooling
    /// built on top of FocusEngine (`.scrollable()` modifier's key handler,
    /// inspector probes, remote-control tree queries) can walk subtrees
    /// without threading `root` through every call site.
    public private(set) var lastIndexedRoot: AttributeNode?

    public init() {}

    // MARK: - Index Rebuilding

    /// Rebuild both indices with a single depth-first walk.
    /// Called after graph.update() when the graph structure changed.
    ///
    /// Validates `keyboardFocusID` against the new index — if it
    /// doesn't resolve (graph rebuilt from a structurally different
    /// view, or the previously-focused node was removed), the ID is
    /// cleared to nil. The runtime's auto-focus path then picks the
    /// first focusable in the new tree, instead of routing arrow
    /// events to a dangling NodeID. Regression seen once: a sidebar mouse
    /// click triggered a `state.selectedIndex` change → graph rebuild from
    /// the new page → old NodeID became stale, arrow handlers
    /// stopped firing because routeKeyEvent walked a node not in
    /// the new tree.
    public func rebuildIndex(root: AttributeNode) {
        nodeIndex.removeAll(keepingCapacity: true)
        focusableList.removeAll(keepingCapacity: true)
        deepestContainmentDepth = 0
        lastIndexedRoot = root
        buildIndexRecursive(root)
        traversableList = deepestContainmentDepth == 0
            ? focusableList
            : focusableList.filter { $0.containmentDepth == deepestContainmentDepth }
        if let focused = keyboardFocusID, nodeIndex[focused] == nil {
            keyboardFocusID = nil
        }
        adoptActiveContainment()
    }

    /// Pull focus into a newly presented modal, and release it when that
    /// modal is dismissed.
    ///
    /// Presenting is the moment containment starts, but nothing in the
    /// runtime moves focus on its own: the auto-focus path in the app loop
    /// only fires when nothing is focused at all, so focus would otherwise
    /// sit on the background node it happened to be on and the user would
    /// have to press Tab before the dialog responded.
    ///
    /// Dismissal is the mirror case — focus left inside a subtree that is
    /// no longer presented would leave key events routing to a node the
    /// user can no longer see.
    private func adoptActiveContainment() {
        let candidates = traversableFocusables
        guard !candidates.isEmpty else { return }

        // Focus already sits somewhere legal — nothing to adopt.
        if let focused = keyboardFocusID,
           candidates.contains(where: { $0.id == focused }) {
            return
        }

        if candidates.contains(where: { $0.containmentDepth > 0 }) {
            // A modal is presented and focus is outside it. Remember what
            // the dialog interrupted so dismissing can put the user back
            // where they were — losing the caret's place on dismiss is what
            // makes dialogs feel broken.
            focusBeforeContainment = keyboardFocusID
            keyboardFocusID = candidates.first?.id
            return
        }

        // No containment active. Only restore a remembered node — a plain
        // rebuild with nothing focused must fall through to the runtime's
        // own auto-focus path, which owns the "first focusable" policy.
        if let restored = focusBeforeContainment {
            focusBeforeContainment = nil
            if candidates.contains(where: { $0.id == restored }) {
                keyboardFocusID = restored
            }
        }
    }

    private func buildIndexRecursive(_ node: AttributeNode) {
        nodeIndex[node.id] = node
        // Re-register handlers a cached update did not touch. The live loop
        // clears the handler tables each frame and relies on the graph update
        // to refill them, but a cached composite subtree is skipped by
        // `evaluateBody`, so its `.onKeyPress` / `.onClick` never re-register
        // and the control goes dead. The handler persists on the node across a
        // cached update, and this walk runs unconditionally, so restoring it
        // here makes registration a function of tree shape rather than of body
        // evaluation. A live update that DID re-fire the modifier has already
        // set the same handler; assigning it again is idempotent.
        if let keyHandler = node._keyHandler, keyHandlers[node.id] == nil {
            keyHandlers[node.id] = keyHandler
        }
        if let clickHandler = node._clickHandler, clickHandlers[node.id] == nil {
            clickHandlers[node.id] = clickHandler
        }
        // `.disabled()` writes `EnvironmentValues.isEnabled = false` into
        // the persisted env on every node in the subtree (set during
        // graph construction by the env-modifier traversal). A disabled
        // node drops out of the Tab order entirely — SwiftUI parity.
        if node.participatesInFocus {
            focusableList.append(node)
            deepestContainmentDepth = max(deepestContainmentDepth, node.containmentDepth)
        }
        for child in node.children {
            buildIndexRecursive(child)
        }
    }

    // MARK: - Keyboard Focus Traversal

    /// The focusables Tab may currently reach.
    ///
    /// When a modal is presented, that set is exactly its contents: modality
    /// "prevents interaction with the parent view" (Apple HIG, Patterns →
    /// Modality), and a panel Tab can walk out of is not modal. With modals
    /// nested, the deepest presentation owns focus — the graph already encodes
    /// the nesting via `containmentDepth`, so the engine holds no stack of
    /// its own and cannot drift out of sync with the tree.
    ///
    /// A presented modal with nothing focusable inside contributes no level
    /// and traversal falls back to the outer set, so an empty dialog cannot
    /// deadlock Tab.
    private var traversableFocusables: [AttributeNode] { traversableList }

    /// Move keyboard focus to the next focusable node (Tab order).
    /// Tab order = depth-first pre-order of the view tree, matching visual reading order.
    /// Wraps around: last node → first node.
    public func focusNext() {
        let candidates = traversableFocusables
        guard !candidates.isEmpty else { return }

        if let current = keyboardFocusID,
           let idx = candidates.firstIndex(where: { $0.id == current }) {
            let next = (idx + 1) % candidates.count
            keyboardFocusID = candidates[next].id
        } else {
            // Includes the case where focus sits outside an active
            // containment: presenting a modal pulls focus into it.
            keyboardFocusID = candidates.first?.id
        }
    }

    /// Move keyboard focus to the previous focusable node (Shift+Tab).
    public func focusPrevious() {
        let candidates = traversableFocusables
        guard !candidates.isEmpty else { return }

        if let current = keyboardFocusID,
           let idx = candidates.firstIndex(where: { $0.id == current }) {
            let prev = idx == 0 ? candidates.count - 1 : idx - 1
            keyboardFocusID = candidates[prev].id
        } else {
            keyboardFocusID = candidates.last?.id
        }
    }

    /// True when `node` may take focus under the active containment. Nodes
    /// outside a presented modal are unreachable by both Tab and click.
    private func isReachableUnderActiveContainment(_ node: AttributeNode) -> Bool {
        deepestContainmentDepth == 0 || node.containmentDepth == deepestContainmentDepth
    }


    // MARK: - Directional focus navigation

    /// Move focus by a 4-way direction, dispatching through the
    /// `FocusableContainer` protocol.
    ///
    /// Walks up the focused node's ancestor chain looking for a container
    /// whose `traversalGeometry` accepts the direction, then picks the
    /// neighbouring child along that axis. When the container has no
    /// neighbour, `focusBoundaryPolicy` decides — falling back to the
    /// container's own `isPermeable` when the user set no preference.
    ///
    /// Returns whether focus moved, was deliberately held, or whether no
    /// container claimed the direction at all. Only the last case makes a
    /// Tab-order fallback legitimate; see `FocusMoveResult`.
    @discardableResult
    public func move(_ direction: FocusDirection, root: AttributeNode) -> FocusMoveResult {
        guard let current = keyboardFocusID,
              let currentNode = findNode(id: current, in: root) else {
            // Nothing focused yet — Tab order falls back to "first focusable."
            // `focusNext` no-ops when the tree holds nothing focusable at all,
            // so report what actually happened rather than assuming a move.
            let before = keyboardFocusID
            focusNext()
            return keyboardFocusID == before ? .unhandled : .moved
        }

        let requestedAxis: TraversalGeometry.Axis = (direction == .up || direction == .down)
            ? .vertical
            : .horizontal
        let scope = currentNode.scopeID

        var ancestor: AttributeNode? = currentNode.parent
        var descendantFromAncestor: AttributeNode = currentNode

        while let candidate = ancestor {
            defer {
                descendantFromAncestor = candidate
                ancestor = candidate.parent
            }

            let geom = candidate.traversalGeometry
            // A scope clamps arrows to itself, so a child leading only to
            // out-of-scope focusables is not a candidate. Tab still crosses
            // scopes — that is the SwiftUI convention, and it routes through
            // `focusNext`, not here.
            let children = candidate.focusableChildren()
                .filter { scope == nil || $0.containsFocusable(inScope: scope) }
            guard !children.isEmpty else { continue }

            guard geom.axis == requestedAxis || geom.axis == .both else {
                // A perpendicular container. Impermeable ones stop the walk so
                // arrows cannot tunnel past a stack into whatever sits beyond
                // it; splits let the search continue, which is how a `.down`
                // inside a horizontal split reaches the split above.
                if !geom.isPermeable { return .blocked }
                continue
            }

            // A single candidate means this container holds only the focused
            // subtree — the wrapping stack a composite view like Button or
            // TextInput introduces around its own body. Keep climbing, or
            // every such view becomes an arrow-navigation dead end.
            guard children.count > 1,
                  let idx = children.firstIndex(where: { $0.id == descendantFromAncestor.id })
                      // Fallback for a child that was reshaped or filtered:
                      // find the one whose subtree still holds the focus.
                      ?? children.firstIndex(where: { subtreeContains(node: $0, id: currentNode.id) })
            else { continue }

            if let target = nextChild(in: children, from: idx, direction: direction) {
                keyboardFocusID = leafFocusID(in: target) ?? target.id
                return .moved
            }

            switch boundaryPolicy(for: candidate, focused: currentNode, geometry: geom) {
            case .wrap:
                guard let wrapped = wrapTarget(in: children, from: idx, direction: direction) else {
                    return .blocked
                }
                keyboardFocusID = leafFocusID(in: wrapped) ?? wrapped.id
                return .moved
            case .stay:
                return .blocked
            case .escapeToParent:
                continue  // Try the next container up.
            }
        }

        // Nothing claimed the direction. A scope still forbids leaking out of
        // it, so report that as a deliberate hold rather than an opening for
        // the caller's Tab fallback.
        return scope == nil ? .unhandled : .blocked
    }

    /// Resolve the boundary policy for a container: the nearest explicit
    /// preference, else the container's intrinsic behaviour.
    private func boundaryPolicy(
        for container: AttributeNode,
        focused: AttributeNode,
        geometry: TraversalGeometry
    ) -> FocusBoundaryPolicy {
        if let explicit = container._resolvedEnv?.focusBoundaryPolicy { return explicit }
        if let explicit = focused._resolvedEnv?.focusBoundaryPolicy { return explicit }
        return geometry.isPermeable ? .escapeToParent : .stay
    }

    private func nextChild(
        in children: [AttributeNode],
        from idx: Int,
        direction: FocusDirection
    ) -> AttributeNode? {
        switch direction {
        case .right, .down:
            return idx + 1 < children.count ? children[idx + 1] : nil
        case .left, .up:
            return idx > 0 ? children[idx - 1] : nil
        }
    }

    private func wrapTarget(
        in children: [AttributeNode],
        from idx: Int,
        direction: FocusDirection
    ) -> AttributeNode? {
        guard children.count > 1 else { return nil }
        switch direction {
        case .right, .down: return children.first
        case .left, .up: return children.last
        }
    }

    /// Resolve the focusable leaf id at or below `node`. If `node` is
    /// itself focusable, returns its id. Otherwise picks the first
    /// focusable descendant in declaration order. Returns nil if
    /// the subtree has no focusable — in which case the caller falls
    /// back to focusing the container itself (i3 "container without
    /// leaf widget" pattern).
    private func leafFocusID(in node: AttributeNode) -> NodeID? {
        if node.isFocusable { return node.id }
        for child in node.children {
            if let id = leafFocusID(in: child) { return id }
        }
        return nil
    }

    /// True iff `id` is `node.id` or matches any descendant. Used by
    /// `move(_:)` to map a deeply-nested focused node back to the
    /// container child that owns its subtree.
    private func subtreeContains(node: AttributeNode, id: NodeID) -> Bool {
        if node.id == id { return true }
        for child in node.children {
            if subtreeContains(node: child, id: id) { return true }
        }
        return false
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

    /// Policy-aware mouse-move entry point. Replaces direct calls to
    /// `updateMouseHover` from the runtime so the four `MouseFocusPolicy`
    /// cases route through one place.
    ///
    /// Behaviour matrix:
    ///
    /// | Policy          | mouseHoverID  | keyboardFocusID         | .onHover fires |
    /// |-----------------|---------------|-------------------------|----------------|
    /// | .clickToLock    | hover-target  | unchanged               | yes            |
    /// | .hoverFollows   | hover-target  | hover-target focusable  | yes            |
    /// | .clickOnly      | hover-target  | unchanged               | yes            |
    /// | .disabled       | nil           | unchanged               | yes            |
    ///
    /// `.onHover` callbacks fire under all policies — they're the
    /// SwiftUI-style escape hatch the framework promises to keep
    /// honouring even when auto-routing is disabled.
    public func applyMouseMove(x: Int, y: Int, root: AttributeNode?, policy: MouseFocusPolicy) {
        mousePosition = (x, y)
        // Always notify .onHover transitions — this is what the
        // .disabled escape hatch ultimately relies on.
        fireHoverTransitions(x: x, y: y, root: root)

        guard let root else {
            mouseHoverID = nil
            return
        }

        switch policy {
        case .disabled:
            mouseHoverID = nil
        case .clickToLock, .clickOnly:
            mouseHoverID = findFocusableAt(x: x, y: y, in: root)?.id
        case .hoverFollows:
            let hover = findFocusableAt(x: x, y: y, in: root)?.id
            mouseHoverID = hover
            if let hover {
                keyboardFocusID = hover
            }
        }
    }

    /// Resolve the node that should receive a wheel event under the
    /// active policy. Returns `nil` when the policy elects to drop the
    /// event so the runtime can short-circuit routing.
    ///
    /// - `.clickToLock` / `.hoverFollows`: route to the focusable
    ///   under the cursor. When the cursor is over inert space the
    ///   event is DROPPED — falling back to keyboardFocusID would
    ///   resurrect the bug where wheeling over an inert region
    ///   advances the keyboard-focused element in another subtree.
    /// - `.clickOnly`: route to keyboardFocusID. Wheel is part of the
    ///   active document, not the cursor.
    /// - `.disabled`: no auto-route. Returns nil; runtime drops.
    public func wheelTargetID(x: Int, y: Int, root: AttributeNode?, policy: MouseFocusPolicy) -> NodeID? {
        switch policy {
        case .disabled:
            return nil
        case .clickOnly:
            return keyboardFocusID
        case .clickToLock, .hoverFollows:
            guard let root else { return nil }
            return findFocusableAt(x: x, y: y, in: root)?.id
        }
    }

    /// Fire `.onHover` transitions for every registered hover handler
    /// whose inside-rect state changed since the last move. Inside
    /// rects without registered handlers are ignored — the framework
    /// hover-target tracking is a separate concern (mouseHoverID).
    private func fireHoverTransitions(x: Int, y: Int, root: AttributeNode?) {
        guard let root else {
            // Cursor left the view tree — leave-fire all currently
            // hovered handlers and clear the bookkeeping set.
            for id in hoveredHandlerIDs {
                hoverHandlers[id]?(false)
            }
            hoveredHandlerIDs.removeAll(keepingCapacity: true)
            return
        }
        var nowHovered: Set<NodeID> = []
        collectHoveredHandlers(x: x, y: y, in: root, into: &nowHovered)

        // Fire enter callbacks for newly entered rects.
        for id in nowHovered.subtracting(hoveredHandlerIDs) {
            hoverHandlers[id]?(true)
        }
        // Fire leave callbacks for rects we just exited.
        for id in hoveredHandlerIDs.subtracting(nowHovered) {
            hoverHandlers[id]?(false)
        }
        hoveredHandlerIDs = nowHovered
    }

    /// Walk the tree collecting IDs of nodes that have a registered
    /// hover handler AND whose rect contains (x, y). Order does not
    /// matter — the result is consumed as a Set.
    private func collectHoveredHandlers(x: Int, y: Int, in node: AttributeNode, into result: inout Set<NodeID>) {
        let r = node.rect
        if hoverHandlers[node.id] != nil,
           x >= r.x, x < r.x + r.width,
           y >= r.y, y < r.y + r.height
        {
            result.insert(node.id)
        }
        for child in node.children {
            collectHoveredHandlers(x: x, y: y, in: child, into: &result)
        }
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
            // The same containment rule Tab obeys: while a modal is
            // presented, clicking the content it dims must not pull focus
            // out of the dialog. The click is swallowed rather than
            // redirected — dismissal is the modal's own explicit action.
            guard isReachableUnderActiveContainment(target) else { return }
            keyboardFocusID = target.id
            if let handler = findClickHandler(for: target, root: root) {
                let relX = x - target.rect.x
                let relY = y - target.rect.y
                handler(relX, relY)
            } else {
                // Synthesize `.activate` (not `.enter`) so click-to-
                // activate works for Button without inserting newlines
                // into focused text-input components. Button treats
                // `.activate` the same as `.enter`; TextArea / TextInput /
                // PromptInput ignore it because their `.enter` arms
                // interpret Enter as user input.
                let syntheticActivate = KeyEvent(key: .activate)
                _ = routeKeyEvent(syntheticActivate, root: root)
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

    /// Click path under `MouseFocusPolicy.disabled`. Fires the
    /// deepest registered `.onClick` handler under the cursor (if
    /// any) WITHOUT promoting any node to keyboard focus and without
    /// synthesising an Enter on focusables. The escape hatch's whole
    /// point: framework auto-routing is off, callbacks still run.
    public func fireClickHandlerOnly(x: Int, y: Int, root: AttributeNode) {
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

        // Bind `currentRoutingNodeID` so handlers like `.scrollable()`'s
        // arrow dispatch resolve the owning node from the routing
        // target rather than `keyboardFocusID`. Wheel
        // routes the synthetic arrow to the hover target, NOT the
        // focused element, so handlers that previously read
        // `keyboardFocusID` would resolve the wrong subtree.
        return GraphContext.$currentRoutingNodeID.withValue(nodeID) {
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

    /// Register a hover handler for a node. Called during graph
    /// construction by the `.onHover` modifier. The handler fires on
    /// state transitions only (see `applyMouseMove`).
    public func registerHoverHandler(for nodeID: NodeID, handler: @escaping (_ isHovering: Bool) -> Void) {
        hoverHandlers[nodeID] = handler
    }

    /// Register a paste handler for a node. Called during graph
    /// construction by the `.onPaste` modifier.
    public func registerPasteHandler(for nodeID: NodeID, handler: @escaping (_ payload: String) -> Void) {
        pasteHandlers[nodeID] = handler
    }

    /// Route a bracketed-paste payload starting at the keyboard-focused
    /// node, walking up to the root. The first ancestor with a registered
    /// `.onPaste` handler claims the payload. Returns true iff a handler
    /// fired — caller drops the payload otherwise (safer than fanning
    /// out fast-typed character events the user did NOT type).
    public func routePasteEvent(_ payload: String, root: AttributeNode?) -> Bool {
        guard let focused = keyboardFocusID, let root else { return false }
        guard let startNode = findNode(id: focused, in: root) else { return false }

        if let handler = pasteHandlers[focused] {
            handler(payload)
            return true
        }
        var ancestor = startNode.parent
        while let node = ancestor {
            if let handler = pasteHandlers[node.id] {
                handler(payload)
                return true
            }
            ancestor = node.parent
        }
        return false
    }

    /// True when the given node has a registered hover handler. Used
    /// by harness code that needs to locate the hover-target node by
    /// walking the tree.
    public func hasHoverHandler(for nodeID: NodeID) -> Bool {
        hoverHandlers[nodeID] != nil
    }

    /// Clear all handlers — called at start of each frame before graph update.
    public func clearHandlers() {
        keyHandlers.removeAll(keepingCapacity: true)
        clickHandlers.removeAll(keepingCapacity: true)
        hoverHandlers.removeAll(keepingCapacity: true)
        pasteHandlers.removeAll(keepingCapacity: true)
        // hoveredHandlerIDs is intentionally NOT cleared — it tracks
        // cursor-inside state across frames so a node that survives
        // the rebuild keeps its hover transition bookkeeping.
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
        if node.participatesInFocus {
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

    /// Resolve EnvironmentValues at a cursor coordinate by walking the
    /// tree to the deepest node whose rect contains (x, y) and reading
    /// the snapshot the renderer captured there. Falls back to the
    /// root's snapshot, then to defaults — so events arriving over
    /// inert space still get a sensible env (matches SwiftUI's
    /// "root env applies until overridden" model).
    ///
    /// Used by the runtime to pick `mouseFocusPolicy` per subtree:
    /// Storybook's preview pane can carry `.disabled` while the
    /// surrounding shell stays on `.clickToLock`.
    public func resolveEnv(x: Int, y: Int, root: AttributeNode) -> EnvironmentValues {
        if let deepest = findDeepestRectContaining(x: x, y: y, in: root),
           let env = deepest._resolvedEnv
        {
            return env
        }
        return root._resolvedEnv ?? EnvironmentValues()
    }

    /// Walk the tree depth-first looking for the deepest node whose
    /// rect contains the point. Unlike `findFocusableAt`, this does
    /// NOT require `isFocusable`; it just wants a rect — the env is
    /// readable from any node, focusable or not.
    private func findDeepestRectContaining(x: Int, y: Int, in node: AttributeNode) -> AttributeNode? {
        let r = node.rect
        let containsHere = x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
        // Children walked deepest-first so a leaf's rect wins over an
        // ancestor's larger rect.
        for child in node.children.reversed() {
            if let hit = findDeepestRectContaining(x: x, y: y, in: child) {
                return hit
            }
        }
        return containsHere ? node : nil
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

    /// The currently keyboard-focused node, or `nil` if no focusable
    /// is selected (e.g. the app has no focusables yet, or focus was
    /// just reset). Falls back to the root when a focused-id is set
    /// but the node has been detached — the caller can still walk to
    /// root from the root itself, so action dispatch finds outer
    /// scopes even with stale focus state.
    public func focusedNode(in root: AttributeNode?) -> AttributeNode? {
        guard let root else { return nil }
        guard let id = keyboardFocusID else { return root }
        return findNode(id: id, in: root) ?? root
    }

    private func findNodeRecursive(id: NodeID, in node: AttributeNode) -> AttributeNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNodeRecursive(id: id, in: child) { return found }
        }
        return nil
    }

    // MARK: - Hovered-ScrollView Wheel Fallback

    /// Walk the tree deepest-first looking for the deepest scroll
    /// layout node whose rect contains (x, y). Used by the runtime
    /// when `wheelTargetID` returns nil — i.e. the cursor is over a
    /// bare `ScrollView` that has no `.scrollable()` (no enclosing
    /// focusable). Mirrors SwiftUI's wheel-on-scroll-region contract:
    /// the wheel is owned by the deepest scroll region under the
    /// cursor, regardless of focus reachability.
    public func findScrollNodeAt(x: Int, y: Int, root: AttributeNode) -> AttributeNode? {
        for child in root.children.reversed() {
            if let hit = findScrollNodeAt(x: x, y: y, root: child) {
                return hit
            }
        }
        if case .layout(let info) = root.kind, case .scroll = info.kind {
            let r = root.rect
            if x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height {
                return root
            }
        }
        return nil
    }

    /// Dispatch a synthetic wheel event (arrow key) directly to the
    /// given scroll layout node, mutating its `scrollOffset` per the
    /// node's axis. Skips the focusable / `routeKeyEvent` chain — this
    /// path is the wheel-on-bare-ScrollView fallback used when no
    /// focusable lives under the cursor.
    ///
    /// Mirrors `ScrollableModifier.handleScrollKey` but resolves the
    /// scroll node directly instead of walking up from a focused
    /// owner. Mutation logic lives in `_ScrollMath.mutateOffset` so
    /// both paths share the same axis / page-step / max-offset rules.
    public func dispatchWheelToScrollNode(_ node: AttributeNode, event: KeyEvent) {
        guard case .layout(let info) = node.kind, case .scroll(let axis) = info.kind else {
            return
        }
        _ = _ScrollMath.mutateOffset(event: event, axis: axis, node: node)
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
