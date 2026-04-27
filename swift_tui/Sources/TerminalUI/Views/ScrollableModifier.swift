/// Keyboard-scroll opt-in for `ScrollView`.
///
/// Applied as `ScrollView { ... }.scrollable()`, the modifier turns the
/// scroll view into a focusable widget whose arrow, PageUp / PageDown,
/// Home / End keys adjust the scroll offset directly. This is the missing
/// affordance when a ScrollView's content has no interactive descendants
/// — Tab would otherwise have nowhere to land and the user couldn't see
/// anything past the initial viewport.
///
/// Intentionally NOT the default: a sidebar ScrollView that already
/// forwards arrow presses to a sibling selection handler would fight with
/// the implicit focusable, as it did when this behaviour shipped as an
/// auto-detect in an earlier attempt (reverted). `.scrollable()` makes the
/// intent explicit at the call site.
///
/// The modifier wraps the scroll view in:
/// - `.focusable()` so Tab reaches it
/// - An `.onKeyPress` that mutates the scroll-layout node's `scrollOffset`
///   via a closure registered at graph-build time. The closure walks the
///   view hierarchy at press time to find the nearest enclosing scroll
///   layout node — the `ScrollView` directly beneath the modifier.
extension ScrollView {
    /// Make this scroll view keyboard-scrollable. Users press Tab to focus
    /// the view, then arrows / PageUp / PageDown / Home / End to drive the
    /// offset. The content itself doesn't need any focusable descendants.
    public func scrollable() -> some TerminalView {
        ScrollableScrollView(content: self)
    }
}

/// Internal wrapper that the framework can identify via `_GraphScrollable`
/// so graph construction hooks a scroll-axis-aware key handler on the
/// produced focusable node.
public struct ScrollableScrollView<Content: TerminalView>: TerminalView {
    public let content: ScrollView<Content>

    public var body: some TerminalView {
        content
            .focusable()
            .onKeyPress { [content] event in
                handleScrollKey(event, axis: content.axes)
            }
    }
}

/// Central dispatch: map an arrow / page / home-end press to a scroll
/// delta along the modifier-supplied axis. The actual offset mutation
/// targets the nearest enclosing scroll layout on the graph via the
/// focus engine's current-node. We read rect size from the enclosed
/// node's cached rect — render sets it each frame, so by the time a
/// key arrives we already have the viewport geometry.
private func handleScrollKey(_ event: KeyEvent, axis: ScrollAxis) -> KeyEventResult {
    guard let engine = GraphContext.currentFocusEngine else { return .ignored }
    // Prefer the routing-target node (set by FocusEngine.routeKeyEvent
    // during dispatch) over keyboardFocusID. Wheel events route to the
    // focusable under the cursor, NOT the keyboard-focused element —
    // reading keyboardFocusID here would resolve the wrong subtree
    // when the user wheels over a scrollable while keyboard focus is
    // elsewhere. Falls back to keyboardFocusID for direct keypresses
    // (Tab-to-focus then arrow), which preserves the legacy path.
    let ownerID = GraphContext.currentRoutingNodeID ?? engine.keyboardFocusID
    guard let ownerID,
          let root = engine.lastIndexedRoot,
          let owner = engine.findNode(id: ownerID, in: root),
          let scrollNode = findEnclosedScrollNode(owner) else { return .ignored }
    return mutateScroll(event: event, axis: axis, node: scrollNode)
}

private func findEnclosedScrollNode(_ node: AttributeNode) -> AttributeNode? {
    if case .layout(let info) = node.kind, case .scroll = info.kind { return node }
    for child in node.children {
        if let found = findEnclosedScrollNode(child) { return found }
    }
    return nil
}

private func mutateScroll(event: KeyEvent, axis: ScrollAxis, node: AttributeNode) -> KeyEventResult {
    guard let content = node.children.first else { return .ignored }
    let viewport = node.rect
    let contentExtent: Int
    let viewportExtent: Int
    switch axis {
    case .vertical:
        contentExtent = GraphMeasurer.measureHeight(content, proposedWidth: viewport.width)
        viewportExtent = viewport.height
    case .horizontal:
        contentExtent = GraphMeasurer.measureWidth(content)
        viewportExtent = viewport.width
    }
    let maxOffset = max(0, contentExtent - viewportExtent)
    let pageStep = max(1, viewportExtent - 1)

    let delta: Int?
    switch (axis, event.key) {
    case (.vertical, .up), (.horizontal, .left): delta = -1
    case (.vertical, .down), (.horizontal, .right): delta = 1
    case (_, .pageUp): delta = -pageStep
    case (_, .pageDown): delta = pageStep
    case (_, .home): node.scrollOffset = 0; return .handled
    case (_, .end): node.scrollOffset = maxOffset; return .handled
    default: return .ignored
    }
    if let delta {
        node.scrollOffset = max(0, min(maxOffset, node.scrollOffset + delta))
        return .handled
    }
    return .ignored
}
