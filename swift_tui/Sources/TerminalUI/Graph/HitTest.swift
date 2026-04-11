/// Hit testing — find which node owns a given screen coordinate.
/// After layout/render, each node has a resolved rect.
/// Hit test walks the graph depth-first (last child first for z-order)
/// and returns the deepest node containing the point.

public enum HitTest {

    /// Find the deepest node at the given screen coordinate.
    /// Returns the node and its full ancestor chain.
    public static func nodeAt(x: Int, y: Int, root: AttributeNode?) -> HitResult? {
        guard let root else { return nil }
        var path: [AttributeNode] = []
        if let found = search(x: x, y: y, node: root, path: &path) {
            return HitResult(node: found, path: path)
        }
        return nil
    }

    private static func search(x: Int, y: Int, node: AttributeNode, path: inout [AttributeNode]) -> AttributeNode? {
        let r = node.rect
        // Check if point is within this node's rect
        guard x >= r.intX, x < r.intX + r.intWidth,
              y >= r.intY, y < r.intY + r.intHeight else {
            return nil
        }

        path.append(node)

        // Search children in reverse order (last child = highest z-order)
        for child in node.children.reversed() {
            if let found = search(x: x, y: y, node: child, path: &path) {
                return found
            }
        }

        // No child contains the point — this node owns it
        return node
    }
}

public struct HitResult {
    /// The deepest node at the hit point
    public let node: AttributeNode
    /// Ancestor chain from root to the hit node
    public let path: [AttributeNode]

    /// Formatted description of declared modifiers on this node
    public var declaredValues: [(String, String)] {
        var values: [(String, String)] = []

        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let s):
                values.append(("type", "Text"))
                values.append(("content", s.count > 30 ? String(s.prefix(30)) + "..." : s))
            case .spacer:
                values.append(("type", "Spacer"))
            case .divider:
                values.append(("type", "Divider"))
            case .progressBar(let v, _, _, _):
                values.append(("type", "ProgressBar"))
                values.append(("value", "\(Int(v * 100))%"))
            case .spinner(let f, _):
                values.append(("type", "Spinner"))
                values.append(("frame", "\(f)"))
            case .empty:
                values.append(("type", "Empty"))
            }

        case .layout(let info):
            switch info.kind {
            case .vstack: values.append(("type", "VStack"))
            case .hstack: values.append(("type", "HStack"))
            case .zstack: values.append(("type", "ZStack"))
            }
            values.append(("children", "\(node.children.count)"))

        case .modifier(let effect):
            switch effect {
            case .foreground(let c): values.append(("modifier", "foreground(\(c))"))
            case .background(let c): values.append(("modifier", "background(\(c))"))
            case .bold: values.append(("modifier", "bold"))
            case .italic: values.append(("modifier", "italic"))
            case .underline: values.append(("modifier", "underline"))
            case .padding(let n): values.append(("modifier", "padding(\(n))"))
            case .border(let s): values.append(("modifier", "border(\(s))"))
            case .frame(let w, let h): values.append(("modifier", "frame(\(w ?? 0)x\(h ?? 0))"))
            case .explicitID(let id): values.append(("modifier", "id(\(id))"))
            case .overlay: values.append(("modifier", "overlay"))
            case .backgroundView: values.append(("modifier", "backgroundView"))
            case .modal(let p): values.append(("modifier", "modal(\(p))"))
            }

        case .viewBody(let info):
            values.append(("type", info.viewTypeName))
        }

        return values
    }

    /// Resolved rect from layout
    public var resolvedRect: (x: Int, y: Int, width: Int, height: Int) {
        (node.rect.intX, node.rect.intY, node.rect.intWidth, node.rect.intHeight)
    }

    /// Full modifier chain from root to this node
    public var modifierChain: [String] {
        path.compactMap { ancestor in
            if case .modifier(let effect) = ancestor.kind {
                switch effect {
                case .foreground(let c): return "fg(\(c))"
                case .background(let c): return "bg(\(c))"
                case .bold: return "bold"
                case .italic: return "italic"
                case .underline: return "underline"
                case .padding(let n): return "pad(\(n))"
                case .border(_): return "border"
                case .frame(let w, let h): return "frame(\(w ?? 0)x\(h ?? 0))"
                case .explicitID(_): return "id"
                case .overlay: return "overlay"
                case .backgroundView: return "bgView"
                case .modal(_): return "modal"
                }
            }
            return nil
        }
    }
}
