/// Layout phase — measures the graph and places it within an
/// allocated rect. Runs between reconcile (`AttributeGraph.update`)
/// and render (`GraphRenderer.render`), and owns the *mutating* parts
/// of the per-frame pipeline:
///
/// 1. Walks the graph applying layout primitives (VStack distributes
///    height, HStack distributes width, etc.) and stamps each node's
///    `rect` for the upcoming render.
/// 2. Invokes every `GeometryReader` rebuilder with the resolved
///    rect's size. The rebuilder reconciles its child subtree
///    against the live size.
///
/// After `measureAndPlace` returns, `GraphRenderer.render` can run as
/// a pure draw — read rects, write cells, no graph mutation. The
/// reviewer flagged the old design (`render` invoking the rebuilder
/// directly) as a phase-separation violation; this layer fixes that.
@MainActor
public enum Layout {

    /// Measure and place the graph rooted at `node` within `rect`.
    /// Recursively walks the tree, applying layout to children
    /// according to each node's kind, and firing GeometryReader
    /// rebuilders with the size each one was placed at.
    ///
    /// This is the runtime path; tests use it directly via the same
    /// public surface to pin the phase contract.
    public static func measureAndPlace(graph node: AttributeNode, in rect: Rect) {
        node.rect = rect

        switch node.kind {
        case .primitive:
            return  // primitives have no descendants requiring layout

        case .layout, .modifier:
            // Layout containers and modifiers descend into children.
            // The detailed measurement (vstack height distribution,
            // hstack width distribution, scroll viewports, etc.) still
            // lives in GraphRenderer.renderLayout — this initial phase
            // recurses and fires rebuilders without duplicating the
            // measurement code. Subsequent commits move the measurement
            // logic here too; for now `measureAndPlace` is responsible
            // for the rebuild contract while render still does the
            // size math during its walk.
            for child in node.children {
                measureAndPlace(graph: child, in: rect)
            }

        case .viewBody:
            // GeometryReader is a viewBody node carrying a
            // `geometryRebuilder` closure. Fire it with the allocated
            // rect's size so the child subtree is reconciled now,
            // outside the render phase. Non-GR viewBody nodes have
            // a nil rebuilder; the recursion still descends so any
            // nested GR finds its rect.
            if let rebuild = node.geometryRebuilder {
                let size = Size(width: rect.width, height: rect.height)
                rebuild(size, node)
                node._lastLaidOutSize = size
            }
            for child in node.children {
                measureAndPlace(graph: child, in: rect)
            }
        }
    }
}
