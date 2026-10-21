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

    /// The content of the presentation drawn on top, which contains focus.
    /// Read from the tree once per `rebuildIndex` rather than per access:
    /// Tab, Shift-Tab and every mouse event ask for it.
    ///
    /// When it has no focusable descendants, keyboard focus adopts it
    /// instead — so `routeKeyEvent`'s ancestor walk starts inside the
    /// presentation and reaches its handlers (a pushed screen's Esc-pop, a
    /// dialog's shortcuts) rather than routing from stale outside focus that
    /// falls back to root.
    private var topmostPresentation: AttributeNode?

    /// Whether a modal presentation is currently containing focus.
    ///
    /// Apps consult this before acting on a global Escape binding: a dialog
    /// is up, so Escape belongs to the dialog and quitting out from under it
    /// would discard the user's context. The runtime enforces the same rule
    /// for its own default quit path.
    public var isContainingFocus: Bool { topmostPresentation != nil }

    /// Focusables Tab may currently reach, in traversal order. Cached
    /// alongside `focusableList` so the per-keypress path is a stored-array
    /// read rather than a fresh filter allocation.
    private var traversableList: [AttributeNode] = []

    /// The root against which `rebuildIndex` last ran. Exposed so tooling
    /// built on top of FocusEngine (`.scrollable()` modifier's key handler,
    /// inspector probes, remote-control tree queries) can walk subtrees
    /// without threading `root` through every call site.
    public private(set) var lastIndexedRoot: AttributeNode?

    /// Creates an empty engine — nothing focused, no handlers, no index.
    /// The runtime rebuilds the index after each graph update; queries are
    /// only meaningful once `rebuildIndex` has run against the current tree.
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
        // Containment is a fact about the tree, not about what Tab can
        // reach: a presented screen made only of Text still owns Escape.
        topmostPresentation = Presentations(in: root).topmost
        lastIndexedRoot = root
        buildIndexRecursive(root)
        traversableList = topmostPresentation.map { content in
            focusableList.filter { $0.isWithin(content) }
        } ?? focusableList
        // A presentation that replaces its base (a pushed screen blanking
        // the root) removes the focused node from the tree, so the stale
        // clear below would erase the very ID dismissal should restore.
        // Capture it first; the ID stays unroutable either way, and the
        // restore path only applies IDs present in the rebuilt tree.
        let focusBeforeReindex = keyboardFocusID
        if let focused = keyboardFocusID, nodeIndex[focused] == nil {
            keyboardFocusID = nil
        }
        adoptActiveContainment(interrupted: focusBeforeReindex)
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
    private func adoptActiveContainment(interrupted: NodeID?) {
        let candidates = traversableFocusables

        if let presentationRoot = topmostPresentation?.id {
            // Focus already sits somewhere legal inside the presentation —
            // nothing to adopt.
            if let focused = keyboardFocusID,
               focused == presentationRoot
                || candidates.contains(where: { $0.id == focused }) {
                return
            }
            // A modal is presented and focus is outside it. Remember what
            // the dialog interrupted so dismissing can put the user back
            // where they were — losing the caret's place on dismiss is what
            // makes dialogs feel broken. Single-shot for the whole
            // containment session: a deeper push must not overwrite the
            // remembered node with one inside the outer presentation, or
            // the full unwind lands somewhere the user never was.
            //
            // A presentation with no focusable descendants still owns the
            // keyboard: focus falls to the presented subtree's root so key
            // routing starts inside it. Tab then has nowhere to go, which
            // is correct — modality "prevents interaction with the parent
            // view" (Apple HIG, Patterns → Modality), and the covered
            // content must stay unreachable.
            if focusBeforeContainment == nil {
                focusBeforeContainment = interrupted
            }
            keyboardFocusID = candidates.first?.id ?? presentationRoot
            return
        }

        guard !candidates.isEmpty else { return }

        // Focus already sits somewhere legal — nothing to adopt.
        if let focused = keyboardFocusID,
           candidates.contains(where: { $0.id == focused }) {
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
    /// Modality), and a panel Tab can walk out of is not modal. With several
    /// up, the one drawn on top owns focus — `Presentations` is read from the
    /// tree on every index rebuild, so the engine holds no stack of its own
    /// and cannot drift out of sync with the screen.
    ///
    /// A presented modal with nothing focusable inside still owns the level:
    /// Tab has nothing to reach — correct, since the covered content must
    /// stay unreachable — and the keyboard routes to the presentation root
    /// instead. The user is never stranded: the presentation's own handlers
    /// (Esc-pop, dialog shortcuts) get the keys, and Ctrl+C stays
    /// unconditional.
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

    /// Where a pointer at (x, y) may reach: the whole tree, or — while a
    /// presentation is up — only the content of the one on top, and nothing
    /// at all in the dim around it. The covered content must not answer a
    /// click, a hover or the wheel any more than it answers Tab.
    private func pointerScope(x: Int, y: Int, root: AttributeNode) -> AttributeNode? {
        Presentations.pointerScope(x: x, y: y, root: root, topmost: topmostPresentation)
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
                      ?? children.firstIndex(where: { currentNode.isWithin($0) })
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

    // MARK: - Mouse Handling

    /// Update hover state from mouse position.
    public func updateMouseHover(x: Int, y: Int, root: AttributeNode?) {
        mousePosition = (x, y)
        mouseHoverID = root
            .flatMap { pointerScope(x: x, y: y, root: $0) }
            .flatMap { findFocusableAt(x: x, y: y, in: $0) }?.id
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
        let scope = root.flatMap { pointerScope(x: x, y: y, root: $0) }
        // Always notify .onHover transitions — this is what the
        // .disabled escape hatch ultimately relies on.
        fireHoverTransitions(x: x, y: y, root: scope)

        guard let scope else {
            mouseHoverID = nil
            return
        }

        switch policy {
        case .disabled:
            mouseHoverID = nil
        case .clickToLock, .clickOnly:
            mouseHoverID = findFocusableAt(x: x, y: y, in: scope)?.id
        case .hoverFollows:
            let hover = findFocusableAt(x: x, y: y, in: scope)?.id
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
            guard let root, let scope = pointerScope(x: x, y: y, root: root) else { return nil }
            return findFocusableAt(x: x, y: y, in: scope)?.id
        }
    }

    /// Scroll the region holding focus, when focus itself has nowhere left to
    /// go in that direction.
    ///
    /// A form's last rows are routinely the ones with nothing to focus — a
    /// version string, a gauge, a footer. Scroll-to-focused only ever follows
    /// focus, so the viewport stopped where the last control was and that tail
    /// was unreachable from the keyboard: laid out, drawn, and impossible to
    /// bring into view. This is the keyboard's version of the rule the wheel
    /// already follows — the deepest enclosing scroll region takes what
    /// nothing else wanted.
    ///
    /// Returns whether the viewport actually moved, so a key that changes
    /// nothing stays available to whatever handles it next rather than being
    /// silently swallowed at the end of a list.
    public func scrollFocusedRegion(_ direction: FocusDirection, root: AttributeNode) -> Bool {
        guard let focusedID = keyboardFocusID,
              let focused = findNode(id: focusedID, in: root) else { return false }

        let wantedAxis: ScrollAxis = (direction == .up || direction == .down)
            ? .vertical
            : .horizontal
        let key: Key
        switch direction {
        case .up: key = .up
        case .down: key = .down
        case .left: key = .left
        case .right: key = .right
        }

        var ancestor: AttributeNode? = focused.parent
        while let node = ancestor {
            defer { ancestor = node.parent }
            guard case .layout(let info) = node.kind,
                  case .scroll(let axis) = info.kind, axis == wantedAxis else { continue }
            let before = node.scrollOffset
            _ScrollMath.mutateOffset(event: KeyEvent(key: key), axis: axis, node: node)
            return node.scrollOffset != before
        }
        return false
    }

    /// Route a wheel event to whatever owns it under the cursor.
    ///
    /// A focusable under the cursor gets first refusal, because some of them
    /// scroll their own contents — a `List`, a `TextArea`, anything holding
    /// its own offset. When one declines the event, the wheel belongs to the
    /// deepest scroll region under the cursor, the same rule that applies when
    /// there is no focusable there at all.
    ///
    /// Trying only the focusable and stopping is what left a `Form` unable to
    /// scroll under the mouse: every row is focusable and no row does anything
    /// with a wheel, so the event died on a control that had already refused
    /// it while the scroll view enclosing it never heard about it. The user
    /// reads that as "the wheel works over the gaps and not over the rows".
    ///
    /// The policy decides where it lands: the focusable under the cursor for
    /// `.clickToLock` and `.hoverFollows`, the keyboard-focused view for
    /// `.clickOnly`, nowhere for `.disabled`.
    ///
    /// `steps` delivers a run of identical wheel events at once: the target
    /// is found once — the tree walks that find it are the cost — and moved
    /// step by step, so a `List` at its end hands the rest to the scroll view
    /// holding it. A step nothing takes changes nothing, so the steps after it
    /// would be refused too, and the run ends there. Returns whether anything
    /// took the event.
    public func routeWheel(
        _ event: KeyEvent,
        root: AttributeNode,
        x: Int,
        y: Int,
        policy: MouseFocusPolicy,
        steps: Int = 1
    ) -> Bool {
        let focusable = wheelTargetID(x: x, y: y, root: root, policy: policy)
            .flatMap { findNode(id: $0, in: root) }
        // `.disabled` drops auto-routed wheel events by policy, and
        // `wheelTargetID` has already returned nil for it.
        let scrollNode = policy == .disabled ? nil : findScrollNodeAt(x: x, y: y, root: root)

        // Deepest under the cursor gets first refusal. A control inside a
        // scroll view is deeper than it, so the control is asked first and a
        // form row that ignores the wheel falls through to the pane holding
        // it. A scroll view inside a focusable *area* is the other way round:
        // the area exists so the engine has something to cycle to, and a wheel
        // over the list it contains means scroll the list — not "operate the
        // area", which for a list means moving its selection.
        let focusableFirst = depth(of: focusable) >= depth(of: scrollNode)

        func step() -> Bool {
            if focusableFirst, let id = focusable?.id,
               routeKeyEvent(event, root: root, startingFrom: id) {
                return true
            }
            if let scrollNode {
                let before = scrollNode.scrollOffset
                dispatchWheelToScrollNode(scrollNode, event: event)
                if scrollNode.scrollOffset != before { return true }
            }
            if !focusableFirst, let id = focusable?.id {
                return routeKeyEvent(event, root: root, startingFrom: id)
            }
            return false
        }
        var taken = false
        for _ in 0..<steps {
            guard step() else { break }
            taken = true
        }
        return taken
    }

    /// How far a node sits from the root, or -1 for no node — so an absent
    /// candidate always loses a depth comparison.
    private func depth(of node: AttributeNode?) -> Int {
        guard var current = node else { return -1 }
        var depth = 0
        while let parent = current.parent {
            depth += 1
            current = parent
        }
        return depth
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
        if hoverHandlers[node.id] != nil, node.rect.contains(x: x, y: y) {
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
        // The same containment rule Tab obeys: while a modal is presented,
        // clicking the content it dims must not reach it. The click is
        // swallowed rather than redirected — dismissal is the modal's own
        // explicit action.
        guard let root, let scope = pointerScope(x: x, y: y, root: root) else { return }
        // A scrollbar is painted over the content's last column, so the cells
        // it occupies belong to the scroll view, not to the row underneath —
        // otherwise a press on the track would both scroll and activate
        // whatever it was drawn on top of.
        if handleScrollAffordanceClick(x: x, y: y, root: scope) { return }
        if let target = findFocusableAt(x: x, y: y, in: scope) {
            keyboardFocusID = target.id
            // A row inside a focusable pane keeps its own click handler.
            // Deepest wins is the rule the non-focusable path already follows,
            // and making a whole area focusable — which is how an app gives
            // the engine something to cycle to — must not swallow the clicks
            // of everything inside it.
            if let (inner, innerHandler) = findClickableAt(x: x, y: y, in: target),
               inner.id != target.id {
                innerHandler(x - inner.rect.x, y - inner.rect.y)
                return
            }
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
        if let (target, handler) = findClickableAt(x: x, y: y, in: scope) {
            let relX = x - target.rect.x
            let relY = y - target.rect.y
            handler(relX, relY)
        }
    }

    /// Press on a scrollbar: the ends step, anywhere else on the track jumps
    /// the viewport to that position. Returns whether the press was taken.
    ///
    /// Dragging the thumb is deliberately absent — a press-move-release
    /// gesture is a different mechanism, and stepping and jumping are what
    /// make the drawn affordance answer at all.
    private func handleScrollAffordanceClick(x: Int, y: Int, root: AttributeNode) -> Bool {
        guard let (node, axis, affordance) = findScrollAffordanceAt(x: x, y: y, in: root) else {
            return false
        }
        let position = axis == .vertical ? y - affordance.y : x - affordance.x
        let extent = axis == .vertical ? affordance.height : affordance.width
        switch position {
        case 0:
            _ScrollMath.mutateOffset(
                event: KeyEvent(key: axis == .vertical ? .up : .left), axis: axis, node: node
            )
        case extent - 1:
            _ScrollMath.mutateOffset(
                event: KeyEvent(key: axis == .vertical ? .down : .right), axis: axis, node: node
            )
        default:
            // The ends are the step buttons, so the track the press maps onto
            // is what lies between them.
            _ScrollMath.jump(
                toFraction: Double(position - 1) / Double(max(1, extent - 3)),
                axis: axis, node: node
            )
        }
        return true
    }

    /// The deepest scroll node whose painted scrollbar covers (x, y).
    private func findScrollAffordanceAt(x: Int, y: Int, in node: AttributeNode)
        -> (AttributeNode, ScrollAxis, Rect)?
    {
        for child in node.children.reversed() {
            if let hit = findScrollAffordanceAt(x: x, y: y, in: child) { return hit }
        }
        guard case .layout(let info) = node.kind, case .scroll(let axis) = info.kind,
              let affordance = node.scrollAffordanceRect,
              affordance.contains(x: x, y: y)
        else { return nil }
        return (node, axis, affordance)
    }

    /// Click path under `MouseFocusPolicy.disabled`. Fires the
    /// deepest registered `.onClick` handler under the cursor (if
    /// any) WITHOUT promoting any node to keyboard focus and without
    /// synthesising an Enter on focusables. The escape hatch's whole
    /// point: framework auto-routing is off, callbacks still run.
    public func fireClickHandlerOnly(x: Int, y: Int, root: AttributeNode) {
        if let scope = pointerScope(x: x, y: y, root: root),
           let (target, handler) = findClickableAt(x: x, y: y, in: scope) {
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
        if node.rect.contains(x: x, y: y),
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

            var ancestor = startNode.parentWithinPresentation
            while let node = ancestor {
                if let handler = keyHandlers[node.id] {
                    if handler(event) == .handled { return true }
                }
                ancestor = node.parentWithinPresentation
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

    /// True iff `nodeID` currently holds keyboard focus. At most one node
    /// holds it; Tab/Shift+Tab (and arrows, where enabled) move it. Mouse
    /// hover is tracked independently — see ``isMouseHovered(_:)``.
    public func isKeyboardFocused(_ nodeID: NodeID) -> Bool {
        keyboardFocusID == nodeID
    }

    /// True iff the mouse cursor sits inside `nodeID`'s rect. Independent of
    /// keyboard focus: under the default `.clickToLock` policy, hovering never
    /// moves focus — clicking promotes the hover target to keyboard focus.
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

    /// The focusable under a cursor, or nil over inert space or the dim
    /// around a presented dialog.
    public func findFocusableUnderCursor(x: Int, y: Int, root: AttributeNode) -> AttributeNode? {
        pointerScope(x: x, y: y, root: root).flatMap { findFocusableAt(x: x, y: y, in: $0) }
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
        if let scope = pointerScope(x: x, y: y, root: root),
           let deepest = findDeepestRectContaining(x: x, y: y, in: scope),
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
        let containsHere = node.rect.contains(x: x, y: y)
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
            if node.rect.contains(x: x, y: y) {
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

    /// The node a key is addressed to: the keyboard-focused node, or — when
    /// nothing holds focus, or the focused node has been detached — the
    /// window itself. `nil` only when there is no graph.
    ///
    /// The window is stood for by ``windowContent(in:)``, not by the root.
    /// Action dispatch walks *up* from this node, and every scope an app
    /// attaches around its content sits below the root; starting there
    /// skipped all of them, so an app with no focusable view could not
    /// override the framework's Escape or Ctrl+C at all.
    public func focusedNode(in root: AttributeNode?) -> AttributeNode? {
        guard let root else { return nil }
        guard let id = keyboardFocusID, let node = findNode(id: id, in: root) else {
            return Self.windowContent(in: root)
        }
        return node
    }

    /// The innermost node that still wraps the whole window: down from the
    /// root, stopping at the first node that lays out more than one child.
    /// A modifier's second child is an overlay or background drawn over its
    /// content, not a part of it, so a modifier is followed into its content.
    /// Walking up from here meets every modifier applied to the app as a
    /// whole, and none that belongs to one part of it.
    static func windowContent(in root: AttributeNode) -> AttributeNode {
        var node = root
        while true {
            if case .modifier = node.kind, let content = node.children.first {
                node = content
            } else if node.children.count == 1 {
                node = node.children[0]
            } else {
                return node
            }
        }
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
        pointerScope(x: x, y: y, root: root).flatMap { findScrollNode(x: x, y: y, in: $0) }
    }

    private func findScrollNode(x: Int, y: Int, in node: AttributeNode) -> AttributeNode? {
        for child in node.children.reversed() {
            if let hit = findScrollNode(x: x, y: y, in: child) {
                return hit
            }
        }
        if case .layout(let info) = node.kind, case .scroll = info.kind {
            if node.rect.contains(x: x, y: y) {
                return node
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

/// The spatial direction of an arrow-key focus move.
public enum FocusDirection {
    /// Toward the top of the screen.
    case up
    /// Toward the bottom of the screen.
    case down
    /// Toward the left edge.
    case left
    /// Toward the right edge.
    case right
}

// MARK: - Key Event Result

/// What a key handler tells the dispatcher about an event.
public enum KeyEventResult {
    /// The event was consumed; dispatch stops here.
    case handled
    /// The event was not consumed; it bubbles to the next handler.
    case ignored
}
