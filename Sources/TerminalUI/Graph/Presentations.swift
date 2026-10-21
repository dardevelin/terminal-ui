/// Every presentation in a tree — modals, alerts, pushed screens — in the
/// order they are drawn.
///
/// A presentation is drawn after the tree, over the whole screen, wherever
/// it was declared (see ``GraphRenderer/render(_:into:context:)``). They are
/// drawn level by level, each over the one before: those declared in the
/// base first, then those declared inside them, and within a level in tree
/// order. The renderer draws this list, and focus containment, hit testing
/// and the pointer all ask for its last entry, so none of them can disagree
/// with the screen.
///
/// Each entry is a presented modal's content; its parent is the modal.
struct Presentations {
    /// Contents by level: index 0 holds those declared in the base.
    private var levels: [[AttributeNode]] = []

    /// Every presentation in the tree under `root`.
    init(in root: AttributeNode) {
        visit(root, level: 0)
    }

    /// Every presented content, in the order the renderer draws them.
    var inDrawOrder: FlattenSequence<[[AttributeNode]]> {
        levels.joined()
    }

    /// The presented content drawn over every other, or nil when none is up.
    var topmost: AttributeNode? {
        levels.last?.last
    }

    /// Where a pointer at (x, y) may reach, given the presentation on top:
    /// the whole tree when there is none, its content when the point is
    /// inside it, and nothing in the dim around it.
    static func pointerScope(x: Int, y: Int, root: AttributeNode, topmost: AttributeNode?) -> AttributeNode? {
        guard let topmost else { return root }
        return topmost.rect.contains(x: x, y: y) ? topmost : nil
    }

    private mutating func visit(_ node: AttributeNode, level: Int) {
        let presented = node.presentedContent
        if let presented {
            while levels.count <= level { levels.append([]) }
            levels[level].append(presented)
        }
        for child in node.children {
            visit(child, level: child === presented ? level + 1 : level)
        }
    }
}
