/// A scroll view's content as the next frame will draw it, for the passes
/// that place the scroll offset before render: where a view inside starts,
/// how far the content runs, which tagged view sits at a point.
///
/// Render stacks the content at the width it is drawn at — the viewport,
/// one column narrower when the scrollbar takes the last one — with each
/// stack's spacing between children and each modifier's inset before its
/// child. Positions are worked out the same way. Measured at no width, as
/// if nothing wrapped, and stacked with no spacing or insets, a chat
/// transcript's entries were all misplaced: bringing one into sight scrolled
/// when it was already in sight, and to the wrong place when it was not.
struct ScrollContent {
    /// The scroll view's content child.
    let root: AttributeNode
    let axis: ScrollAxis
    /// The viewport's length along the axis.
    let viewportSize: Int
    /// The width vertical content wraps at; a horizontal scroll view lays
    /// its content out at its natural width, the measurer's 0.
    let width: Int
    /// What the content is measured under — the scroll view's own
    /// environment, which render will draw it in.
    let environment: EnvironmentValues

    /// The content of `scroll`, nil when it is not a scroll view with
    /// content. Before the first render the scroll view has no rect, and
    /// `fallback`, the terminal, stands in for its viewport.
    init?(of scroll: AttributeNode, environment: EnvironmentValues, fallback: Size) {
        guard case .layout(let info) = scroll.kind, case .scroll(let axis) = info.kind,
              let content = scroll.children.first else { return nil }
        root = content
        self.axis = axis
        self.environment = environment
        let viewport = Size(width: scroll.rect.width > 0 ? scroll.rect.width : fallback.width,
                            height: scroll.rect.height > 0 ? scroll.rect.height : fallback.height)
        switch axis {
        case .horizontal:
            viewportSize = viewport.width
            width = 0
        case .vertical:
            viewportSize = viewport.height
            // The width render chose last frame, while the viewport is the
            // width it chose it for: worked out again, it is one more
            // measure of the whole content, at a width that evicts the
            // measure render keeps.
            if let drawn = scroll.scrollContentWidth, drawn.viewport == viewport.width {
                width = drawn.content
            } else {
                width = GraphContext.$currentEnvironment.withValue(environment) {
                    GraphRenderer.verticalContentWidth(
                        of: content, viewport: Rect(x: 0, y: 0, width: viewport.width, height: viewport.height),
                        showIndicators: environment.scrollIndicators == .visible)
                }
            }
        }
    }

    /// How far the content runs along the scroll axis.
    var total: Int {
        measured { extent(of: root, width: width) }
    }

    /// Where the view `id` starts along the scroll axis, and its size.
    func position(of id: NodeID) -> (start: Int, size: Int)? {
        measured {
            var found: (start: Int, size: Int)?
            walk(root, start: 0, width: width, size: nil) { node, start, size in
                guard node.id == id else { return false }
                found = (start, size())
                return true
            }
            return found
        }
    }

    /// Every `.id(_:)`-tagged view, in order, with where it starts and ends.
    func taggedExtents() -> [(id: AnyHashable, start: Int, end: Int)] {
        measured {
            var extents: [(id: AnyHashable, start: Int, end: Int)] = []
            walk(root, start: 0, width: width, size: nil) { node, start, size in
                if case .modifier(.explicitID(let id)) = node.kind {
                    extents.append((id, start, start + size()))
                }
                return false
            }
            return extents
        }
    }

    private func measured<T>(_ body: () -> T) -> T {
        GraphContext.$currentEnvironment.withValue(environment, operation: body)
    }

    private func extent(of node: AttributeNode, width: Int) -> Int {
        axis == .horizontal
            ? GraphMeasurer.measureWidth(node)
            : GraphMeasurer.measureHeight(node, proposedWidth: width)
    }

    /// Visit `node` and what lies under it with where each starts along the
    /// axis and its size there, until `visit` returns true; returns whether
    /// it did. `size` is the node's extent when its stack already measured
    /// it, so a row is measured once.
    ///
    /// Mirrors how render stacks a scroll view's content (`renderVStack`):
    /// stack placement lives in render, not in `Layout`, so there is no
    /// placed rect to read before render. Once it moves into `Layout`, this
    /// becomes `measureAndPlace` and a read of each node's rect.
    @discardableResult
    private func walk(_ node: AttributeNode, start: Int, width: Int, size: Int?,
                      _ visit: (AttributeNode, Int, () -> Int) -> Bool) -> Bool {
        if visit(node, start, { size ?? extent(of: node, width: width) }) { return true }
        if node.setsEnvironment {
            var environment = GraphContext.currentEnvironment ?? EnvironmentValues()
            node.applyEnvironment(to: &environment)
            return GraphContext.$currentEnvironment.withValue(environment) {
                walkChildren(of: node, start: start, width: width, visit)
            }
        }
        switch node.kind {
        case .layout(let info) where info.kind == (axis == .vertical ? .vstack : .hstack):
            var position = start
            for child in GraphRenderer.effectiveChildren(of: node) {
                let childSize = extent(of: child, width: width)
                if walk(child, start: position, width: width, size: childSize, visit) { return true }
                position += childSize + info.spacing
            }
            return false
        case .modifier(let effect):
            let child = Layout.childRect(for: effect, outerWidth: width)
            return walkChildren(of: node, start: start + (axis == .vertical ? child.y : child.x),
                                width: width > 0 ? max(1, child.width) : width, visit)
        default:
            return walkChildren(of: node, start: start, width: width, visit)
        }
    }

    private func walkChildren(of node: AttributeNode, start: Int, width: Int,
                              _ visit: (AttributeNode, Int, () -> Int) -> Bool) -> Bool {
        node.children.contains { walk($0, start: start, width: width, size: nil, visit) }
    }
}
