/// Hit testing — map (x,y) screen coordinates to graph nodes.
///
/// After rendering, every node has a resolved rect (set by GraphRenderer).
/// Hit test walks the graph depth-first, children in reverse order
/// (last child = highest z-order, matching render order where last
/// child paints on top). Returns the deepest node containing the point.
///
/// Modal occlusion: when a modal is presented, clicks inside the modal
/// bounds search only the modal subtree. Clicks in the dimmed area
/// (outside modal content) are consumed by the modal node — no
/// passthrough to the base app underneath.

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
        guard x >= r.x, x < r.x + r.width,
              y >= r.y, y < r.y + r.height else {
            return nil
        }

        path.append(node)

        // Modal layer awareness: when a modal is presented, it occludes the base app.
        // If the point is inside the modal content, only search modal children.
        // If outside, return the modal node itself (dimmed area, no base hit).
        if case .modifier(.modal(let isPresented)) = node.kind, isPresented, node.children.count > 1 {
            let modalChild = node.children[1]
            let mr = modalChild.rect
            if x >= mr.x, x < mr.x + mr.width,
               y >= mr.y, y < mr.y + mr.height {
                // Inside modal bounds — only search modal subtree
                if let found = search(x: x, y: y, node: modalChild, path: &path) {
                    return found
                }
                return modalChild
            }
            // Outside modal bounds — hit the dimmed area (no base app passthrough)
            return node
        }

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
            case .text(let spans):
                values.append(("type", "Text"))
                let s = spans.map(\.text).joined()
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
            case .cellBuffer(let buf):
                values.append(("type", "BufferView"))
                values.append(("size", "\(buf.width)x\(buf.height)"))
            }

        case .layout(let info):
            switch info.kind {
            case .vstack: values.append(("type", "VStack"))
            case .hstack: values.append(("type", "HStack"))
            case .zstack: values.append(("type", "ZStack"))
            case .scroll(let axis):
                values.append(("type", axis == .horizontal ? "ScrollView(H)" : "ScrollView(V)"))
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
            case .frame(let w, let h, _, _, _, _): values.append(("modifier", "frame(\(w ?? 0)x\(h ?? 0))"))
            case .flexible(let axes, let grow): values.append(("modifier", "flexible(axes:\(axes.rawValue),grow:\(grow))"))
            case .explicitID(let id): values.append(("modifier", "id(\(id))"))
            case .overlay: values.append(("modifier", "overlay"))
            case .backgroundView: values.append(("modifier", "backgroundView"))
            case .modal(let p): values.append(("modifier", "modal(\(p))"))
            case .focusable: values.append(("modifier", "focusable"))
            case .focusScope(let id): values.append(("modifier", "focusScope(\(id))"))
            case .onKeyPress: values.append(("modifier", "onKeyPress"))
            case .onAppear: values.append(("modifier", "onAppear"))
            case .onChange: values.append(("modifier", "onChange"))
            case .onDisappear: values.append(("modifier", "onDisappear"))
            case .onClick: values.append(("modifier", "onClick"))
            case .onHover: values.append(("modifier", "onHover"))
            case .onPaste: values.append(("modifier", "onPaste"))
            case .environment: values.append(("modifier", "environment"))
            case .actions(let scope): values.append(("modifier", "actions(bound:\(scope.boundActions.count))"))
            }

        case .viewBody(let info):
            values.append(("type", info.viewTypeName))
        }

        return values
    }

    /// Resolved rect from layout
    public var resolvedRect: (x: Int, y: Int, width: Int, height: Int) {
        (node.rect.x, node.rect.y, node.rect.width, node.rect.height)
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
                case .frame(let w, let h, _, _, _, _): return "frame(\(w ?? 0)x\(h ?? 0))"
                case .flexible(let axes, let grow): return "flexible(axes:\(axes.rawValue),grow:\(grow))"
                case .explicitID(_): return "id"
                case .overlay: return "overlay"
                case .backgroundView: return "bgView"
                case .modal(_): return "modal"
                case .focusable: return "focusable"
                case .focusScope(let id): return "focusScope(\(id))"
                case .onKeyPress: return "onKeyPress"
                case .onAppear: return "onAppear"
                case .onChange: return "onChange"
                case .onDisappear: return "onDisappear"
                case .onClick: return "onClick"
                case .onHover: return "onHover"
                case .onPaste: return "onPaste"
                case .environment: return "environment"
                case .actions(let scope): return "actions(\(scope.boundActions.count))"
                }
            }
            return nil
        }
    }
}
